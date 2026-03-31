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
%% @doc Test handler that responds with random data.

-module(riak_api_web_get_random).

-if(?OTP_RELEASE == 26).
-feature(maybe_expr, enable).
-endif.

-behaviour(riak_api_web_handler).

-export(
    [
        match_route/3,
        check_permissions/4,
        parse_query_params/2,
        parse_request_headers/2,
        process_request/2,
        record_request/3
    ]
).

-ifdef(TEST).
-export(
    [
        setup/0,
        generator/1,
        cleanup/1,
        request_single_value/3
    ]
).
-endif.

-record(context,
    {
        request_id :: non_neg_integer()|undefined,
        required_size :: non_neg_integer()|undefined
    }
).

-type context() :: #context{}.

-define(ID_HEADER_LWR, <<"x-riak-request_id">>).

%% @doc match_route for the module
-spec match_route(
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) -> 
    no_match |
    {method_not_allowed, list(riak_api_web_acceptor:method())} |
    {ok, context(), riak_api_web_handler:limits()}.
match_route('GET', <<"/random_data">>, _SP) ->
    {ok, #context{}, {10, 1024, 128 * 1024}};
match_route(_, <<"/random_data">>, _SP) ->
    {method_not_allowed, ['GET']};
match_route(_, _, _) ->
    no_match.

%% @doc check_permissions for using this module or route
-spec
    check_permissions(
        context(),
        riak_api_web_headers:headers(),
        riak_api_web_socket:scheme(),
        riak_api_web_handler:peer()
    ) -> 
        {ok, context()}.
check_permissions(Ctx, _Hdrs, _Scheme, _Peer) ->
    {ok, Ctx}.

%% @doc parse and validate query params, passed as a map
-spec
    parse_query_params(
        context(),
        riak_api_web_handler:query_params()
    ) -> 
        {ok, context()}|riak_api_web_acceptor:halt_response().
parse_query_params(#context{required_size = undefined}, []) ->
    {halt, 400, [], <<"no required_size parameter">>, []};
parse_query_params(Ctx, []) ->
    {ok, Ctx};
parse_query_params(Ctx, [{<<"required_size">>, RS}|Rest]) ->
    try
        case binary_to_integer(RS) of
            RSI when is_integer(RSI), RSI >= 0 ->
                parse_query_params(Ctx#context{required_size = RSI}, Rest);
            _BadRS ->
                {halt, 400, [], <<"invalid required_size ~0p">>, [RS]}
        end
    catch
        _ : _ ->
            {halt, 400, [], <<"invalid required_size ~0p">>, [RS]}
    end;
parse_query_params(Ctx,[_Other|Rest]) ->
    parse_query_params(Ctx, Rest).

%% @doc parse and validate the request headers
-spec
    parse_request_headers(
        context(),
        riak_api_web_headers:headers()
    ) -> 
        {ok, context()}|riak_api_web_acceptor:halt_response().
parse_request_headers(Ctx, ReqHeaders) ->
    case riak_api_web_headers:lookup(?ID_HEADER_LWR, ReqHeaders, true) of
        undefined ->
            ErrorMsg = <<"request requires x-riak-request_id header">>,
            {halt, 400, [], ErrorMsg, []};
        {_OrigKey, [RequestIDStr]} when is_binary(RequestIDStr) ->
            try
                RequestID = binary_to_integer(RequestIDStr),
                true = RequestID > 0,
                {ok, Ctx#context{request_id = RequestID}}
            catch
                error:badarg ->
                    {halt, 400, [], <<"invalid non-numeric request_id">>, []};
                error:{badmatch,false} ->
                    {halt, 400, [], <<"invalid negative request_id">>, []}
            end;
        {_OrigKey, MultipleIDs} when is_list(MultipleIDs) ->
            {halt, 400, [], <<"multiple request_id provided">>, []}
    end.

%% @doc Process the request and produce a response
-spec
    process_request(
        context(),
        riak_api_web_body:req_body()
    ) ->
        {
            ok,
            context(),
            {
                riak_api_web_acceptor:response_code(),
                riak_api_web_headers:header_list(),
                riak_api_web_handler:response_body(),
                boolean(),
                riak_api_web_body:req_body()
            }
        }.
process_request(Ctx = #context{request_id = RqID, required_size = RS}, RqBdy)
        when is_integer(RqID), is_integer(RS), RS > 0 ->
    Body = crypto:strong_rand_bytes(RS),
    RspHdr =
        {<<"X-Riak-request_id">>, integer_to_binary(RqID)},
    {
        ok,
        Ctx,
        {200, [RspHdr], Body, true, RqBdy}
    }.

%% @doc Record the output of the interaction
-spec record_request(
    context(),
    riak_api_web_handler:timings(),
    riak_api_web_handler:completion()
) -> 
    ok.
record_request(_Ctx, Timings, Completion) ->
    {A, B, C} = Timings,
    io:format(
        user,
        "Request ~w with timings ~0p~n",
        [Completion, {B - A, C - B, C - A}]
    ).


%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

basic_handler_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun generator/1}.

-define(REQUEST_BIN(ID, Size, KeepAlive),
    io_lib:format(
        <<
            "GET /random_data?required_size=~w HTTP/1.1\r\n"
            "X-Riak-request_id: ~w\r\n"
            "Connection: ~w\r\n"
            "Content-Length: 0\r\n"
            "\r\n"
        >>,
        [Size, ID, KeepAlive]
    )
).

-define(BAD_VERSION,
    <<
        "GET /random_data?required_size=~w HTTP1.1\r\n"
        "X-Riak-request_id: 1\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    >>
).

-define(WRONG_URL,
    <<
        "GET /randon_data?required_size=~w HTTP/1.1\r\n"
        "X-Riak-request_id: 1\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    >>
).

-define(POST_NOT_GET,
    <<
        "POST /random_data?required_size=~w HTTP/1.1\r\n"
        "X-Riak-request_id: 1\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    >>
).

setup() ->
    TestPort = find_available_port(lists:seq(8000, 8999)),
    IPAddr = {127, 0, 0, 1},
    SpecName = riak_api_web:spec_name(http, IPAddr, TestPort),
    Options =
        [
            {name, SpecName},
            {ip, IPAddr},
            {port, TestPort},
            {web_acceptor_pool_start_size, 4}
        ],
    {ok, _Pid} = riak_api_web_socket:start_link(Options),
    riak_api_web:add_routes([{10, ?MODULE}]),
    {ok, _HTTPC} = inets:start(httpc, [{profile, test_client}]),
    ok = httpc:set_options([{verbose, false}], test_client),
    {SpecName, IPAddr, TestPort}
    .

generator({_SpecName, IPAddr, Port}) ->
    [
        request_single_value(IPAddr, Port, 32),
        request_single_value(IPAddr, Port, 64),
        request_single_value(IPAddr, Port, 2048),
        pipeline_request_values(IPAddr, Port, 16),
        request_error(IPAddr, Port, ?WRONG_URL, 404),
        request_error(IPAddr, Port, ?POST_NOT_GET, 405),
        request_error(IPAddr, Port, ?BAD_VERSION, 400),
        request_with_httpc(IPAddr, Port, 128),
        request_with_httpc(IPAddr, Port, 16)
    ].

cleanup({SpecName, _IPAddr, _Port}) ->
    ok = inets:stop(),
    ?assertMatch(4, riak_api_web_socket:get_active_pool_size(SpecName)),
    ok.

request_error(IPAddr, Port, Msg, ExpectedCode) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        ok = gen_tcp:send(Socket, Msg),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        ?assertMatch(ok, validate_error(Data, ExpectedCode, Socket)),
        ok = gen_tcp:close(Socket)
    end.

request_with_httpc({A, B, C, D}, Port, Size) ->
    fun() ->
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/random_data?required_size=~w",
                    [A, B, C, D, Port, Size]
                )
            ),
        {ok, {{"HTTP/1.1", 200, "OK"}, ResponseHeaders, ResponseBody}} =
            httpc:request(
                get,
                {
                    URI,
                    [{"X-Riak-request_id", integer_to_binary(1)}]
                },
                [],
                [],
                test_client
            ),
        ?assertMatch(
            {"connection", "keep-alive"},
            lists:keyfind("connection", 1, ResponseHeaders)
        ),
        ?assertMatch(
            {"server", "RiakAPI/4.0 SilverMachine"},
            lists:keyfind("server", 1, ResponseHeaders)
        ),
        SizeL = integer_to_list(Size),
        ?assertMatch(
            {"content-length", SizeL},
            lists:keyfind("content-length", 1, ResponseHeaders)
        ),
        ?assertMatch(
            {"x-riak-request_id", "1"},
            lists:keyfind("x-riak-request_id", 1, ResponseHeaders)
        ),
        ?assertMatch(Size, length(ResponseBody))
    end.

request_single_value(IPAddr, Port, Size) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = ?REQUEST_BIN(1, Size, close),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        ?assertMatch(<<>>, validate_response(Data, Size, Socket)),
        ok = gen_tcp:close(Socket)
    end.

pipeline_request_values(IPAddr, Port, Size) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Requests =
            lists:map(
                fun(I) -> ?REQUEST_BIN(I, Size, 'keep-alive') end,
                lists:seq(1, 5)
            ),
        Request = iolist_to_binary(Requests),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        R1 = validate_response(Data, Size, Socket),
        R2 = validate_response(R1, Size, Socket),
        R3 = validate_response(R2, Size, Socket),
        R4 = validate_response(R3, Size, Socket),
        <<>> = validate_response(R4, Size, Socket),
        ok = gen_tcp:close(Socket)
    end.        

extract_headers(Data, Socket, ExpectedResponseLine) ->
    maybe
        {ok, L1, R1} ?= erlang:decode_packet(line, Data, []),
        ?assertMatch(L1, ExpectedResponseLine),
        {ok, L2, R2} ?= erlang:decode_packet(line, R1, []),
        {ok, L3, R3} ?= erlang:decode_packet(line, R2, []),
        {ok, L4, R4} ?= erlang:decode_packet(line, R3, []),
        {ok, L5, R5} ?= erlang:decode_packet(line, R4, []),
        {ok, MaybeL6, R6} ?= erlang:decode_packet(line, R5, []),
        {ok, L6, Rem} ?=
            case MaybeL6 of
                <<"\r\n">> ->
                    {ok, none, R6};
                MaybeL6 ->
                    case erlang:decode_packet(line, R6, []) of
                        {ok, <<"\r\n">>, R7} ->
                            {ok, MaybeL6, R7};
                        {more, _} ->
                            {more, undefined}
                    end
            end,

        {
            lists:map(
                fun(S) -> hd(string:split(S, <<":">>, leading)) end,
                lists:filter(
                    fun(H) -> H =/= none end,
                    lists:sort([L2, L3, L4, L5, L6])
                )
            ),
            Rem
        }
    else
        {more, _} ->
            {ok, More} = gen_tcp:recv(Socket, 0),
            extract_headers(
                <<Data/binary, More/binary>>,
                Socket,
                ExpectedResponseLine
            )
    end.

validate_response(Data, Size, Socket) ->
    {HeaderKeys, Rem} =
        extract_headers(Data, Socket, <<"HTTP/1.1 200 OK\r\n">>),
    ?assertMatch(
        [
            <<"Connection">>,
            <<"Content-Length">>,
            <<"Date">>,
            <<"Server">>,
            <<"X-Riak-request_id">>
        ],
        HeaderKeys
    ),
    {ok, RspBody, Rest} = erlang:decode_packet(0, Rem, []),
    <<ExpectedBody:Size/binary, RestBody/binary>> = RspBody,
    ?assertMatch(Size, byte_size(ExpectedBody)),
    <<RestBody/binary, Rest/binary>>.

validate_error(Data, ExpectedCode, Socket) ->
    {ExpectedResponseLine, AdditionalHeaderKeys} =
        case ExpectedCode of
            400 ->
                {<<"HTTP/1.0 400 Bad Request\r\n">>, []};
                    % As it was a bad version - can't assume 1.1
            404 ->
                {<<"HTTP/1.1 404 Not Found\r\n">>, []};
            405 ->
                {<<"HTTP/1.1 405 Method Not Allowed\r\n">>, [<<"Allow">>]}
        end,
    {HeaderKeys, _Rem} = extract_headers(Data, Socket, ExpectedResponseLine),
    ExpectedHeaderKeys =
        lists:sort(
            [
                <<"Connection">>,
                <<"Content-Length">>,
                <<"Date">>,
                <<"Server">>
            ] ++ AdditionalHeaderKeys
        ),
    ?assertMatch(ExpectedHeaderKeys, HeaderKeys).

find_available_port([]) ->
    no_port_found;
find_available_port([Port|Rest]) ->
    case gen_tcp:listen(Port, []) of
        {ok, Sock} -> 
            ok = gen_tcp:close(Sock),
            Port;
        _ -> 
            find_available_port(Rest)
    end.

-endif.