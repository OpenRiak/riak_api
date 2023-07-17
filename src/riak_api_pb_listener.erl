%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2015 Basho Technologies, Inc.
%% Copyright (c) 2022-2023 Workday, Inc.
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
%%
%% @doc Entry point for TCP-based protocol buffers service.
%%
%% This is a re-write of the original module that incorporates its own
%% non-blocking socket acceptance behavior rather than relying on
%% `riak_core:gen_nb_server'.
%% This approach allows us to simplify the implementation while taking
%% advantage of the continuation pattern added to `gen_server' in OTP 21
%% that eliminates a potential race condition.
%%
%% Additionally, this implementation initializes asynchronously so that it can
%% wait for the KV service to be up before accepting connections, resulting in
%% clients getting consistent `{tcp, econnrefused}' errors instead of various
%% error results prior to the service being ready.
%%
-module(riak_api_pb_listener).
-behaviour(gen_server).

% Public API
-export([
    start_link/2
]).

% gen_server callbacks
-export([
    handle_continue/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    init/1,
    terminate/2
]).

% riak_api_sup callback
-export([
    get_listeners/0
]).

-include_lib("kernel/include/logger.hrl").

%% ===================================================================
%% Types
%% ===================================================================

%% Use a unique name for the state record to avoid confusion.
-record(pbl_state, {
    sock    :: gen_tcp:socket() | undefined,
    ip      :: inet:ip_address(),
    port    :: inet:port_number()
}).

-type pb_addr() :: inet:ip_address() | nonempty_string().
-type pb_port() :: inet:port_number().
-type state()   :: #pbl_state{}.

%% Milliseconds between checks in wait_for_node_kv_service/1.
-define(WAIT_FOR_NODE_KV_RETRY_INTERVAL, 277).

%% Milliseconds between checks for riak_core_node_watcher.
-define(WAIT_FOR_NODE_WATCHER_RETRY_INTERVAL, 181).

%% Message from init/1 to handle_continue/2
-define(ASYNC_INIT_CONTINUE_MSG, {?MODULE, init_tcp_server_with_wait}).

%% Simplified guards
-define(is_ip_addr(A), (erlang:is_tuple(A)
    andalso (erlang:size(A) =:= 4 orelse erlang:size(A) =:= 8))).
-define(is_port_num(P),
    (erlang:is_integer(P) andalso P >= 0 andalso P =< 65535)).

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc Starts the PB listener with validated state.
%%
%% Throws a `badarg' error in the calling process if parameters are not valid.
-spec start_link(IpAddr :: pb_addr(), Port :: pb_port())
        -> {ok, pid()} | {error, term()}.
start_link(IpAddr, Port) ->
    State = init_state(IpAddr, Port),
    gen_server:start_link(?MODULE, State, []).

%% ===================================================================
%% gen_server callbacks
%% ===================================================================

%% @doc Initialization callback for `gen_server' behavior.
%%
%% `State' has been validated by `start_link/2' before this is called.
-spec init(State :: state()) -> {ok, state(), {continue, term()}}.
init(State) ->
    {ok, State, {continue, ?ASYNC_INIT_CONTINUE_MSG}}.

%% @doc Continuation callback for `gen_server' behavior.
%%
%% Performs asynchronous initialization of the listener.
-spec handle_continue(Continue :: term(), State :: state())
        -> {noreply, state()} | {stop, term(), state()}.
handle_continue(?ASYNC_INIT_CONTINUE_MSG,
        #pbl_state{ip = IpAddr, port = Port, sock = undefined} = State) ->
    %% This call only returns on success, it blocks forever otherwise.
    ok = wait_for_listener_ready(),
    SockOpts = [{ip, IpAddr} | sock_opts()],
    case gen_tcp:listen(Port, SockOpts) of
        {ok, Socket} ->
            case prim_inet:async_accept(Socket, -1) of
                {ok, _Ref} ->
                    {noreply, State#pbl_state{sock = Socket}};
                {error, AError} ->
                    _ = gen_tcp:close(Socket),
                    {stop, AError, State}
            end;
        {error, LError} ->
            {stop, LError, State}
    end;
handle_continue(Continue, State) ->
    ?LOG_ERROR("unhandled continuation ~0p", [Continue]),
    {stop, {badarg, [Continue, State]}, State}.

%% @doc Unused required `gen_server' callback.
-spec handle_call(term(), {pid(), term()}, state())
        -> {reply, term(), state()}.
handle_call(Request, From, State) ->
    ?LOG_WARNING("unhandled request ~0p from ~0p", [Request, From]),
    {reply, not_implemented, State}.

%% @doc Unused required `gen_server' callback.
-spec handle_cast(Message :: term(), State :: state()) -> {noreply, state()}.
handle_cast(Message, State) ->
    ?LOG_WARNING("unhandled message ~0p", [Message]),
    {noreply, State}.

%% @doc Message callback for `gen_server' behavior.
%%
%% Wires accepted socket connections through to their handlers.
-spec handle_info(Message :: term(), State :: state())
        -> {noreply, state()} | {stop, term(), state()}.
handle_info({inet_async, ListSock, _Ref, {ok, CliSocket}}, StateIn) ->
    case inet_db:register_socket(CliSocket, inet_tcp) of
        true ->
            case new_connection(CliSocket, StateIn) of
                {ok, StateOut} ->
                    case prim_inet:async_accept(ListSock, -1) of
                        {ok, _} ->
                            {noreply, StateOut};
                        {error, AReason} ->
                            {stop, AReason, StateOut}
                    end;
                {error, CReason} ->
                    {stop, CReason, StateIn}
            end;
        _ ->
            ?LOG_ERROR("Failed to register socket ~w", [CliSocket]),
            _ = gen_tcp:close(CliSocket),
            {stop, {badarg, [CliSocket]}, StateIn}
    end;
handle_info(Message, State) ->
    ?LOG_WARNING("Unhandled message ~0p", [Message]),
    {noreply, State}.

%% @doc Termination callback for `gen_server' behavior.
-spec terminate(Reason :: term(), State :: state()) -> Ignored :: term().
terminate(Reason, #pbl_state{sock = undefined} = State) ->
    %% If the socket is undefined then we're in the asynchronous
    %% initialization phase and handle_continue/2 hasn't been called yet,
    %% so there's nothing to clean up.
    ?LOG_DEBUG("terminate(~0p) with state: ~0p", [Reason, State]);
terminate(Reason, #pbl_state{sock = Socket} = State) ->
    _ = gen_tcp:close(Socket),
    ?LOG_DEBUG("terminate(~0p) with state: ~0p", [Reason, State]).

%% ===================================================================
%% riak_api_sup callback
%% ===================================================================

%% @doc Returns the endpoint upon which this service will be initialized.
-spec get_listeners() -> list({inet:ip_address(), inet:port_number()}).
get_listeners() ->
    Pairs = app_helper:get_env(riak_api, pb, []),
    IpAdr = get_deprecated(pb_ip),
    Port  = get_deprecated(pb_port),
    case IpAdr =:= undefined orelse Port =:= undefined of
        true ->
            Pairs;
        _ ->
            Default = {IpAdr, Port},
            case lists:member(Default, Pairs) of
                true ->
                    Pairs;
                _ ->
                    Pairs ++ [Default]
            end
    end.

%% ===================================================================
%% Wait for the KV service to be ready
%% ===================================================================

%% @hidden
%% Wait until required services are online, or forever if they don't start.
-spec wait_for_listener_ready() -> ok.
wait_for_listener_ready() ->
    wait_for_node_service_watcher(),
    wait_for_node_kv_service(erlang:node()).

%% @hidden
%% Returns `ok' only when running services can be checked safely.
%%
%% This is waaay too tightly coupled to the riak_core_node_watcher
%% implementation, but there doesn't seem to be any way to avoid that.
%%
%% As currently implemented, riak_core_node_watcher:services/1 relies on the
%% ets table directly, not on the running gen_server.
%% We'd prefer to just check for the running gen_server by name, since its
%% init/1 function initializes the ets table, but gen_server registers the
%% name *before* running init/1, so erlang:whereis can return a pid before
%% the ets table has actually been initialized.
%%
%% We use the services/0 function, which performs a lightweight query on the
%% ets table via a gen_server call, as a proxy for determining that services/1
%% can be invoked, so that if the services/1 implementation changes to go
%% through the gen_server this strategy should still be safe on the assumption
%% that services/1 and services/0 would almost certainly operate from the same
%% shared state (as they do now).
%%
%% If riak_core_node_watcher:init/1 fails for any reason that will cascade to
%% this process crashing as well, and both gen_servers will be restarted by
%% their respective supervisors to try it all again.
%%
-spec wait_for_node_service_watcher() -> ok.
wait_for_node_service_watcher() ->
    RegisteredService = riak_core_node_watcher,
    ?LOG_DEBUG("checking ~s", [RegisteredService]),
    case erlang:whereis(RegisteredService) of
        undefined ->
            timer:sleep(?WAIT_FOR_NODE_WATCHER_RETRY_INTERVAL),
            wait_for_node_service_watcher();
        _ ->
            %% We don't care about the result, this is just the cheapest way
            %% to wait for the gen_server to finish its (and the ets table's)
            %% initialization.
            _ = riak_core_node_watcher:services(),
            ok
    end.

%% @hidden
%% Returns `ok' only when listener requests can be handled successfully
-spec wait_for_node_kv_service(Node :: node()) -> ok.
wait_for_node_kv_service(Node) ->
    ?LOG_DEBUG("checking for KV service on ~w", [Node]),
    case lists:member(riak_kv, riak_core_node_watcher:services(Node)) of
        true ->
            ok;
        _ ->
            timer:sleep(?WAIT_FOR_NODE_KV_RETRY_INTERVAL),
            wait_for_node_kv_service(Node)
    end.

%% ===================================================================
%% Internal functions
%% ===================================================================

%% @private
%% Get a deprecated key, warning if it's present.
-spec get_deprecated(Key :: atom()) -> term().
get_deprecated(Key) ->
    case app_helper:get_env(riak_api, Key) of
        undefined ->
            undefined;
        Val ->
            ?LOG_WARNING(
                "The config riak_api/~s has been deprecated and will be removed."
                " Use riak_api/pb (IP/Port pairs) in the future.", [Key]),
            Val
    end.

%% @private
%% Initializes the state record with validated parameters, allowing the
%% `start' function(s) to throw a `badarg' error *before* spawning the gs
%% process, yielding an informative stack trace.
-spec init_state(IpAddr :: pb_addr(), Port :: pb_port())
        -> state() | no_return().
init_state(_IpAddr, Port) when not ?is_port_num(Port) ->
    erlang:error(badarg, [Port]);
init_state(IpAddrStr, Port) when not ?is_ip_addr(IpAddrStr) ->
    case inet:parse_address(IpAddrStr) of
        {ok, IpAddr} ->
            init_state(IpAddr, Port);
        _ ->
            erlang:error(badarg, [IpAddrStr])
    end;
init_state(IpAddr, Port) ->
    #pbl_state{ip = IpAddr, port = Port}.

%% @private Called when a new socket is accepted.
-spec new_connection(Socket :: port(), state())
        -> {ok, state()} | {error, term()}.
new_connection(Socket, State) ->
    case riak_api_pb_sup:start_socket() of
        {ok, Pid} ->
            case gen_tcp:controlling_process(Socket, Pid) of
                ok ->
                    ok = riak_api_pb_server:set_socket(Pid, Socket),
                    {ok, State};
                TcpErr ->
                    TcpErr
            end;
        SupErr ->
            SupErr
    end.

%% @private Preferred socket options for the listener.
-spec sock_opts() -> list(gen_tcp:listen_option()).
sock_opts() ->
    [
        binary,
        {packet, raw},
        {reuseaddr, true},
        {backlog, app_helper:get_env(riak_api, pb_backlog, 128)},
        {nodelay, app_helper:get_env(riak_api, disable_pb_nagle, true)},
        {keepalive, app_helper:get_env(riak_api, pb_keepalive, true)}
    ].
