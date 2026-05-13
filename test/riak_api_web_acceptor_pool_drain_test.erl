%% -------------------------------------------------------------------
%%
%% Copyright (c) 2026 Frank Eickhoff
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc Test that reproduces edge case where acceptor pool maxes out and does not get replenished:
%% after the pool reaches max size and all accepted connections exit, the
%% listener remains alive but the acceptor pool is not replenished unless
%% explicitly handled.
%%
%% This test opens three TCP connections to exhaust the pool at max size, then
%% closes them. If the pool is incorrectly managed, it will be left empty,
%% leaving the listener process running with no acceptors available. As a result,
%% new client TCP handshakes can complete, but since no Erlang acceptor process
%% calls gen_tcp:accept, subsequent HTTP requests from the client will time out,
%% with no HTTP response received.
%%
%% The test error logs record acceptor_pool_status, remaining acceptor PIDs, and
%% probe the listener state to illustrate that the bug is triggered when no
%% acceptor processes are registered after the connections exit.

-module(riak_api_web_acceptor_pool_drain_test).

-include_lib("eunit/include/eunit.hrl").

-define(TEST_OBJECT_KEY, <<"foo">>).

acceptor_pool_drain_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(State) ->
        [fun() -> max_out_acceptor_pool(State) end]
    end}.

setup() ->
    TestPort = find_available_port(lists:seq(9100, 9999)),
    IPAddr = {127, 0, 0, 1},
    SpecName = riak_api_web:spec_name(http, IPAddr, TestPort),
    Options =
        [
            {name, SpecName},
            {ip, IPAddr},
            {port, TestPort},
            {acceptor_pool_start_size, 1},
            {acceptor_pool_max_size, 3}
        ],
    {ok, _Pid} = riak_api_web_socket:start_link(Options),
    riak_api_web:add_routes([{20, riak_api_web_ets_store}]),
    ets:new(
        riak_api_web_ets_store,
        [named_table, public, {read_concurrency, true}]
    ),
    ?assertEqual(1, riak_api_web_socket:get_active_pool_size(SpecName)),
    {SpecName, IPAddr, TestPort}.

cleanup({SpecName, _IPAddr, _Port}) ->
    ok = riak_api_web_socket:stop(SpecName),
    catch ets:delete(riak_api_web_ets_store),
    ok.

max_out_acceptor_pool({SpecName, IPAddr, Port}) ->
    %% Open enough TCP connections to fill acceptor_pool_max_size (handshakes
    %% complete without HTTP first; see riak_api_web_acceptor:init/3).
    Sockets = connect_clients(IPAddr, Port, 3),
    Req = test_get_request(),
    %% Drive each accepted socket with HTTP so acceptors run the request path.
    lists:foreach(
        fun(S) -> ok = gen_tcp:send(S, Req) end,
        Sockets
    ),
    %% Read responses until close so work finishes and connections drop.
    lists:foreach(fun flush_http_client/1, Sockets),
    %% Let EXIT casts and pool bookkeeping run before we inspect pool size.
    ok = timer:sleep(400),
    Pool = riak_api_web_socket:get_active_pool_size(SpecName),
    ServerAtom = binary_to_existing_atom(SpecName),
    if
        Pool > 0 ->
            ok;
        true ->
            %% Pool empty: collect listener and acceptor context for the failure.
            ListenerPid = whereis(ServerAtom),
            ListenerAlive =
                is_pid(ListenerPid) andalso is_process_alive(ListenerPid),
            LinkedAcceptors =
                linked_web_acceptor_workers_for_listener(ListenerPid),
            Probe = probe_new_client_after_pool_drain(IPAddr, Port),
            ErrorReason = error_reason_for_drained_pool(
                Pool, ListenerPid, ListenerAlive, LinkedAcceptors
            ),
            erlang:error(
                {acceptor_pool_drained, [
                    {error_reason, ErrorReason},
                    {new_client_probe, Probe}
                ]}
            )
    end,
    %% Listener must stay registered after the scenario.
    ?assert(is_pid(whereis(ServerAtom))).

connect_clients(IPAddr, Port, N) ->
    [
        begin
            {ok, S} = gen_tcp:connect(IPAddr, Port, conn_opts(), 5000),
            S
        end
     || _ <- lists:seq(1, N)
    ].

error_reason_for_drained_pool(0, ListenerPid, true, []) when
    is_pid(ListenerPid)
->
    "Acceptor pool size is 0; all acceptor processes drained. The listener process is still alive, but no new acceptors were spawned to handle further incoming connections.";
error_reason_for_drained_pool(0, ListenerPid, true, _) when
    is_pid(ListenerPid)
->
    "Acceptor pool size is 0; listener is still alive, but some acceptors are still linked.";
error_reason_for_drained_pool(0, ListenerPid, _, _) when
    not is_pid(ListenerPid)
->
    "Acceptor pool size is 0; listener process is not registered. No acceptor processes are available.";
error_reason_for_drained_pool(_, _, _, _) ->
    "Unexpected pool/acceptor/listener state.".

conn_opts() ->
    [binary, {packet, raw}, {active, false}].

test_get_request() ->
    iolist_to_binary(
        [
            <<"GET /ets_object/key/">>,
            ?TEST_OBJECT_KEY,
            <<" HTTP/1.1\r\nConnection: close\r\n\r\n">>
        ]
    ).

%% Acceptors are spawn_link-ed from riak_api_web_socket when it calls
%% riak_api_web_acceptor:start_link/2, so each worker is linked to that
%% gen_server pid. An empty list means no accept loop is running for it.
-spec linked_web_acceptor_workers_for_listener(pid() | false) -> [pid()].
linked_web_acceptor_workers_for_listener(ListenerPid) when
    is_pid(ListenerPid)
->
    Filter = fun(P) ->
        case process_info(P, [initial_call, links]) of
            undefined ->
                false;
            Info ->
                case lists:keyfind(initial_call, 1, Info) of
                    {initial_call, {riak_api_web_acceptor, init, 3}} ->
                        case lists:keyfind(links, 1, Info) of
                            {links, Links} ->
                                lists:member(ListenerPid, Links);
                            _ ->
                                false
                        end;
                    _ ->
                        false
                end
        end
    end,
    lists:filter(
        Filter,
        processes()
    );
linked_web_acceptor_workers_for_listener(_) ->
    [].

%% @doc When the acceptor set is empty, the listen socket may still complete
%% new TCP handshakes while no Erlang process calls gen_tcp:accept, so connect
%% can succeed and HTTP still never runs. This records which case applies.
-spec probe_new_client_after_pool_drain(inet:ip_address(), inet:port_number()) ->
    term().
probe_new_client_after_pool_drain(IPAddr, Port) ->
    Req = test_get_request(),
    case gen_tcp:connect(IPAddr, Port, conn_opts(), 2500) of
        {ok, S} ->
            ok = gen_tcp:send(S, Req),
            Recv = gen_tcp:recv(S, 0, 2500),
            ok = gen_tcp:close(S),
            {client_tcp, handshake_complete, {http_recv, Recv}};
        {error, timeout} ->
            {client_tcp, connect_timed_out};
        {error, Reason} ->
            {client_tcp, connect_failed, Reason}
    end.

flush_http_client(S) ->
    case gen_tcp:recv(S, 0, 8000) of
        {ok, _} ->
            flush_http_client(S);
        {error, closed} ->
            ok;
        {error, timeout} ->
            ok = gen_tcp:close(S),
            ok
    end.

find_available_port([]) ->
    error(no_free_port);
find_available_port([Port | Rest]) ->
    case gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}, {reuseaddr, true}]) of
        {ok, LSock} ->
            ok = gen_tcp:close(LSock),
            Port;
        {error, _} ->
            find_available_port(Rest)
    end.
