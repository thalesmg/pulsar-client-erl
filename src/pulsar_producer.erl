%% Copyright (c) 2013-2019 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(pulsar_producer).

-behaviour(gen_statem).

-include("PulsarApi_pb.hrl").

-export([ send/2
        , send_sync/2
        ]).

-export([ start_link/3
        , idle/3
        , connecting/3
        , connected/3
        ]).

-export([ callback_mode/0
        , init/1
        , terminate/3
        , code_change/4
        ]).

callback_mode() -> [state_functions].

-define(TIMEOUT, 60000).

-define(TCPOPTIONS, [
    binary,
    {packet,    raw},
    {reuseaddr, true},
    {nodelay,   true},
    {active,    true},
    {reuseaddr, true},
    {send_timeout, ?TIMEOUT}]).

-record(state, {partitiontopic,
                broker_service_url,
                sock,
                request_id = 1,
                producer_id = 1,
                sequence_id = 1,
                producer_name,
                opts = [],
                callback,
                batch_size = 0,
                requests = #{}}).

-define (FRAME, pulsar_protocol_frame).

start_link(PartitionTopic, BrokerServiceUrl, ProducerOpts) ->
    gen_statem:start_link(?MODULE, [PartitionTopic, BrokerServiceUrl, ProducerOpts], []).


send(Pid, Message) ->
    gen_statem:cast(Pid, {send, Message}).

send_sync(Pid, Message) ->
    send_sync(Pid, Message, 5000).

send_sync(Pid, Message, Timeout) ->
    gen_statem:call(Pid, {send, Message}, Timeout).


%%--------------------------------------------------------------------
%% gen_server callback
%%--------------------------------------------------------------------
init([PartitionTopic, BrokerServiceUrl, ProducerOpts]) ->
    State = #state{partitiontopic = PartitionTopic,
                   callback = maps:get(callback, ProducerOpts, undefined),
                   batch_size = maps:get(batch_size, ProducerOpts, 0),
                   broker_service_url = BrokerServiceUrl,
                   opts = maps:get(tcp_opts, ProducerOpts, [])},
    self() ! connecting,
    {ok, idle, State}.

idle(_, connecting, State = #state{opts = Opts, broker_service_url = BrokerServiceUrl}) ->
    {Host, Port} = format_url(BrokerServiceUrl),
    case gen_tcp:connect(Host, Port, merge_opts(Opts, ?TCPOPTIONS), ?TIMEOUT) of
        {ok, Sock} ->
            tune_buffer(Sock),
            gen_tcp:controlling_process(Sock, self()),
            connect(Sock),
            {next_state, connecting, State#state{sock = Sock}};
        Error ->
            {stop, Error, State}
    end.

connecting(_EventType, {tcp, _, Bin}, State) ->
    handle_response(?FRAME:parse(Bin), State).

connected(_EventType, {tcp_closed, Sock}, State = #state{sock = Sock, producer_id = ProducerId}) ->
    log_error("TcpClosed producer: ~p~n", [ProducerId]),
    erlang:send_after(5000, self(), connecting),
    {next_state, idle, State#state{sock = undefined}};

connected(_EventType, {tcp, _, Bin}, State) ->
    handle_response(?FRAME:parse(Bin), State);

connected(_EventType, ping, State = #state{sock = Sock}) ->
    ping(Sock),
    {keep_state, State};

connected({call, From}, {send, Message}, State = #state{sequence_id = SequenceId, requests = Reqs}) ->
    send_batch_payload(Message, State),
    {keep_state, next_sequence_id(State#state{requests = maps:put(SequenceId, From, Reqs)})};

connected(cast, {send, Message}, State = #state{batch_size = BatchSize}) ->
    BatchMessage = Message ++ collect_send_calls(BatchSize),
    send_batch_payload(BatchMessage, State),
    {keep_state, next_sequence_id(State)};

connected(_EventType, EventContent, State) ->
    handle_response(EventContent, State).

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.

terminate(_Reason, _StateName, _State) ->
    ok.

handle_response(#commandconnected{}, State = #state{sock = Sock,
                                                    request_id = RequestId,
                                                    producer_id = ProId,
                                                    partitiontopic = Topic}) ->
    ping(Sock),
    create_producer(Sock, Topic, RequestId, ProId),
    {next_state, connected, next_request_id(State)};

handle_response(#commandproducersuccess{producer_name = ProName}, State) ->
    {next_state, connected, State#state{producer_name = ProName}};

handle_response(#commandpong{}, State) ->
    start_keepalive(),
    {keep_state, State};
handle_response(#commandping{}, State = #state{sock = Sock}) ->
    pong(Sock),
    {keep_state, State};
handle_response(#commandcloseproducer{producer_id = ProducerId}, State) ->
    log_error("Close producer: ~p~n", [ProducerId]),
    {stop, closed_producer, State};
handle_response(Resp = #commandsendreceipt{sequence_id = SequenceId},
                State = #state{callback = undefined, requests = Reqs}) ->
    case maps:get(SequenceId, Reqs, undefined) of
        undefined ->
            {keep_state, State};
        From ->
            gen_statem:reply(From, Resp),
            {keep_state, State#state{requests = maps:remove(SequenceId, Reqs)}}
    end;
handle_response(Resp = #commandsendreceipt{sequence_id = SequenceId},
                State = #state{callback = Callback, requests = Reqs}) ->
    case maps:get(SequenceId, Reqs, undefined) of
        undefined ->
            Callback(Resp),
            {keep_state, State};
        From ->
            gen_statem:reply(From, Resp),
            {keep_state, State#state{requests = maps:remove(SequenceId, Reqs)}}
    end;
    
handle_response(Msg, State) ->
    log_error("Receive unknown message:~p~n", [Msg]),
    {keep_state, State}.

connect(Sock) ->
    Conn = #commandconnect{client_version = "Pulsar-Client-Erlang-v0.0.1",
                           protocol_version = 6},
    gen_tcp:send(Sock, ?FRAME:connect(Conn)).

send_batch_payload(Messages, #state{sequence_id = SequenceId,
                                    producer_id = ProducerId,
                                    producer_name = ProducerName,
                                    sock = Sock}) ->
    Send = #commandsend{
        producer_id = ProducerId,
        sequence_id = SequenceId,
        num_messages = length(Messages)
    },
    
    BatchMessage = batch_message(Messages),

    Metadata = #messagemetadata{
        producer_name = ProducerName,
        sequence_id = SequenceId,
        publish_time = erlang:system_time(millisecond),
        num_messages_in_batch = length(Messages)
    },
    gen_tcp:send(Sock, ?FRAME:send(Send, Metadata, BatchMessage)).

start_keepalive() ->
    erlang:send_after(30*1000, self(), ping).

ping(Sock) ->
    gen_tcp:send(Sock, ?FRAME:ping()).

pong(Sock) ->
    gen_tcp:send(Sock, ?FRAME:pong()).

create_producer(Sock, Topic, RequestId, ProducerId) ->
    Producer = #commandproducer{
        topic = Topic,
        producer_id = ProducerId,
        request_id = RequestId
    },
    gen_tcp:send(Sock, ?FRAME:create_producer(Producer)).

batch_message(Messages) when length(Messages) =:= 1 ->
    [Message] = Messages,
    Message;
batch_message(Messages) ->
    lists:foldl(fun(Message, Acc) ->
        Metadata = #singlemessagemetadata{payload_size = size(Message)},
        MetadataBin = iolist_to_binary('PulsarApi_pb':encode_singlemessagemetadata(Metadata)),
        MetadataBinSize = size(MetadataBin),
        <<Acc/binary, MetadataBinSize:32, MetadataBin/binary, Message/binary>>
    end, <<>>, Messages).

collect_send_calls(0) ->
    [];
collect_send_calls(Cnt) when Cnt > 0 ->
    collect_send_calls(Cnt, []).

collect_send_calls(0, Acc) ->
    lists:reverse(Acc);

collect_send_calls(Cnt, Acc) ->
    receive
        {'$gen_cast', {send, Messages}} ->
            collect_send_calls(Cnt - 1, Messages ++ Acc)
    after 0 ->
          lists:reverse(Acc)
    end.

tune_buffer(Sock) ->
    {ok, [{recbuf, RecBuf}, {sndbuf, SndBuf}]} = inet:getopts(Sock, [recbuf, sndbuf]),
    inet:setopts(Sock, [{buffer, max(RecBuf, SndBuf)}]).

merge_opts(Defaults, Options) ->
    lists:foldl(
        fun({Opt, Val}, Acc) ->
                case lists:keymember(Opt, 1, Acc) of
                    true ->
                        lists:keyreplace(Opt, 1, Acc, {Opt, Val});
                    false ->
                        [{Opt, Val}|Acc]
                end;
            (Opt, Acc) ->
                case lists:member(Opt, Acc) of
                    true -> Acc;
                    false -> [Opt | Acc]
                end
        end, Defaults, Options).

format_url("pulsar://" ++ Url) ->
    [Host, Port] = string:tokens(Url, ":"),
    {Host, list_to_integer(Port)};
format_url(_) ->
    {"127.0.0.1", 6650}.

next_request_id(State = #state{request_id = 65535}) ->
    State#state{request_id = 1};
next_request_id(State = #state{request_id = RequestId}) ->
    State#state{request_id = RequestId+1}.

next_sequence_id(State = #state{sequence_id = 4294836225}) ->
    State#state{sequence_id = 1};
next_sequence_id(State = #state{sequence_id = SequenceId}) ->
    State#state{sequence_id = SequenceId+1}.

log_error(Fmt, Args) -> error_logger:error_msg(Fmt, Args).