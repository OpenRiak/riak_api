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
%% @doc Test handler that is used for triggering error conditions

-module(riak_api_web_trigger).

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
        cleanup/1
    ]
).
-endif.

-record(context, {
    mishandle_nonzero_body = false :: boolean(),
    response_code = 200 :: 200 | 201 | 204
}).

-type context() :: #context{}.

%% @doc match_route for the module
-spec match_route(
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) ->
    nomatch
    | {method_not_allowed, list(riak_api_web_acceptor:method())}
    | {ok, riak_api_web_handler:limits(), context()}.
match_route('PUT', _P, [<<"with_limits">>, HC, HS, BS]) when
    is_binary(HC), is_binary(HS), is_binary(BS)
->
    {
        ok,
        {
            binary_to_integer(HC),
            binary_to_integer(HS),
            binary_to_integer(BS)
        },
        #context{}
    };
match_route(_, _, _) ->
    nomatch.

%% @doc check_permissions for using this module or route
-spec check_permissions(
    riak_api_web_headers:headers(),
    riak_api_web_socket:scheme(),
    riak_api_web_handler:peer_ip(),
    context()
) ->
    {ok, context()}.
check_permissions(_Hdrs, _Scheme, _Peer, Ctx) ->
    {ok, Ctx}.

%% @doc parse and validate query params, passed as a map
-spec parse_query_params(
    riak_api_web_handler:query_params(),
    context()
) ->
    {ok, context()} | riak_api_web_acceptor:halt_response().
parse_query_params(QueryParams, Ctx) ->
    {ok, Ctx1} =
        case lists:keyfind(<<"mishandle_nonzero_body">>, 1, QueryParams) of
            {<<"mishandle_nonzero_body">>, true} ->
                {ok, Ctx#context{mishandle_nonzero_body = true}};
            _ ->
                {ok, Ctx}
        end,
    case lists:keyfind(<<"response_code">>, 1, QueryParams) of
        {<<"response_code">>, RC} when is_binary(RC) ->
            {ok, Ctx1#context{response_code = binary_to_integer(RC)}};
        _ ->
            {ok, Ctx1}
    end.

%% @doc parse and validate the request headers
-spec parse_request_headers(
    riak_api_web_headers:headers(),
    context()
) ->
    {ok, context()} | riak_api_web_acceptor:halt_response().
parse_request_headers(_ReqHeaders, Ctx) ->
    {ok, Ctx}.

%% @doc Process the request and produce a response
-spec process_request(
    riak_api_web_body:req_body() | none,
    context()
) ->
    {
        ok,
        {
            riak_api_web_acceptor:response_code(),
            riak_api_web_headers:header_list(),
            riak_api_web_handler:response_body(),
            boolean(),
            riak_api_web_body:req_body() | none
        },
        context()
    }.
process_request(RqBdy, Ctx) ->
    case {Ctx#context.mishandle_nonzero_body, RqBdy} of
        {true, RqBdy} when RqBdy =/= none ->
            {ok, {200, [], <<>>, true, none}, Ctx};
        {false, none} ->
            {ok, {Ctx#context.response_code, [], <<>>, true, RqBdy}, Ctx};
        {false, RqBdy} ->
            case riak_api_web_body:get_body(RqBdy, all, 10000) of
                {Buffer, UpdBdy} when Buffer =/= error ->
                    {ok, {Ctx#context.response_code, [], <<>>, true, UpdBdy},
                        Ctx}
            end
    end.

%% @doc Record the output of the interaction
-spec record_request(
    riak_api_web_handler:timings(),
    riak_api_web_handler:completion(),
    context()
) ->
    ok.
record_request(_Timings, _Completion, _Ctx) ->
    ok.

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

basic_handler_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun generator/1}.

setup() ->
    inets:start(),
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
    {SpecName, IPAddr, TestPort}.

generator({_SpecName, IPAddr, Port}) ->
    [
        too_many_headers(IPAddr, Port),
        header_too_large(IPAddr, Port),
        non_zero_body(IPAddr, Port),
        zero_body(IPAddr, Port),
        mishandle_nonzero_body(IPAddr, Port),
        handle_bad_uri(IPAddr, Port),
        handle_bad_content_length(IPAddr, Port),
        handle_connection_header_confusion(IPAddr, Port),
        trigger_alternative_response_code(
            IPAddr,
            Port,
            <<"1.0">>,
            201,
            <<"HTTP/1.0 201 Created\r\n">>
        ),
        trigger_alternative_response_code(
            IPAddr,
            Port,
            <<"1.0">>,
            204,
            <<"HTTP/1.0 204 No Content\r\n">>
        ),
        trigger_alternative_response_code(
            IPAddr,
            Port,
            <<"1.0">>,
            202,
            <<"HTTP/1.0 202 Accepted\r\n">>
        ),
        trigger_alternative_response_code(
            IPAddr,
            Port,
            <<"1.1">>,
            201,
            <<"HTTP/1.1 201 Created\r\n">>
        ),
        trigger_alternative_response_code(
            IPAddr,
            Port,
            <<"1.1">>,
            204,
            <<"HTTP/1.1 204 No Content\r\n">>
        ),
        trigger_alternative_response_code(
            IPAddr,
            Port,
            <<"1.1">>,
            202,
            <<"HTTP/1.1 202 Accepted\r\n">>
        )
    ].

request_bin(HC, HS, BS, HeaderSize, BodySize) ->
    request_bin(HC, HS, BS, <<"">>, HeaderSize, BodySize).

request_bin(HC, HS, BS, QP, HeaderSize, BodySize) ->
    <<Header:HeaderSize/binary, _RestHdr/binary>> =
        base64:encode(crypto:strong_rand_bytes(HeaderSize)),
    Body =
        case BodySize of
            "A" ->
                crypto:strong_rand_bytes(10);
            _ ->
                crypto:strong_rand_bytes(BodySize)
        end,
    Rq =
        io_lib:format(
            <<
                "PUT /with_limits/~w/~w/~w?~s HTTP/1.1\r\n"
                "Connection: close\r\n"
                "Content-Length: ~w\r\n"
                "X-Riak-BigHeader: ~s\r\n"
                "Content-Type: application/octet-stream\r\n"
                "\r\n"
                "~w"
            >>,
            [HC, HS, BS, QP, BodySize, Header, Body]
        ),
    iolist_to_binary(Rq).

request_bin_cc(HC, HS, BS, HeaderSize, BodySize, Version) ->
    <<Header:HeaderSize/binary, _RestHdr/binary>> =
        base64:encode(crypto:strong_rand_bytes(HeaderSize)),
    Body = crypto:strong_rand_bytes(BodySize),
    Rq =
        io_lib:format(
            <<
                "PUT /with_limits/~w/~w/~w?QP HTTP/~s\r\n"
                "Connection: close\r\n"
                "Connection: keep-alive\r\n"
                "Content-Length: ~w\r\n"
                "X-Riak-BigHeader: ~s\r\n"
                "Content-Type: application/octet-stream\r\n"
                "\r\n"
                "~w"
            >>,
            [HC, HS, BS, Version, BodySize, Header, Body]
        ),
    iolist_to_binary(Rq).

request_bin_rc(HC, HS, BS, RC, HeaderSize, BodySize, Version) ->
    <<Header:HeaderSize/binary, _RestHdr/binary>> =
        base64:encode(crypto:strong_rand_bytes(HeaderSize)),
    Body = crypto:strong_rand_bytes(BodySize),
    Rq =
        io_lib:format(
            <<
                "PUT /with_limits/~w/~w/~w?response_code=~w HTTP/~s\r\n"
                "Connection: keep-alive\r\n"
                "Content-Length: ~w\r\n"
                "X-Riak-BigHeader: ~s\r\n"
                "Content-Type: application/octet-stream\r\n"
                "\r\n"
                "~w"
            >>,
            [HC, HS, BS, RC, Version, BodySize, Header, Body]
        ),
    iolist_to_binary(Rq).

too_many_headers(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin(1, 1024, 1024, 32, 64),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 431 Request Header Fields Too Large\r\n">>,
            L1
        ),
        ?assertNotMatch(
            nomatch,
            string:find(R1, <<"Headers exceeded maximum count of 1">>)
        ),
        ok = gen_tcp:close(Socket)
    end.

header_too_large(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin(16, 64, 1024, 256, 64),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 431 Request Header Fields Too Large\r\n">>,
            L1
        ),
        ?assertNotMatch(
            nomatch,
            string:find(
                R1,
                <<"Header X-Riak-BigHeader exceeded maximum size of 64">>
            )
        ),
        ok = gen_tcp:close(Socket)
    end.

non_zero_body(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin(16, 2048, 0, 32, 64),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, _R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 413 Content Too Large\r\n">>,
            L1
        ),
        ok = gen_tcp:close(Socket)
    end.

zero_body(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin(16, 2048, 0, 32, 0),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, _R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 200 OK\r\n">>,
            L1
        ),
        ok = gen_tcp:close(Socket)
    end.

mishandle_nonzero_body(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        QP = <<"mishandle_nonzero_body">>,
        Request = request_bin(16, 2048, 1024, QP, 32, 64),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, _R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 500 Internal Server Error\r\n">>,
            L1
        ),
        ok = gen_tcp:close(Socket)
    end.

handle_bad_uri(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin(<<"badly_encoded_con%0tent">>, 2048, 0, 32, 64),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, _R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 400 Bad Request\r\n">>,
            L1
        ),
        ok = gen_tcp:close(Socket)
    end.

handle_bad_content_length(IPAddr, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin(8, 512, 96, 32, "A"),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, _R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            <<"HTTP/1.1 400 Bad Request\r\n">>,
            L1
        ),
        ok = gen_tcp:close(Socket)
    end.

handle_connection_header_confusion(IPAddr, Port) ->
    fun() ->
        {ok, Socket10} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request10 = request_bin_cc(8, 512, 96, 32, 32, <<"1.0">>),
        ok = gen_tcp:send(Socket10, Request10),
        {ok, Data10} = gen_tcp:recv(Socket10, 0),
        {ok, L1, R1} = erlang:decode_packet(line, Data10, []),
        ?assertMatch(
            <<"HTTP/1.0 200 OK\r\n">>,
            L1
        ),
        ?assertMatch(
            nomatch,
            string:find(R1, <<"Connection: keep-alive">>)
        ),
        ?assertNotMatch(
            nomatch,
            string:find(R1, <<"Connection: close">>)
        ),
        ok = gen_tcp:close(Socket10),
        {ok, Socket11} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request11 = request_bin_cc(8, 512, 96, 32, 32, <<"1.1">>),
        ok = gen_tcp:send(Socket11, Request11),
        {ok, Data11} = gen_tcp:recv(Socket11, 0),
        {ok, L2, R2} = erlang:decode_packet(line, Data11, []),
        ?assertMatch(
            <<"HTTP/1.1 200 OK\r\n">>,
            L2
        ),
        ?assertNotMatch(
            nomatch,
            string:find(R2, <<"Connection: keep-alive">>)
        ),
        ?assertMatch(
            nomatch,
            string:find(R2, <<"Connection: close">>)
        ),
        ok = gen_tcp:close(Socket10)
    end.

trigger_alternative_response_code(IPAddr, Port, Version, RC, RM) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                IPAddr,
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        Request = request_bin_rc(16, 512, 256, RC, 32, 64, Version),
        ok = gen_tcp:send(Socket, Request),
        {ok, Data} = gen_tcp:recv(Socket, 0),
        {ok, L1, _R1} = erlang:decode_packet(line, Data, []),
        ?assertMatch(
            RM,
            L1
        ),
        ok = gen_tcp:close(Socket)
    end.

cleanup({SpecName, _IPAddr, _Port}) ->
    ok = inets:stop(),
    ?assertMatch(4, riak_api_web_socket:get_active_pool_size(SpecName)),
    riak_api_web_socket:stop(SpecName),
    ok.

find_available_port([]) ->
    no_port_found;
find_available_port([Port | Rest]) ->
    case gen_tcp:listen(Port, []) of
        {ok, Sock} ->
            ok = gen_tcp:close(Sock),
            Port;
        _ ->
            find_available_port(Rest)
    end.

-endif.
