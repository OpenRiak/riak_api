%% -------------------------------------------------------------------
%%
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
%% @doc Handler for a HTTP connection, where the connection will be associated
%% With a module implementing the riak_api_web_rest behaviour

-module(riak_api_web_acceptor).

-if(?OTP_RELEASE == 26).
-feature(maybe_expr, enable).
-endif.

-export([start_link/1, init/2]).

-export([extend_buffer/4, start_clock/0]).

-include_lib("kernel/include/logger.hrl").

-define(ACCEPT_TIMEOUT, 10000).
-define(RECEIVE_TIMEOUT, 60000).
-define(CONTINUE_RESPONSE, <<"HTTP 1.1 100 Continue">>).

-type response_code() ::
    200..204
    | 206
    | 300..304
    | 400
    | 401..406
    | 408..418
    | 421..429
    | 431
    | 451
    | 500..508.

-type method() ::
    'GET' | 'HEAD' | 'POST' | 'PUT' | 'DELETE'.

-type http_version() ::
    {1, 0} | {1, 1}.

-type halt_response() ::
    {
        halt,
        response_code(),
        riak_api_web_headers:header_list(),
        binary(),
        list()
    }.

-type halt_result() ::
    {
        halt,
        response_code(),
        riak_api_web_headers:header_list(),
        binary(),
        riak_api_web_socket:socket()
    }.
-type good_result() ::
    {
        finish,
        boolean(),
        response_code(),
        riak_api_web_headers:headers(),
        {stream, stream_fun()} | binary(),
        {module(), any()},
        riak_api_web_socket:socket(),
        binary(),
        pos_integer()
    }.

-type stream_fun() :: fun(() -> {ok, binary()} | done).
-type send_fun() :: fun((binary()) -> ok | {error, any()}).

-export_type([halt_response/0, method/0, response_code/0]).

%%%============================================================================
%%% API
%%%============================================================================

-spec start_link(riak_api_web_socket:socket()) -> pid().
start_link(Socket) ->
    spawn_link(?MODULE, init, [self(), Socket]).

-spec init(pid(), riak_api_web_socket:socket()) -> ok.
init(Server, Listener) ->
    case riak_api_web_socket:accept(Listener, ?ACCEPT_TIMEOUT) of
        {ok, Socket} ->
            ok = riak_api_web_socket:acceptor_accepted(Server),
            loop(Socket, <<>>);
        {error, timeout} ->
            init(Server, Listener);
        {error, {tls_alert, Alert}} ->
            ?LOG_WARNING("TLS Alert received ~0p", [Alert]),
            init(Server, Listener);
        {error, closed} ->
            ok;
        {error, Other} ->
            exit({error, Other})
    end.

%%%============================================================================
%%% Primary Loop
%%%============================================================================

-spec loop(riak_api_web_socket:socket(), binary()) -> ok.
loop(Socket, InitBuffer) ->
    %% In the keepalive loop, the send buffer is assumed to be empty
    %% An so pipelining of requests (in parallel) is explicitly not supported
    case handle_request(Socket, InitBuffer) of
        {KeepAlive, Buffer} when KeepAlive == true ->
            loop(Socket, Buffer);
        _Close ->
            riak_api_web_socket:close(Socket),
            ok
    end.

-spec handle_request(
    riak_api_web_socket:socket(),
    binary()
) ->
    {boolean(), binary()} | close.
handle_request(Socket, InitBuffer) ->
    StartTime = os:system_time(microsecond),
    reset_version(),
    RequestResult =
        maybe
            {ok, Peer} = riak_api_web_socket:get_peer(Socket),
            {ok, {Method, RawPath, Version, HdrBuffer}} ?=
                get_request_line(Socket, InitBuffer),
            set_version(Version),
            {ok, {Path, QueryParams}} ?= split_path(RawPath),
            {
                ok,
                CallbackMod,
                InitModCtx,
                {MaxHdrCount, MaxHdrSize, MaxBodySize}
            } ?=
                riak_api_web:get_route(Method, Path),
            {ok, ReqHeaders, BdyBuffer} ?=
                get_request_headers(
                    HdrBuffer,
                    Socket,
                    {MaxHdrCount, MaxHdrSize}
                ),
            {ok, ModCtx1} ?=
                CallbackMod:check_permissions(
                    InitModCtx,
                    ReqHeaders,
                    element(1, Socket),
                    Peer
                ),
            {ok, ModCtx2} ?=
                CallbackMod:parse_query_params(ModCtx1, QueryParams),
            {ok, ModCtx3} ?=
                CallbackMod:parse_request_headers(ModCtx2, ReqHeaders),
            {ok, {CLorChunk, UseGzip}} ?= expect_body(ReqHeaders),
            {ok, InitReqBdy} ?=
                riak_api_web_body:initiate_body(
                    extend_buffer_fun(Socket),
                    BdyBuffer,
                    CLorChunk,
                    UseGzip,
                    MaxBodySize
                ),
            ok ?= send_continue(Socket, ReqHeaders),
            {ok, ModCtx4, {Code, RspHeaders, RspBody, KeepAliveOK, ReqBdy1}} ?=
                CallbackMod:process_request(
                    ModCtx3,
                    InitReqBdy
                ),
            Keepalive =
                request_prefers_keepalive(Version, ReqHeaders) andalso
                    KeepAliveOK,
            MergedRspHeaders =
                riak_api_web_headers:enter_from_list(
                    RspHeaders,
                    default_response_headers(Keepalive)
                ),
            {
                finish,
                Keepalive,
                Code,
                MergedRspHeaders,
                RspBody,
                {CallbackMod, ModCtx4},
                Socket,
                riak_api_web_body:get_buffer(ReqBdy1),
                StartTime
            }
        else
            {halt, HaltRspCode, HaltRspHeaders, HaltRspText, HaltRspSubs} ->
                HaltRspBody = generate_error_body(HaltRspText, HaltRspSubs),
                {halt, HaltRspCode, HaltRspHeaders, HaltRspBody, Socket}
        end,
    handle_response(RequestResult).

%%%============================================================================
%%% Manage Version on Process dictionary
%%%============================================================================

-define(VERSION_KEY, {?MODULE, http_version}).

-spec set_version(http_version()) -> ok.
set_version(Version) when Version == {1, 0}; Version == {1, 1} ->
    put(?VERSION_KEY, Version).

-spec get_version() -> http_version().
get_version() ->
    case get(?VERSION_KEY) of
        undefined ->
            {1, 0};
        Tag ->
            Tag
    end.

-spec reset_version() -> ok.
reset_version() ->
    put(?VERSION_KEY, undefined).

%%%============================================================================
%%% Internal request handling functions
%%%============================================================================

-spec bad_request(binary(), list()) -> halt_response().
bad_request(Error, Subs) ->
    {halt, 400, [], Error, Subs}.

-spec split_path(
    iodata()
) ->
    {
        ok,
        {unicode:chardata(), [{unicode:chardata(), unicode:chardata() | true}]}
    }
    | halt_response().
split_path(URIPath) ->
    case uri_string:normalize(URIPath, [return_map]) of
        URIMap when is_map(URIMap) ->
            Path = maps:get(path, URIMap, <<"">>),
            case uri_string:dissect_query(maps:get(query, URIMap, <<"">>)) of
                QueryParams when is_list(QueryParams) ->
                    {ok, {Path, QueryParams}};
                {error, QTerm, QReason} ->
                    bad_request(
                        <<"Query parameters not parsed ~w  - ~0p">>,
                        [QTerm, QReason]
                    )
            end;
        {error, NTerm, NReason} ->
            bad_request(
                <<"Path cannot be normalized ~w  - ~0p">>,
                [NTerm, NReason]
            )
    end.

-spec extend_buffer(
    riak_api_web_socket:socket(),
    binary(),
    non_neg_integer() | line,
    pos_integer() | undefined
) ->
    binary().
extend_buffer(Socket, Buffer, Needed, Timeout) when is_integer(Needed) ->
    case riak_api_web_socket:recv(Socket, Needed, get_timeout(Timeout)) of
        {ok, Data} when is_binary(Data) ->
            <<Buffer/binary, Data/binary>>;
        {error, Reason} ->
            ?LOG_WARNING(
                "Unexpected failure to read data from client "
                "~w for socket ~0p",
                [Reason, Socket]
            ),
            riak_api_web_socket:close(Socket),
            exit(normal)
    end;
extend_buffer(Socket, Buffer, line, Timeout) ->
    case riak_api_web_socket:recv_line(Socket, get_timeout(Timeout)) of
        {ok, Data} when is_binary(Data) ->
            <<Buffer/binary, Data/binary>>;
        {error, Reason} ->
            ?LOG_WARNING(
                "Unexpected failure to read data from client "
                "~w for socket ~0p",
                [Reason, Socket]
            ),
            riak_api_web_socket:close(Socket),
            exit(normal)
    end.

-spec extend_buffer_fun(
    riak_api_web_socket:socket()
) ->
    riak_api_web_body:buffer_fun().
extend_buffer_fun(Socket) ->
    fun(Buffer, Needed, Timeout) ->
        extend_buffer(Socket, Buffer, Needed, Timeout)
    end.

-spec expect_body(
    riak_api_web_headers:headers()
) ->
    {ok, {non_neg_integer() | chunked, boolean()}} | halt_response().
expect_body(Headers) ->
    ContentLengthH =
        riak_api_web_headers:get_unique_value('Content-Length', Headers),
    Encoding =
        case riak_api_web_headers:get_value('Transfer-Encoding', Headers) of
            MultipleValues when is_list(MultipleValues) ->
                lists:sort(MultipleValues);
            SingleValue ->
                SingleValue
        end,
    case {ContentLengthH, Encoding} of
        {ValBin, Encoding} when is_binary(ValBin) ->
            try
                ContentLength = binary_to_integer(ValBin),
                case {ContentLength, Encoding} of
                    {CL, undefined} when CL >= 0 ->
                        {ok, {CL, false}};
                    {CL, <<"gzip">>} ->
                        {ok, {CL, true}};
                    {_CL, UnsupportedEncoding} ->
                        bad_request(
                            <<
                                "Content length provided with unsupported "
                                "transfer encoding ~0p"
                            >>,
                            [UnsupportedEncoding]
                        )
                end
            catch
                _:_ ->
                    bad_request(<<"Non-integer content length ~0p">>, [ValBin])
            end;
        {undefined, <<"chunked">>} ->
            {ok, {chunked, false}};
        {undefined, [<<"chunked">>, <<"gzip">>]} ->
            {ok, {chunked, true}};
        {undefined, UnexpectedEncoding} ->
            UEWarn = <<"Received encoding ~0p without content length">>,
            bad_request(UEWarn, [UnexpectedEncoding]);
        {{error, multiple_values}, _} ->
            bad_request(<<"Content has non-unique length">>, [])
    end.

-spec generate_error_body(binary(), list(any())) -> binary().
generate_error_body(ErrorText, Subs) ->
    iolist_to_binary(
        io_lib:format(ErrorText, Subs)
    ).

-spec get_request_line(
    riak_api_web_socket:socket(),
    binary()
) ->
    {ok, {method(), binary(), http_version(), binary()}}
    | halt_response().
get_request_line(Socket, Buffer) ->
    case erlang:decode_packet(http_bin, Buffer, []) of
        {more, _} ->
            get_request_line(
                Socket,
                extend_buffer(Socket, Buffer, 0, undefined)
            );
        {ok, {http_request, Method, {abs_path, Path}, Version}, Rest} when
            is_binary(Path)
        ->
            case Version of
                SV when SV == {1, 0}; SV == {1, 1} ->
                    case Method of
                        SM when
                            SM == 'GET';
                            SM == 'HEAD';
                            SM == 'POST';
                            SM == 'PUT';
                            SM == 'DELETE'
                        ->
                            {ok, {SM, Path, SV, Rest}};
                        _USM ->
                            {halt, 405, [], <<>>, []}
                    end;
                _USV ->
                    USVError = <<"Only HTTP 1.0 and 1.1 supported">>,
                    {halt, 505, [], USVError, []}
            end;
        {ok, {http_error, Error}, _} ->
            bad_request(<<"HTTP error on inbound request ~0p">>, [Error]);
        {ok, Unexpected, _} ->
            bad_request(
                <<"Unexpected error on inbound request ~0p">>,
                [Unexpected]
            )
    end.

-spec get_request_headers(
    binary(),
    riak_api_web_socket:socket(),
    {pos_integer(), pos_integer()}
) ->
    {ok, riak_api_web_headers:headers(), binary()}
    | riak_api_web_acceptor:halt_response().
get_request_headers(Buffer, Socket, {MaxCount, MaxSize}) ->
    riak_api_web_headers:parse_request_block(
        Buffer,
        fun(Prev) when is_binary(Prev) ->
            extend_buffer(Socket, Prev, 0, ?RECEIVE_TIMEOUT)
        end,
        {MaxCount, MaxSize}
    ).

-spec request_prefers_keepalive(
    http_version(),
    riak_api_web_headers:headers()
) ->
    boolean().
request_prefers_keepalive({1, 0}, ReqHeaders) ->
    %% https://www.rfc-editor.org/rfc/rfc7230#section-6.1
    %% Note that connection options are case insensitive
    case riak_api_web_headers:get_value('Connection', ReqHeaders) of
        ConnectionOption when is_binary(ConnectionOption) ->
            case string:casefold(ConnectionOption) of
                <<"keep-alive">> ->
                    true;
                _ ->
                    false
            end;
        _ ->
            false
    end;
request_prefers_keepalive({1, 1}, ReqHeaders) ->
    case riak_api_web_headers:get_value('Connection', ReqHeaders) of
        ConnectionOption when is_binary(ConnectionOption) ->
            case string:casefold(ConnectionOption) of
                <<"close">> ->
                    false;
                _ ->
                    true
            end;
        _ ->
            true
    end.

-spec get_timeout(
    undefined | infinity | non_neg_integer()
) ->
    non_neg_integer() | infinity.
get_timeout(undefined) ->
    ?RECEIVE_TIMEOUT;
get_timeout(infinity) ->
    infinity;
get_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Timeout.

%%%============================================================================
%%% Internal response handling functions
%%%============================================================================

-spec handle_response(
    good_result() | halt_result()
) ->
    {boolean(), binary()} | close.
handle_response(
    {
        finish,
        Keepalive,
        RspCode,
        RspHeaders,
        {stream, StreamFun},
        {CallbackMod, Context},
        Socket,
        BufferIn,
        StartTime
    }
) ->
    RequestCompleteTime = os:system_time(microsecond),
    stream_response(
        RspCode,
        RspHeaders,
        StreamFun,
        fun(B) -> riak_api_web_socket:send(Socket, B) end
    ),
    ResponseCompleteTime = os:system_time(microsecond),
    ok =
        CallbackMod:record_request(
            Context,
            {StartTime, RequestCompleteTime, ResponseCompleteTime},
            stream_complete
        ),
    {Keepalive, BufferIn};
handle_response(
    {
        finish,
        Keepalive,
        RspCode,
        RspHeaders,
        RspBody,
        {CallbackMod, Context},
        Socket,
        BufferIn,
        StartTime
    }
) when is_binary(RspBody) ->
    RequestCompleteTime = os:system_time(microsecond),
    send_response(RspCode, RspHeaders, RspBody, Socket),
    ResponseCompleteTime = os:system_time(microsecond),
    ok =
        CallbackMod:record_request(
            Context,
            {StartTime, RequestCompleteTime, ResponseCompleteTime},
            send_complete
        ),
    {Keepalive, BufferIn};
handle_response({halt, RspCode, RspHeaders, RspBody, Socket}) ->
    MergedRspHeaders =
        riak_api_web_headers:enter_from_list(
            RspHeaders,
            default_response_headers(false)
        ),
    send_response(RspCode, MergedRspHeaders, RspBody, Socket),
    close.

-spec send_continue(
    riak_api_web_socket:socket(),
    riak_api_web_headers:headers()
) ->
    ok | {error, term()}.
send_continue(Socket, ReqHeaders) ->
    case riak_api_web_headers:lookup(<<"expect">>, ReqHeaders, true) of
        {_Key, [<<"100-continue">>]} ->
            riak_api_web_socket:send(Socket, ?CONTINUE_RESPONSE);
        _Other ->
            ok
    end.

-spec stream_response(
    response_code(),
    riak_api_web_headers:headers(),
    stream_fun(),
    send_fun()
) ->
    ok.
stream_response(RspCode, RspHeaders, StreamFun, SendFun) ->
    RspLine = get_response_line(get_version(), RspCode),
    FinalHeaders =
        riak_api_web_headers:enter(
            'Transfer-Encoding',
            <<"chunked">>,
            RspHeaders
        ),
    Metadata = riak_api_web_headers:output_response_block(FinalHeaders),
    ok =
        SendFun(
            <<
                RspLine/binary,
                Metadata/binary,
                <<"\r\n">>/binary
            >>
        ),
    stream_response(StreamFun, SendFun).

stream_response(StreamFun, SendFun) ->
    case StreamFun() of
        {<<>>, NextFun} ->
            stream_response(NextFun, SendFun);
        done ->
            SendFun(<<"0\r\n\r\n">>);
        {Bin, NextFun} when is_binary(Bin) ->
            BS = integer_to_binary(byte_size(Bin), 16),
            ok =
                SendFun(
                    <<
                        BS/binary,
                        <<"\r\n">>/binary,
                        Bin/binary,
                        <<"\r\n">>/binary
                    >>
                ),
            stream_response(NextFun, SendFun)
    end.

-spec send_response(
    response_code(),
    riak_api_web_headers:headers(),
    binary(),
    riak_api_web_socket:socket()
) ->
    ok | {error, any()}.
send_response(RspCode, RspHeaders, RspBody, Socket) ->
    riak_api_web_socket:send(
        Socket,
        generate_binary_response(RspCode, RspHeaders, RspBody)
    ).

-spec generate_binary_response(
    response_code(),
    riak_api_web_headers:headers(),
    binary()
) ->
    binary().
generate_binary_response(RspCode, RspHeaders, RspBody) ->
    RspLine = get_response_line(get_version(), RspCode),
    FinalHeaders =
        riak_api_web_headers:enter(
            'Content-Length',
            integer_to_binary(byte_size(RspBody)),
            RspHeaders
        ),
    Metadata = riak_api_web_headers:output_response_block(FinalHeaders),
    <<
        RspLine/binary,
        Metadata/binary,
        <<"\r\n">>/binary,
        RspBody/binary
    >>.

-spec get_response_line(http_version(), response_code()) -> binary().
get_response_line({1, 0}, RspCode) ->
    iolist_to_binary(
        [
            <<"HTTP/1.0 ">>,
            reason_phrase(RspCode),
            <<"\r\n">>
        ]
    );
get_response_line({1, 1}, RspCode) ->
    iolist_to_binary(
        [
            <<"HTTP/1.1 ">>,
            reason_phrase(RspCode),
            <<"\r\n">>
        ]
    ).

-spec start_clock() -> ok.
start_clock() ->
    ?MODULE =
        ets:new(
            ?MODULE,
            [named_table, public, {read_concurrency, true}]
        ),
    ok.

-spec default_response_headers(
    boolean()
) ->
    riak_api_web_headers:headers().
default_response_headers(KeepAlive) ->
    DateHeader =
        case {os:system_time(second), ets:lookup(?MODULE, rfc1123)} of
            {Now, [{rfc1123, {CachedTime, CachedHdr}}]} when
                Now == CachedTime
            ->
                CachedHdr;
            {Now, _} ->
                Hdr = {'Date', list_to_binary(httpd_util:rfc1123_date())},
                ets:insert(?MODULE, {rfc1123, {Now, Hdr}}),
                Hdr
        end,
    ServerHeader = {'Server', <<"RiakAPI/4.0 SilverMachine">>},
    ConnectionHeader =
        case KeepAlive of
            true ->
                {'Connection', <<"keep-alive">>};
            false ->
                {'Connection', <<"close">>}
        end,
    riak_api_web_headers:make_rsp_header(
        [ServerHeader, DateHeader, ConnectionHeader]
    ).

%% @doc
%% The http_util:reason_phrase/1 returns Object Not Found not Not Found
%% these are taken direct from RFC 2616
-spec reason_phrase(response_code()) -> binary().
reason_phrase(200) -> <<"200 OK">>;
reason_phrase(201) -> <<"201 Created">>;
reason_phrase(202) -> <<"202 Accepted">>;
reason_phrase(203) -> <<"203 Non-Authoritative Information">>;
reason_phrase(204) -> <<"204 No Content">>;
reason_phrase(206) -> <<"206 Partial Content">>;
reason_phrase(300) -> <<"300 Multiple Choices">>;
reason_phrase(301) -> <<"301 Moved Permanently">>;
reason_phrase(302) -> <<"302 Found">>;
reason_phrase(303) -> <<"303 See Other">>;
reason_phrase(304) -> <<"304 Not Modified">>;
reason_phrase(400) -> <<"400 Bad Request">>;
reason_phrase(401) -> <<"401 Unauthorized">>;
reason_phrase(402) -> <<"402 Payment Required">>;
reason_phrase(403) -> <<"403 Forbidden">>;
reason_phrase(404) -> <<"404 Not Found">>;
reason_phrase(405) -> <<"405 Method Not Allowed">>;
reason_phrase(406) -> <<"406 Not Acceptable">>;
reason_phrase(408) -> <<"408 Request Timeout">>;
reason_phrase(409) -> <<"409 Conflict">>;
reason_phrase(410) -> <<"410 Gone">>;
reason_phrase(411) -> <<"411 Length Required">>;
reason_phrase(412) -> <<"412 Precondition Failed">>;
reason_phrase(413) -> <<"413 Request Entity Too Large">>;
reason_phrase(414) -> <<"414 Request-URI Too Long">>;
reason_phrase(415) -> <<"415 Unsupported Media Type">>;
reason_phrase(416) -> <<"416 Requested Range Not Satisfiable">>;
reason_phrase(417) -> <<"417 Expectation Failed">>;
reason_phrase(418) -> <<"418 I'm a teapot">>;
reason_phrase(421) -> <<"421 Misdirected Request">>;
reason_phrase(422) -> <<"422 Unprocessable Entity">>;
reason_phrase(423) -> <<"423 Locked">>;
reason_phrase(424) -> <<"424 Failed Dependency">>;
reason_phrase(425) -> <<"425 Unordered Collection">>;
reason_phrase(426) -> <<"426 Upgrade Required">>;
reason_phrase(428) -> <<"428 Precondition Required">>;
reason_phrase(429) -> <<"429 Too Many Requests">>;
reason_phrase(431) -> <<"431 Request Header Fields Too Large">>;
reason_phrase(451) -> <<"451 Unavailable For Legal Reasons">>;
reason_phrase(500) -> <<"500 Internal Server Error">>;
reason_phrase(501) -> <<"501 Not Implemented">>;
reason_phrase(502) -> <<"502 Bad Gateway">>;
reason_phrase(503) -> <<"503 Service Unavailable">>;
reason_phrase(504) -> <<"504 Gateway Timeout">>;
reason_phrase(505) -> <<"505 HTTP Version Not Supported">>;
reason_phrase(506) -> <<"506 Variant Also Negotiates">>;
reason_phrase(507) -> <<"507 Insufficient Storage">>;
reason_phrase(508) -> <<"508 Loop Detected">>.

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

clock_test() ->
    ok = start_clock(),
    {TC1, _Hdrs1} =
        timer:tc(fun() -> default_response_headers(true) end),
    {TC2, _Hdrs2} =
        timer:tc(fun() -> default_response_headers(true) end),
    {TC3, _Hdrs3} =
        timer:tc(fun() -> default_response_headers(false) end),
    {TC4, _Hdrs4} =
        timer:tc(fun() -> default_response_headers(true) end),
    timer:sleep(1000),
    {TC5, _Hdrs5} =
        timer:tc(fun() -> default_response_headers(true) end),
    ?assertMatch(1, ets:info(?MODULE, size)),
    MeanUnCached = (TC1 + TC5) div 2,
    MeanCached = (TC2 + TC3 + TC4) div 3,
    io:format(
        user,
        "Cached ~w micros vs uncached ~w~n",
        [MeanCached, MeanUnCached]
    ),
    ?assert(MeanCached < MeanUnCached),
    ets:delete(?MODULE).

simple_response_test() ->
    ok = start_clock(),
    set_version({1, 1}),
    FullResponse =
        generate_binary_response(
            200,
            default_response_headers(false),
            <<"OutputOK">>
        ),
    Date = list_to_binary(httpd_util:rfc1123_date()),
    ExpectedResponse =
        <<
            <<"HTTP/1.1 200 OK\r\n">>/binary,
            <<"Connection: close\r\n">>/binary,
            <<"Date: ">>/binary,
            Date/binary,
            <<"\r\n">>/binary,
            <<"Server: RiakAPI/4.0 SilverMachine\r\n">>/binary,
            <<"Content-Length: 8\r\n">>/binary,
            <<"\r\n">>/binary,
            <<"OutputOK">>/binary
        >>,
    ?assertMatch(ExpectedResponse, FullResponse),
    ets:delete(?MODULE).

simple_stream_test() ->
    ok = start_clock(),
    SendFun =
        fun(Bin) when is_binary(Bin) ->
            case get({?MODULE, ?TEST, send_buffer}) of
                AccBin when is_binary(AccBin) ->
                    put(
                        {?MODULE, ?TEST, send_buffer},
                        <<AccBin/binary, Bin/binary>>
                    );
                undefined ->
                    put({?MODULE, ?TEST, send_buffer}, Bin)
            end,
            ok
        end,
    put({?MODULE, ?TEST, send_buffer}, undefined),
    Me = self(),
    spawn(
        fun() ->
            Me ! <<"Wiki">>,
            Me ! <<"Pedia ">>,
            Me ! <<"in chunks!">>,
            Me ! done
        end
    ),
    Date = list_to_binary(httpd_util:rfc1123_date()),
    stream_response(
        200,
        default_response_headers(true),
        stream_fun(),
        SendFun
    ),
    Response = get({?MODULE, ?TEST, send_buffer}),
    ExpectedResponse =
        <<
            <<"HTTP/1.1 200 OK\r\n">>/binary,
            <<"Connection: keep-alive\r\n">>/binary,
            <<"Date: ">>/binary,
            Date/binary,
            <<"\r\n">>/binary,
            <<"Transfer-Encoding: chunked\r\n">>/binary,
            <<"Server: RiakAPI/4.0 SilverMachine\r\n">>/binary,
            <<"\r\n">>/binary,
            <<
                "4\r\nWiki\r\n6\r\nPedia "
                "\r\nA\r\nin chunks!\r\n0\r\n\r\n"
            >>/binary
        >>,
    ?assertMatch(ExpectedResponse, Response),
    ets:delete(?MODULE).

stream_fun() ->
    fun() ->
        receive
            Bin when is_binary(Bin) ->
                {Bin, stream_fun()};
            done ->
                done
        end
    end.

expect_test() ->
    FixedLength =
        riak_api_web_headers:make(
            [
                {'Content-Length', <<"1024">>}
            ]
        ),
    ?assertMatch({ok, {1024, false}}, expect_body(FixedLength)),
    FixedLengthGZ =
        riak_api_web_headers:make(
            [
                {'Content-Length', <<"1024">>},
                {'Transfer-Encoding', <<"gzip">>}
            ]
        ),
    ?assertMatch({ok, {1024, true}}, expect_body(FixedLengthGZ)),
    UnsupportedCompress =
        riak_api_web_headers:make(
            [
                {'Content-Length', <<"1024">>},
                {'Transfer-Encoding', <<"deflate">>}
            ]
        ),
    {halt, 400, [], Error1, _} = expect_body(UnsupportedCompress),
    ?assertNotMatch(
        nomatch,
        string:find(Error1, <<"unsupported transfer encoding">>)
    ),
    NoLength =
        riak_api_web_headers:make(
            [
                {'Transfer-Encoding', <<"gzip">>}
            ]
        ),
    {halt, 400, [], Error2, _} = expect_body(NoLength),
    ?assertNotMatch(
        nomatch,
        string:find(Error2, <<"without content length">>)
    ),
    ContentSmuggle =
        riak_api_web_headers:make(
            [
                {'Content-Length', <<"1024">>},
                {'Transfer-Encoding', <<"gzip">>},
                {'Content-Length', <<"262144">>}
            ]
        ),
    {halt, 400, [], Error3, _} = expect_body(ContentSmuggle),
    ?assertNotMatch(
        nomatch,
        string:find(Error3, <<"non-unique length">>)
    ).

-endif.
