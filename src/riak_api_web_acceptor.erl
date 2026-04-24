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

-export([extend_buffer/4, compile_detectors/0]).

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
    'OPTIONS' | 'GET' | 'HEAD' | 'POST' | 'PUT' | 'DELETE' | 'TRACE'.

-type http_version() ::
    {1, 0} | {1, 1}.

-type halt_response() ::
    {
        halt,
        response_code(),
        riak_api_web_headers:header_list(),
        binary(),
        list(term())
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
            {ok, PeerIP, Cert} = riak_api_web_socket:get_peer(Socket),
            loop(Socket, <<>>, PeerIP, Cert);
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

-spec loop(
    riak_api_web_socket:socket(),
    binary(),
    inet:ip_address(),
    public_key:cert()|undefined
) -> 
    ok.
loop(Socket, InitBuffer, PeerIP, Cert) ->
    %% In the keepalive loop, the send buffer is assumed to be empty
    %% An so pipelining of requests (in parallel) is explicitly not supported
    case handle_request(Socket, InitBuffer, PeerIP, Cert) of
        {KeepAlive, Buffer} when KeepAlive == true ->
            loop(Socket, Buffer, PeerIP, Cert);
        _Close ->
            riak_api_web_socket:close(Socket),
            ok
    end.

-spec handle_request(
    riak_api_web_socket:socket(),
    binary(),
    inet:ip_address(),
    public_key:cert()|undefined
) ->
    {boolean(), binary()} | close.
handle_request(Socket, InitBuffer, PeerIP, Cert) ->
    StartTime = os:system_time(microsecond),
    reset_version(),
    RequestResult =
        maybe
            {ok, {Method, RawPath, Version, HdrBuffer}} ?=
                get_request_line(Socket, InitBuffer),
            set_version(Version),
            {ok, {Path, SplitPath, QueryParams}} ?= split_path(RawPath),
            {
                ok,
                CallbackMod,
                {MaxHdrCount, MaxHdrSize, MaxBodySize},
                InitModCtx
            } ?=
                riak_api_web:get_route(Method, Path, SplitPath),
            {ok, ReqHeaders, BdyBuffer} ?=
                get_request_headers(
                    HdrBuffer,
                    Socket,
                    {MaxHdrCount, MaxHdrSize}
                ),
            {ok, ModCtx1} ?=
                CallbackMod:check_permissions(
                    ReqHeaders,
                    element(1, Socket),
                    PeerIP,
                    Cert,
                    InitModCtx
                ),
            {ok, ModCtx2} ?=
                CallbackMod:parse_query_params(QueryParams, ModCtx1),
            {ok, ModCtx3} ?=
                CallbackMod:parse_request_headers(ReqHeaders, ModCtx2),
            {ok, {CLorChunk, UseGzip}} ?= expect_body(ReqHeaders),
            {ok, InitReqBody} ?=
                riak_api_web_body:initiate_body(
                    extend_buffer_fun(Socket),
                    BdyBuffer,
                    CLorChunk,
                    UseGzip,
                    MaxBodySize
                ),
            ok ?= send_continue(Socket, ReqHeaders),
            {ok, NextReqBody, CallbackReqBody} ?=
                case MaxBodySize of
                    N when N == 0 ->
                        case riak_api_web_body:confirm_empty(InitReqBody) of
                            {ok, RemBody} ->
                                {ok, RemBody, none};
                            {error, content_too_large} ->
                                {
                                    halt,
                                    413,
                                    [{'Content-Type', <<"text/plain">>}],
                                    <<>>,
                                    []
                                }
                        end;
                    _N ->
                        {ok, none, InitReqBody}
                end,
            {ok, {Code, RspHeaders, RspBody, KeepAliveOK, RetBody}, ModCtx4} ?=
                CallbackMod:process_request(
                    CallbackReqBody,
                    ModCtx3
                ),
            {ok, BufferNext} ?=
                case {NextReqBody, RetBody} of
                    {NextReqBody, none} when NextReqBody =/= none ->
                        {ok, riak_api_web_body:get_buffer(NextReqBody)};
                    {none, RetBody} when RetBody =/= none ->
                        {ok, riak_api_web_body:get_buffer(RetBody)};
                    _ ->
                        WarnText =
                            "Incorrect handling of request body buffer in"
                            " callback module ~w",
                        ?LOG_WARNING(WarnText, [CallbackMod]),
                        {
                            halt,
                            500,
                            [{'Content-Type', <<"text/plain">>}],
                            <<"Error handling request body">>,
                            []
                        }
                end,
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
                BufferNext,
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

%% @doc %% @doc Call this function when initialising API
-spec compile_detectors() -> ok.
compile_detectors() ->
    CP = binary:compile_pattern([<<"%">>, <<".">>]),
    persistent_term:put({?MODULE, compile_patterns}, CP).

-spec normalise_path(binary()) -> uri_string:uri_map() | uri_string:error().
normalise_path(URI) ->
    CP = persistent_term:get({?MODULE, compile_patterns}),
    case binary:match(URI, CP) of
        nomatch ->
            % There is no percent-encoded content, or no path reversing, and
            % so it is safe to parse rather than normalise
            uri_string:parse(URI);
        _ ->
            case uri_string:normalize(URI, [return_map]) of
                URIMap when is_map(URIMap) ->
                    uri_string:percent_decode(URIMap);
                {error, Type, Detail} ->
                    {error, Type, Detail}
            end
    end.

-spec split_path(
    binary()
) ->
    {
        ok,
        {
            unicode:chardata(),
            list(unicode:chardata()),
            [{unicode:chardata(), unicode:chardata() | true}]
        }
    }
    | halt_response().
split_path(URIPath) ->
    case normalise_path(URIPath) of
        URIMap when is_map(URIMap) ->
            PathN = maps:get(path, URIMap, <<>>),
            QueryParamsN = maps:get(query, URIMap, <<>>),
            SplitPath = binary:split(PathN, <<"/">>, [global, trim_all]),
            case uri_string:dissect_query(QueryParamsN) of
                QueryParams when is_list(QueryParams) ->
                    {ok, {PathN, SplitPath, QueryParams}};
                {error, QTerm, QReason} ->
                    bad_request(
                        <<"Query parameters not parsed ~w  - ~0p">>,
                        [QTerm, QReason]
                    )
            end;
        {error, NTerm, NReason} ->
            bad_request(
                <<"Path cannot be normalized ~w - ~0p">>,
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
        {error, closed} ->
            riak_api_web_socket:close(Socket),
            exit(normal);
        {error, Reason} ->
            log_unexpected_recv(Socket, Reason),
            exit(normal)
    end;
extend_buffer(Socket, Buffer, line, Timeout) ->
    case riak_api_web_socket:recv_line(Socket, get_timeout(Timeout)) of
        {ok, Data} when is_binary(Data) ->
            <<Buffer/binary, Data/binary>>;
        {error, Reason} ->
            log_unexpected_recv(Socket, Reason),
            exit(normal)
    end.

-spec log_unexpected_recv(
    riak_api_web_socket:socket(),
    term()
) ->
    ok | {error, term()}.
log_unexpected_recv(Socket, Reason) ->
    LogText = "Unexpected failure to read data from client ~w for socket ~0p",
    ?LOG_WARNING(LogText, [Reason, Socket]),
    riak_api_web_socket:close(Socket).

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
        {undefined, undefined} ->
            % Assume no content - and set content-length to 0
            {ok, {0, false}};
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
            is_binary(Path), is_atom(Method)
        ->
            case Version of
                SV when SV == {1, 0}; SV == {1, 1} ->
                    {ok, {Method, Path, SV, Rest}};
                _USV ->
                    USVError = <<"Only HTTP 1.0 and 1.1 supported">>,
                    {halt, 505, [], USVError, []}
            end;
        {ok, {http_request, Method, _, _}, _Rest} when is_atom(Method) ->
            bad_request(<<"Absolute path required not full or relative">>, []);
        {ok, {http_error, Error}, _} ->
            bad_request(<<"HTTP error on inbound request ~0p">>, [Error]);
        {ok, _Unexpected, _} ->
            bad_request(
                <<"Unexpected request line ~0p">>,
                [Buffer]
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
            {StartTime, RequestCompleteTime, ResponseCompleteTime},
            stream_complete,
            Context
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
            {StartTime, RequestCompleteTime, ResponseCompleteTime},
            send_complete,
            Context
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

%% @doc
%% For performance reasons pre-create the whole line for the most common
%% scenarios
-spec get_response_line(http_version(), response_code()) -> binary().
get_response_line({1, 0}, 200) ->
    <<"HTTP/1.0 200 OK\r\n">>;
get_response_line({1, 0}, 201) ->
    <<"HTTP/1.0 201 Created\r\n">>;
get_response_line({1, 0}, 204) ->
    <<"HTTP/1.0 204 No Content\r\n">>;
get_response_line({1, 1}, 200) ->
    <<"HTTP/1.1 200 OK\r\n">>;
get_response_line({1, 1}, 201) ->
    <<"HTTP/1.1 201 Created\r\n">>;
get_response_line({1, 1}, 204) ->
    <<"HTTP/1.1 204 No Content\r\n">>;
get_response_line({1, 0}, Code) ->
    iolist_to_binary(
        [
            <<"HTTP/1.0 ">>,
            integer_to_binary(Code),
            <<" ">>,
            reason_phrase(Code),
            <<"\r\n">>
        ]
    );
get_response_line({1, 1}, Code) ->
    iolist_to_binary(
        [
            <<"HTTP/1.1 ">>,
            integer_to_binary(Code),
            <<" ">>,
            reason_phrase(Code),
            <<"\r\n">>
        ]
    ).

-spec default_response_headers(
    boolean()
) ->
    riak_api_web_headers:headers().
default_response_headers(KeepAlive) ->
    DateHeader = {'Date', riak_api_web:rfc1123_date_now()},
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
%% these are taken direct from RFC 2616.  Likewise "Request Entity Too Large"
%% rather than the more common "Content Too Large"
-spec reason_phrase(response_code()) -> binary().
reason_phrase(404) -> <<"Not Found">>;
reason_phrase(413) -> <<"Content Too Large">>;
reason_phrase(431) -> <<"Request Header Fields Too Large">>;
reason_phrase(N) -> httpd_util:reason_phrase(N).

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/assert.hrl").

request_line_decode_test() ->
    ?assertMatch(
        {halt, 400, [], <<"Absolute path required not full or relative">>, []},
        get_request_line(
            test_socket,
            <<"GET no-leading-slash/relative HTTP/1.1\r\n">>
        )
    ),
    ?assertMatch(
        {halt, 400, [], <<"Absolute path required not full or relative">>, []},
        get_request_line(
            test_socket,
            <<"GET http://localhost:8000/full-path HTTP/1.1\r\n">>
        )
    ),
    ?assertMatch(
        {halt, 400, [], <<"Absolute path required not full or relative">>, []},
        get_request_line(
            test_socket,
            <<"GET @ref HTTP/1.1\r\n">>
        )
    ),
    ?assertMatch(
        {
            halt,
            400,
            [],
            <<"HTTP error on inbound request ~0p">>,
            [<<"GET @ref HTP/1.1\r\n">>]
        },
        get_request_line(
            test_socket,
            <<"GET @ref HTP/1.1\r\n">>
        )
    ),
    ?assertMatch(
        {halt, 505, [], <<"Only HTTP 1.0 and 1.1 supported">>, []},
        get_request_line(test_socket, <<"GET /stats HTTP/2.0\r\n">>)
    ),
    % If the method is not supported at all, then give general error - as it is
    % not possible to know what methods are allowed on the URL - this can only
    % be determined when matching routes
    ?assertMatch(
        {
            halt,
            400,
            [],
            <<"Unexpected request line ~0p">>,
            [<<"PATCH /stats HTTP/1.0\r\n">>]
        },
        get_request_line(test_socket, <<"PATCH /stats HTTP/1.0\r\n">>)
    ).

simple_response_test() ->
    ok = riak_api_web:cache_today(),
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
    ?assertMatch(ExpectedResponse, FullResponse).

simple_stream_test() ->
    ok = riak_api_web:cache_today(),
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
    ?assertMatch(ExpectedResponse, Response).

stream_fun() ->
    fun() ->
        receive
            Bin when is_binary(Bin) ->
                {Bin, stream_fun()};
            done ->
                done
        end
    end.

normalise_path_test() ->
    compile_detectors(),
    URI1 = <<"types/BT/buckets/B/keys/K?return_terms">>,
    URI2 = <<"types/BT/buckets/../buckets/B/key%73/K?return_term%73">>,
    {ok, Output1} = split_path(URI1),
    {ok, Output2} = split_path(URI2),
    ?assertMatch(Output1, Output2),
    URI3 = <<"types/T/buckets/Swedes/keys/%C3%85berg?return_terms">>,
    {ok, {_, SP, _}} = split_path(URI3),
    [<<"types">>, <<"T">>, <<"buckets">>, <<"Swedes">>, <<"keys">>, Name] = SP,
    ?assertMatch(<<"Åberg"/utf8>>, Name).

expect_test() ->
    FixedLength =
        riak_api_web_headers:make(
            [
                {'Content-Length', <<"1024">>}
            ]
        ),
    ?assertMatch({ok, {1024, false}}, expect_body(FixedLength)),
    Empty = riak_api_web_headers:make([]),
    % e.g. just curl GET from command line - no encoding or content-length
    ?assertMatch({ok, {0, false}}, expect_body(Empty)),
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
