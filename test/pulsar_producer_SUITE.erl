%%%%--------------------------------------------------------------------
%%%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%%%
%%%% Licensed under the Apache License, Version 2.0 (the "License");
%%%% you may not use this file except in compliance with the License.
%%%% You may obtain a copy of the License at
%%%%
%%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%%
%%%% Unless required by applicable law or agreed to in writing, software
%%%% distributed under the License is distributed on an "AS IS" BASIS,
%%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%%% See the License for the specific language governing permissions and
%%%% limitations under the License.
%%%%--------------------------------------------------------------------
-module(pulsar_producer_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(TEST_SUIT_CLIENT, ?MODULE).
-define(DEFAULT_PULSAR_HOST, "pulsar://pulsar:6650").

%%--------------------------------------------------------------------
%% CT Boilerplate
%%--------------------------------------------------------------------

all() ->
    [ t_code_change_replayq
    , t_code_change_requests
    , t_state_rec_roundtrip
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(pulsar),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(pulsar),
    ok.

init_per_testcase(t_code_change_replayq, Config) ->
    PulsarHost = os:getenv("PULSAR_HOST", ?DEFAULT_PULSAR_HOST),
    {ok, _ClientPid} = pulsar:ensure_supervised_client(?TEST_SUIT_CLIENT, [PulsarHost], #{}),
    TestPID = self(),
    Counter = counters:new(1, [atomics]),
    Callback =
        fun(Response) ->
          counters:add(Counter, 1, 1),
          erlang:send(TestPID, Response),
          ok
        end,
    ProducerOpts = #{ batch_size => 100
                    , strategy => random
                    , callback => Callback
                    , replayq_dir => "/tmp/replayq1"
                    , replayq_seg_bytes => 20 * 1024 * 1024
                    , replayq_offload_mode => false
                    , replayq_max_total_bytes => 1_000_000_000
                    , retention_period => 1_000
                    },
    {ok, Producers} = pulsar:ensure_supervised_producers( ?TEST_SUIT_CLIENT
                                                         , <<"my-topic">>
                                                         , ProducerOpts
                                                         ),
    Batch = [#{key => <<"k">>, value => <<"v">>}],
    {_, ProducerPid} = pulsar_producers:pick_producer(Producers, Batch),
    [ {pulsar_host, PulsarHost}
    , {producer_pid, ProducerPid}
    , {producers, Producers}
    , {async_counter, Counter}
    | Config];
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(t_code_change_replayq, Config) ->
    Producers = ?config(producers, Config),
    pulsar:stop_and_delete_supervised_producers(Producers),
    pulsar:stop_and_delete_supervised_client(?TEST_SUIT_CLIENT),
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

%%--------------------------------------------------------------------
%% Helper fns
%%--------------------------------------------------------------------

drain_messages(ExpectedN, Acc) when ExpectedN =< 0 ->
    lists:reverse(Acc);
drain_messages(ExpectedN, Acc) ->
    receive
        Msg ->
            drain_messages(ExpectedN - 1, [Msg | Acc])
    after
        1_000 ->
            ct:fail("expected messages have not arrived;~n  so far: ~100p", [Acc])
    end.

%%--------------------------------------------------------------------
%% Testcases
%%--------------------------------------------------------------------

t_code_change_replayq(Config) ->
    ProducerPid = ?config(producer_pid, Config),

    {_StatemState0, State0} = sys:get_state(ProducerPid),

    ?assert(is_map(State0)),
    ?assertMatch(
       #{ replayq := #{ config := _
                      , sizer := _
                      , stats := _
                      }
        },
       State0),
    #{replayq := Q, opts := Opts0} = State0,
    ?assertNot(replayq:is_mem_only(Q)),
    ?assertMatch(#{retention_period := 1_000}, Opts0),
    OriginalSize = map_size(State0),
    %% FIXME: another way to check if open?
    #{w_cur := #{fd := {_, _, #{pid := ReplayQPID}}}} = Q,

    %% check downgrade has no replayq, and replayq is closed.
    ok = sys:suspend(ProducerPid),
    ExtraDown = #{from_version => {0, 7, 0}, to_version => {0, 6, 4}},
    %% make some requests to downgrade
    Messages = [#{key => <<"key">>, value => <<"value">>}],
    pulsar_producer:send(ProducerPid, Messages),
    try
        pulsar_producer:send_sync(ProducerPid, Messages, 1)
    catch
        error:timeout -> ok
    end,
    ok = sys:change_code(ProducerPid, pulsar_producer, {down, unused_vsn}, ExtraDown),
    %% ok = sys:resume(ProducerPid),
    {_StatemState1, State1} = sys:get_state(ProducerPid),
    ?assert(is_tuple(State1), #{state_after => State1}),
    ?assertEqual(state, element(1, State1)),
    %% state record has 1 element more (the record name), but also has
    %% one field less (`replayq').
    ?assertEqual(OriginalSize, tuple_size(State1)),
    Opts1 = element(9, State1),
    ?assertNot(maps:is_key(replayq, Opts1)),
    ?assertNot(maps:is_key(retention_period, Opts1)),
    %% replayq should be already closed
    ?assertNot(is_process_alive(ReplayQPID)),

    %% check upgrade has replayq and retention_period.
    %% ok = sys:suspend(ProducerPid),
    ExtraUp = #{from_version => {0, 6, 4}, to_version => {0, 7, 0}},
    ok = sys:change_code(ProducerPid, pulsar_producer, unused_vsn, ExtraUp),
    ok = sys:resume(ProducerPid),
    {_StatemState2, State2} = sys:get_state(ProducerPid),
    ?assert(is_map(State2), #{state_after => State2}),
    ?assertEqual(OriginalSize, map_size(State2)),

    ?assertMatch(
       #{ replayq := #{ config := _
                      , sizer := _
                      , stats := _
                      }
        },
       State2),
    #{replayq := Q2, opts := Opts2} = State2,
    ?assertMatch(#{retention_period := infinity}, Opts2),
    %% new replayq is mem-only, since we can't configure it.
    ?assert(replayq:is_mem_only(Q2)),

    %% one sync, one async
    drain_messages(_Expected = 2, _Acc = []),
    %% assert that async callback was called only once
    Counter = ?config(async_counter, Config),
    ?assertEqual(1, counters:get(Counter, 1)),

    ok.

t_code_change_requests(_Config) ->
    %% new format:
    %% {replayq:ack_ref(), [gen_statem:from()], [{timestamp(), [pulsar:message()]}]}
    SequenceId = 1,
    AckRef = {1,1},
    From0 = {self(), erlang:make_ref()},
    From1 = undefined,
    Timestamp0 = erlang:system_time(millisecond),
    Messages0 = [#{key => <<"k1">>, value => <<"v1">>},
                 #{key => <<"k2">>, value => <<"v2">>}],
    Timestamp1 = erlang:system_time(millisecond),
    Messages1 = [#{key => <<"k3">>, value => <<"v3">>}],
    FromsToMessages = [{From0, {Timestamp0, Messages0}},
                       {From1, {Timestamp1, Messages1}}],
    Request = {inflight_req, AckRef, FromsToMessages},
    Requests0 = #{SequenceId => Request},

    Requests1 = pulsar_producer:code_change_requests_down(Requests0),
    %% old format
    ExpectedBatchLen = length(Messages0 ++ Messages1),
    ?assertEqual(#{SequenceId => {SequenceId, ExpectedBatchLen}}, Requests1),

    ok.

t_state_rec_roundtrip(_Config) ->
    StateMap =
        maps:from_list([{K, erlang:make_ref()}
                        || K <- [ batch_size
                                , broker_server
                                , callback
                                , last_bin
                                , opts
                                , partitiontopic
                                , producer_id
                                , producer_name
                                , request_id
                                , requests
                                , sequence_id
                                , sock
                                ]]),
    ?assertEqual(StateMap,
                 pulsar_producer:from_old_state_record(
                   pulsar_producer:to_old_state_record(StateMap))).
