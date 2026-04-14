%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007 Mochi Media, Inc
%% Copyright (c) 2026 Martin Sumner
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
%% @doc Socket and acceptor pool management for web requests
%%
%% Socket manager intended to abstract away from choice of SSL, and also
%% maintain a pool of accept processes that are ready to accept new connection
%% requests
%%
%% Each acceptor is an `riak_api_web_acceptor` - an as each acceptor accepts
%% a connection, it will prompt this socket server to launch a new acceptor.
%% When a linked acceptor closes (along with the connection), the close message
%% is handled and the closed acceptor is removed from the pool.
%%
%% The intention is that there should always be at least the pool size of
%% acceptors waiting for a connection - unless the max size is reached, and no
%% new acceptors will be started.  This means that concurrently no more
%% connections can be handled concurrently than the max pool size.
%%
%% The module was initially based on the:
%%  - mochiweb_socket_server
%%  - mochiweb_socket
%%  - mochiweb_acceptor
%%
%% Patterns used in these modules have been compared with the Elli web server
%% for validation - https://github.com/elli-lib/elli.

-module(riak_api_web_socket).

-if(?OTP_RELEASE == 26).
-feature(maybe_expr, enable).
-endif.

-behaviour(gen_server).

-export(
    [
        start_link/1,
        get_max_pool_size/1,
        set_max_pool_size/2,
        get_active_pool_size/1
    ]
).

-export(
    [
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2
    ]
).

-export(
    [
        get_scheme/1,
        accept/2,
        recv/3,
        recv_line/2,
        send/2,
        close/1,
        stop/1,
        get_peer/1,
        acceptor_accepted/1
    ]
).

-include_lib("kernel/include/logger.hrl").

-define(POOL_SIZE_DEFAULT, 16).
-define(POOL_SIZE_MAX_DEFAULT, 2048).
-define(DEFAULT_RECV_BUFFER, 131072).
% Setting the receive buffer will also change the buffer
% https://github.com/erlang/otp/issues/9355

-record(socket_state, {
    port :: inet:port_number(),
    listener :: socket(),
    pool_size = ?POOL_SIZE_DEFAULT :: pos_integer(),
    max_pool_size = ?POOL_SIZE_MAX_DEFAULT :: pos_integer(),
    acceptor_pool = sets:new([{version, 2}]) :: sets:set()
}).

-type socket_option() ::
    {ip, inet:ip_address()}
    | binary
    | {reuseaddr, boolean()}
    %% Assumed necessary to allow for rapid restart of supervised
    %% process - e.g. allow for next process to listen on socket even
    %% when the previous process has not completed the close
    | {packet, raw}
    | {active, boolean()}
%% After a connection is accepted the socket is manually read to be
%% decoded
.

-type buffer_option() ::
    {recbuf, pos_integer()}
    | {sndbuf, pos_integer()}
    | {buffer, pos_integer()}
% The size of the user-level buffer used by the driver.
% Not to be confused with options sndbuf and recbuf, which correspond
% to the Kernel socket buffers. For TCP it is recommended to have
% val(buffer) >= val(recbuf) to avoid performance issues because
% of unnecessary copying
.

-type server_name() :: binary().
% Name of the root part of the address i.e.
% <<"Protocol://Host:Port">>

-type option() ::
    {acceptor_pool_start_size, pos_integer()}
    % The number of acceptors to be ready to accept an new connection.
    % This pool size is not a limit, it is is the starting size.  As an
    % acceptor picks up a new connection request it will prompt for a new
    % acceptor to be spawned (and will not return to the pool once it is
    % complete).
    | {acceptor_pool_max_size, pos_integer()}
    % The maximum number of acceptors in the pool - the total number of
    % concurrent requests that can be supported on this port
    | {ssl, boolean()}
    | {ssl_opts, [ssl:tls_server_option()]}
    | {ip, inet:ip_address()}
    | {port, inet:port_number()}
    | {name, server_name()}.

-type scheme() :: http | https.

-type web_options() :: list(option()).

-type socket() :: {http, gen_tcp:socket()} | {https, ssl:sslsocket()}.

-type tcp_error() :: closed | timeout | system_limit | inet:posix().
-type tls_error() :: term().

-export_type([socket/0, scheme/0]).

%%%============================================================================
%%% API
%%%============================================================================

-spec start_link(web_options()) -> {ok, pid()}.
start_link(Options) ->
    ServerName =
        case lists:keyfind(name, 1, Options) of
            {name, Name} when is_binary(Name) ->
                {local, binary_to_atom(Name)}
        end,
    {ok, Pid} = gen_server:start_link(ServerName, ?MODULE, Options, []),
    {ok, Pid}.

-spec get_max_pool_size(server_name()) -> pos_integer().
get_max_pool_size(ServerName) ->
    gen_server:call(
        binary_to_existing_atom(ServerName),
        get_max_pool_size,
        infinity
    ).

-spec get_active_pool_size(server_name()) -> pos_integer().
get_active_pool_size(ServerName) ->
    gen_server:call(
        binary_to_existing_atom(ServerName),
        get_active_pool_size,
        infinity
    ).

-spec set_max_pool_size(server_name(), pos_integer()) -> ok.
set_max_pool_size(ServerName, MaxPoolSize) when is_integer(MaxPoolSize) ->
    gen_server:cast(
        binary_to_existing_atom(ServerName),
        {set_max_pool_size, MaxPoolSize}
    ).

-spec acceptor_accepted(pid()) -> ok.
acceptor_accepted(Pid) ->
    gen_server:cast(Pid, accepted).

-spec stop(server_name()) -> ok.
stop(ServerName) ->
    gen_server:call(
        binary_to_existing_atom(ServerName),
        stop,
        infinity
    ).

%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init(Options) ->
    process_flag(trap_exit, true),
    BufferOpts =
        case get_tcp_buffer_options() of
            [] ->
                [{recbuf, ?DEFAULT_RECV_BUFFER}];
            NonDefaultOpts ->
                ?LOG_INFO(
                    "Non-default TCP buffer options configured for web ~0p",
                    [NonDefaultOpts]
                ),
                NonDefaultOpts
        end,
    {ip, IP} =
        case lists:keyfind(ip, 1, Options) of
            {ip, IPString} when is_list(IPString) ->
                {ok, IPAddr} = inet:parse_address(IPString),
                {ip, IPAddr};
            {ip, IPAddr} ->
                {ip, IPAddr}
        end,
    {port, Port} = lists:keyfind(port, 1, Options),
    {Protocol, SSLOpts} =
        case lists:keyfind(ssl, 1, Options) of
            {ssl, true} ->
                {ssl_opts, SSLOptsIn} = lists:keyfind(ssl_opts, 1, Options),
                {https, SSLOptsIn};
            _ ->
                {http, none}
        end,
    SocketOpts = default_socket_options(IP),
    {ok, Listener} = listen(Protocol, Port, SocketOpts, BufferOpts, SSLOpts),
    {AcceptorPool, StartSize, MaxSize} = get_acceptor_pool(Listener, Options),
    ?LOG_INFO(
        "Acceptor pool for web started on IP ~0p port ~w of size ~w",
        [IP, Port, StartSize]
    ),
    riak_api_web:cache_today(),
    riak_api_web_headers:compile_separators(),
    riak_api_web_acceptor:compile_separators(),
    {
        ok,
        #socket_state{
            listener = Listener,
            port = Port,
            pool_size = StartSize,
            max_pool_size = MaxSize,
            acceptor_pool = sets:from_list(AcceptorPool, [{version, 2}])
        }
    }.

handle_call(get_max_pool_size, _From, State) ->
    {reply, State#socket_state.max_pool_size, State};
handle_call(get_active_pool_size, _From, State) ->
    {reply, sets:size(State#socket_state.acceptor_pool), State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({set_max_pool_size, MPS}, State) ->
    case State#socket_state.pool_size of
        PS when PS =< MPS ->
            {noreply, State#socket_state{max_pool_size = MPS}};
        PS ->
            ?LOG_WARNING(
                "Ignoring change to max pool size ~w to smaller value than "
                "starting pool ~w",
                [MPS, PS]
            ),
            {noreply, State}
    end;
handle_cast(accepted, State) ->
    case State#socket_state.pool_size of
        PS when PS < State#socket_state.max_pool_size ->
            P =
                riak_api_web_acceptor:start_link(
                    State#socket_state.listener
                ),
            {
                noreply,
                State#socket_state{
                    acceptor_pool =
                        sets:add_element(P, State#socket_state.acceptor_pool),
                    pool_size = PS + 1
                }
            };
        _ ->
            ?LOG_WARNING(
                "Web connection pool reached limit of ~w",
                [State#socket_state.pool_size]
            ),
            {noreply, State}
    end.

handle_info({'EXIT', Pid, normal}, State) ->
    {
        noreply,
        State#socket_state{
            pool_size = State#socket_state.pool_size - 1,
            acceptor_pool =
                sets:del_element(Pid, State#socket_state.acceptor_pool)
        }
    };
handle_info({'EXIT', Pid, Reason}, State) ->
    ?LOG_ERROR("Acceptor ~p unexpectedly crashed: ~0p", [Pid, Reason]),
    handle_info({'EXIT', Pid, normal}, State).

%%%============================================================================
%%% Internal Functions
%%%============================================================================

-spec default_socket_options(inet:ip_address()) -> [socket_option()].
default_socket_options(IPAddr) ->
    [
        {ip, IPAddr},
        binary,
        {reuseaddr, true},
        {packet, raw},
        {active, false}
    ].

-spec get_acceptor_pool(socket(), list(option())) ->
    {list(pid()), pos_integer(), pos_integer()}.
get_acceptor_pool(Listener, Options) ->
    StartSize =
        case lists:keyfind(web_acceptor_pool_start_size, 1, Options) of
            {web_acceptor_pool_start_size, SS} when is_integer(SS), SS > 0 ->
                SS;
            false ->
                application:get_env(
                    riak_api,
                    acceptor_pool_start_size,
                    ?POOL_SIZE_DEFAULT
                )
        end,
    MaxSize =
        case lists:keyfind(web_acceptor_pool_max_size, 1, Options) of
            {web_acceptor_pool_start_size, MS} when is_integer(MS), MS > 0 ->
                MS;
            false ->
                application:get_env(
                    riak_api,
                    acceptor_pool_max_size,
                    ?POOL_SIZE_MAX_DEFAULT
                )
        end,
    case {StartSize, MaxSize} of
        {StartSize, MaxSize} when
            is_integer(StartSize),
            is_integer(MaxSize),
            MaxSize >= StartSize
        ->
            {
                start_acceptor_pool(Listener, StartSize),
                StartSize,
                MaxSize
            };
        InvalidConfig ->
            ?LOG_ERROR(
                "Invalid configuration of acceptor pool ~0p - "
                "starting with defaults",
                [InvalidConfig]
            ),
            {
                start_acceptor_pool(Listener, ?POOL_SIZE_DEFAULT),
                ?POOL_SIZE_DEFAULT,
                ?POOL_SIZE_MAX_DEFAULT
            }
    end.

-spec start_acceptor_pool(socket(), pos_integer()) -> list(pid()).
start_acceptor_pool(Listener, Size) ->
    lists:map(
        fun(_I) ->
            P = riak_api_web_acceptor:start_link(Listener),
            true = is_pid(P),
            P
        end,
        lists:seq(1, Size)
    ).

-spec get_tcp_buffer_options() -> list(buffer_option()).
get_tcp_buffer_options() ->
    get_tcp_buffer_options(
        [
            {buffer, web_kernel_buffer},
            {recbuf, web_receive_buffer},
            {sndbuf, web_send_buffer}
        ],
        []
    ).

get_tcp_buffer_options([], BufferOptions) ->
    BufferOptions;
get_tcp_buffer_options([{Name, EnVar} | Rest], BufferOptions) ->
    case application:get_env(riak_api, EnVar) of
        {ok, BSize} when is_integer(BSize) ->
            get_tcp_buffer_options(Rest, [{Name, BSize} | BufferOptions]);
        _ ->
            get_tcp_buffer_options(Rest, BufferOptions)
    end.

-spec get_scheme(socket()) -> scheme().
get_scheme({Scheme, _Socket}) ->
    Scheme.

-spec listen(
    scheme(),
    inet:port_number(),
    list(socket_option()),
    list(buffer_option()),
    none | list(ssl:tls_server_option())
) ->
    {ok, socket()} | {error, any()}.
listen(http, Port, SocketOpts, BufferOpts, none) ->
    case gen_tcp:listen(Port, SocketOpts ++ BufferOpts) of
        {ok, Socket} ->
            {ok, {http, Socket}};
        {error, Reason} ->
            {error, Reason}
    end;
listen(https, Port, SocketOpts, BufferOpts, SSLOpts) when SSLOpts =/= none ->
    case ssl:listen(Port, SocketOpts ++ BufferOpts ++ SSLOpts) of
        {ok, Socket} ->
            {ok, {https, Socket}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec accept(
    socket(),
    pos_integer()
) ->
    {ok, socket()} | {error, tcp_error() | tls_error()}.
accept({http, Socket}, Timeout) ->
    case gen_tcp:accept(Socket, Timeout) of
        {ok, S} ->
            {ok, {http, S}};
        {error, Reason} ->
            {error, Reason}
    end;
accept({https, Socket}, Timeout) ->
    case ssl:transport_accept(Socket, Timeout) of
        {ok, S} ->
            case ssl:handshake(S, Timeout) of
                {ok, S1} ->
                    {ok, {https, S1}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec recv(
    socket(),
    non_neg_integer(),
    non_neg_integer() | infinity
) ->
    {ok, binary()} | {error, any()}.
recv({http, Socket}, Size, Timeout) ->
    case gen_tcp:recv(Socket, Size, Timeout) of
        {ok, Data} when is_binary(Data) ->
            {ok, Data};
        {error, Error} ->
            {error, Error}
    end;
recv({https, Socket}, Size, Timeout) ->
    case ssl:recv(Socket, Size, Timeout) of
        {ok, Data} when is_binary(Data) ->
            {ok, Data};
        {error, Error} ->
            {error, Error}
    end.

-spec recv_line(
    socket(),
    non_neg_integer() | infinity
) ->
    {ok, binary()} | {error, any()}.
recv_line({http, Socket}, Timeout) ->
    maybe
        ok ?= inet:setopts(Socket, [{packet, line}]),
        {ok, Data} ?= gen_tcp:recv(Socket, 0, Timeout),
        ok ?= inet:setopts(Socket, [{packet, raw}]),
        true = is_binary(Data),
        {ok, Data}
    else
        {error, Error} ->
            {error, Error}
    end;
recv_line({https, Socket}, Timeout) ->
    maybe
        ok ?= ssl:setopts(Socket, [{packet, line}]),
        {ok, Data} ?= ssl:recv(Socket, 0, Timeout),
        ok ?= ssl:setopts(Socket, [{packet, raw}]),
        true = is_binary(Data),
        {ok, Data}
    else
        {error, Error} ->
            {error, Error}
    end.

-spec send(socket(), binary()) -> ok | {error, any()}.
send({http, Socket}, Data) ->
    gen_tcp:send(Socket, Data);
send({https, Socket}, Data) ->
    ssl:send(Socket, Data).

-spec close(socket()) -> ok | {error, any()}.
close({http, Socket}) ->
    gen_tcp:close(Socket);
close({https, Socket}) ->
    ssl:close(Socket).

-spec get_peer(socket()) -> {ok, inet:ip_address()} | {error, any()}.
get_peer({http, Socket}) ->
    case inet:peername(Socket) of
        {ok, {Addr, _Port}} when is_tuple(Addr) ->
            {ok, Addr};
        {error, Error} ->
            {error, Error}
    end;
get_peer({https, Socket}) ->
    case ssl:peername(Socket) of
        {ok, {Addr, _Port}} when is_tuple(Addr) ->
            {ok, Addr};
        {error, Error} ->
            {error, Error}
    end.
