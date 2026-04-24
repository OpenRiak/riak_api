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

-module(riak_api_web_ets_store).

-if(?OTP_RELEASE == 26).
-feature(maybe_expr, enable).
-endif.

-behaviour(riak_api_web_handler).

-export(
    [
        match_route/3,
        check_permissions/5,
        parse_query_params/2,
        parse_request_headers/2,
        process_request/2,
        record_request/3,
        slice_stream_fun/1
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

-define(SLICE_SIZE, 10 * 1024).

-record(context, {
    key :: unicode:chardata(),
    method :: 'GET' | 'PUT',
    type :: object | file,
    slice_list = [] :: list({range(), guid()}),
    last_slice_end = 0 :: non_neg_integer()
}).

-type context() :: #context{}.
-type guid() :: binary().
-type range() :: {non_neg_integer(), non_neg_integer()}.

%% @doc match_route for the module
-spec match_route(
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) ->
    nomatch
    | {method_not_allowed, list(riak_api_web_acceptor:method())}
    | {ok, riak_api_web_handler:limits(), context()}.
match_route(Method, _P, [<<"ets_object">>, <<"key">>, Key]) when
    Method == 'GET'; Method == 'PUT'
->
    {
        ok,
        {10, 1024, 16 * 1024},
        #context{key = Key, method = Method, type = object}
    };
match_route(_, _, [<<"ets_object">>, <<"key">>, _Key]) ->
    {method_not_allowed, ['GET', 'PUT']};
match_route(Method, _P, [<<"ets_file">>, <<"filename">>, Key]) when
    Method == 'GET'; Method == 'PUT'
->
    {
        ok,
        {10, 1024, 1024 * 1024},
        #context{key = Key, method = Method, type = object}
    };
match_route(_, _, _) ->
    nomatch.

%% @doc check_permissions for using this module or route
-spec check_permissions(
    riak_api_web_headers:headers(),
    riak_api_web_socket:scheme(),
    riak_api_web_handler:peer_ip(),
    public_key:cert() | undefined,
    context()
) ->
    {ok, context()}.
check_permissions(_Hdrs, _Scheme, _Peer, _Cert, Ctx) ->
    {ok, Ctx}.

%% @doc parse and validate query params, passed as a map
-spec parse_query_params(
    riak_api_web_handler:query_params(),
    context()
) ->
    {ok, context()} | riak_api_web_acceptor:halt_response().
parse_query_params(_Params, Ctx) ->
    {ok, Ctx}.

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
    riak_api_web_body:req_body(),
    context()
) ->
    {
        ok,
        {
            riak_api_web_acceptor:response_code(),
            riak_api_web_headers:header_list(),
            riak_api_web_handler:response_body(),
            boolean(),
            riak_api_web_body:req_body()
        },
        context()
    }.
process_request(
    RqBdy, Ctx = #context{key = Key, method = 'GET', type = object}
) ->
    case ets:lookup(?MODULE, {object, Key}) of
        [{{object, Key}, Value}] ->
            {ok, {200, [], Value, true, RqBdy}, Ctx};
        [] ->
            {ok, {404, [], <<>>, true, RqBdy}, Ctx}
    end;
process_request(
    RqBdy, Ctx = #context{key = Key, method = 'PUT', type = object}
) ->
    case riak_api_web_body:get_body(RqBdy, all, 10000) of
        {Value, UpdRqBdy} when is_binary(Value) ->
            ets:insert(?MODULE, {{object, Key}, Value}),
            ETag = base64:encode(crypto:hash(md5, Value), #{mode => urlsafe}),
            {ok, {204, [{'Etag', ETag}], <<>>, true, UpdRqBdy}, Ctx};
        {error, content_too_large} ->
            {ok, {413, [], <<>>, false, RqBdy}, Ctx}
    end;
process_request(
    RqBdy, Ctx = #context{key = Key, method = 'GET', type = file}
) ->
    case ets:lookup(?MODULE, {file, Key}) of
        [{{file, Key}, SliceList}] ->
            {
                ok,
                {
                    200,
                    [],
                    {stream, slice_stream_fun(lists:sort(SliceList))},
                    true,
                    RqBdy
                },
                Ctx
            };
        [] ->
            {ok, {404, [], <<>>, true, RqBdy}, Ctx}
    end;
process_request(
    RqBdy, Ctx = #context{key = Key, method = 'PUT', type = file}
) ->
    case riak_api_web_body:get_body(RqBdy, ?SLICE_SIZE, 10000) of
        {Slice, UpdRqBdy} when is_binary(Slice) ->
            SliceKey = generate_uuid(),
            SliceSize = byte_size(Slice),
            ets:insert_new(?MODULE, {{slice, SliceKey}, Slice}),
            process_request(
                UpdRqBdy,
                Ctx#context{
                    slice_list =
                        [
                            {
                                {Ctx#context.last_slice_end, SliceSize},
                                SliceKey
                            }
                            | Ctx#context.slice_list
                        ],
                    last_slice_end = Ctx#context.last_slice_end + SliceSize
                }
            );
        {done, UpdRqBdy} ->
            ets:insert(?MODULE, {{file, Key}, Ctx#context.slice_list}),
            ETag =
                base64:encode(
                    crypto:hash(md5, term_to_binary(Ctx#context.slice_list)),
                    #{mode => urlsafe}
                ),
            {ok, {204, [{'Etag', ETag}], <<>>, true, UpdRqBdy}, Ctx};
        {error, content_too_large} ->
            {ok, {413, [], <<>>, false, RqBdy}, Ctx}
    end.

generate_uuid() ->
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    L = io_lib:format(
        "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]
    ),
    list_to_binary(L).

slice_stream_fun([]) ->
    fun() -> done end;
slice_stream_fun(List) ->
    fun() ->
        [{_Range, SliceKey} | Rest] = List,
        [{{slice, SliceKey}, Slice}] = ets:lookup(?MODULE, {slice, SliceKey}),
        {Slice, slice_stream_fun(Rest)}
    end.

%% @doc Record the output of the interaction
-spec record_request(
    riak_api_web_handler:timings(),
    riak_api_web_handler:completion(),
    context()
) ->
    ok.
record_request(Timings, Completion, Ctx) ->
    {A, B, C} = Timings,
    io:format(
        user,
        "Request ~w ~w with timings ~0p~n",
        [Ctx#context.method, Completion, {B - A, C - B, C - A}]
    ).

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("stdlib/include/assert.hrl").

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
    riak_api_web:add_routes([{20, ?MODULE}]),
    ets:new(
        ?MODULE,
        [named_table, public, {read_concurrency, true}]
    ),
    {ok, _HTTPC} = inets:start(httpc, [{profile, test_client}]),
    ok = httpc:set_options([{verbose, false}], test_client),
    {SpecName, IPAddr, TestPort}.

generator({_SpecName, IPAddr, Port}) ->
    [
        put_then_get(IPAddr, Port),
        put_too_big(IPAddr, Port),
        put_big_header(IPAddr, Port),
        put_then_get_file(IPAddr, Port),
        raw_put_then_get_file(IPAddr, Port),
        raw_put_toobig_object(IPAddr, Port)
    ].

cleanup({SpecName, _IPAddr, _Port}) ->
    ok = inets:stop(),
    ?assertMatch(4, riak_api_web_socket:get_active_pool_size(SpecName)),
    riak_api_web_socket:stop(SpecName),
    ok.

raw_put_toobig_object({A, B, C, D}, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                {A, B, C, D},
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        RequestHead =
            <<
                "PUT /ets_object/key/K0006 HTTP/1.1\r\n"
                "Connection: close\r\n"
                "Transfer-Encoding: chunked\r\n"
                "\r\n"
            >>,
        gen_tcp:send(Socket, RequestHead),
        _Hash = send_chunked_4KBobject(Socket),
        ok = inet:setopts(Socket, [{packet, line}]),
        {ok, L1} = gen_tcp:recv(Socket, 0, 10000),
        ?assertMatch(
            <<"HTTP/1.1 413 Content Too Large\r\n">>,
            L1
        ),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, _RspHdrs} = gen_tcp:recv(Socket, 0, 10000),
        ok = gen_tcp:close(Socket)
    end.

raw_put_then_get_file({A, B, C, D}, Port) ->
    fun() ->
        {ok, Socket} =
            gen_tcp:connect(
                {A, B, C, D},
                Port,
                [binary, {packet, raw}, {active, false}]
            ),
        RequestHead =
            <<
                "PUT /ets_file/filename/K0005 HTTP/1.1\r\n"
                "Connection: close\r\n"
                "Transfer-Encoding: chunked\r\n"
                "\r\n"
            >>,
        gen_tcp:send(Socket, RequestHead),
        Hash = send_chunked_4KBobject(Socket),
        ok = inet:setopts(Socket, [{packet, line}]),
        {ok, L1} = gen_tcp:recv(Socket, 0, 10000),
        ?assertMatch(
            <<"HTTP/1.1 204 No Content\r\n">>,
            L1
        ),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, _RspHdrs} = gen_tcp:recv(Socket, 0, 10000),
        ok = gen_tcp:close(Socket),
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/ets_file/filename/~s",
                    [A, B, C, D, Port, <<"K0005">>]
                )
            ),
        {ok, {{"HTTP/1.1", 200, "OK"}, _FetchHeaders, FetchBody}} =
            httpc:request(
                get,
                {URI, []},
                [],
                [{body_format, binary}],
                test_client
            ),
        ?assert(is_binary(FetchBody)),
        ?assertMatch(41020, byte_size(FetchBody)),
        ReturnedHash = crypto:hash(md5, FetchBody),
        ?assertMatch(Hash, ReturnedHash)
    end.

send_chunked_4KBobject(Socket) ->
    TestValue = crypto:strong_rand_bytes((10 * 4092) + 100),
    Hash = crypto:hash(md5, TestValue),
    <<
        Chunk1:4092/binary,
        Chunk2:4092/binary,
        Chunk3:4092/binary,
        Chunk4:4092/binary,
        Chunk5:4092/binary,
        Chunk6:4092/binary,
        Chunk7:4092/binary,
        Chunk8:4092/binary,
        Chunk9:4092/binary,
        Chunk10:4092/binary,
        Chunk11:100/binary
    >> = TestValue,
    lists:foreach(
        fun(Chunk) ->
            Size = integer_to_binary(byte_size(Chunk), 16),
            Bin = iolist_to_binary([Size, <<"\r\n">>, Chunk, <<"\r\n">>]),
            gen_tcp:send(Socket, Bin)
        end,
        [
            Chunk1,
            Chunk2,
            Chunk3,
            Chunk4,
            Chunk5,
            Chunk6,
            Chunk7,
            Chunk8,
            Chunk9,
            Chunk10,
            Chunk11
        ]
    ),
    gen_tcp:send(Socket, <<"0\r\n\r\n">>),
    Hash.

put_then_get_file({A, B, C, D}, Port) ->
    fun() ->
        Key = <<"K0004">>,
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/ets_file/filename/~s",
                    [A, B, C, D, Port, Key]
                )
            ),
        Value = crypto:strong_rand_bytes(100 * 1024),
        Hash = crypto:hash(md5, Value),
        {ok, {{"HTTP/1.1", 204, "No Content"}, _Headers, <<>>}} =
            httpc:request(
                put,
                {URI, [], "application/binary", Value},
                [],
                [{body_format, binary}],
                test_client
            ),
        {ok, {{"HTTP/1.1", 200, "OK"}, _FetchHeaders, FetchBody}} =
            httpc:request(
                get,
                {URI, []},
                [],
                [{body_format, binary}],
                test_client
            ),
        ?assert(is_binary(FetchBody)),
        ?assertMatch(102400, byte_size(FetchBody)),
        ReturnedHash = crypto:hash(md5, FetchBody),
        ?assertMatch(Hash, ReturnedHash)
    end.

put_then_get({A, B, C, D}, Port) ->
    fun() ->
        Key = <<"K0001">>,
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/ets_object/key/~s",
                    [A, B, C, D, Port, Key]
                )
            ),
        {ok, {{"HTTP/1.1", 404, "Not Found"}, Rsp1Headers, _Rsp1Body}} =
            httpc:request(
                get,
                {URI, []},
                [],
                [],
                test_client
            ),
        ?assertMatch(
            {"connection", "keep-alive"},
            lists:keyfind("connection", 1, Rsp1Headers)
        ),
        ?assertMatch(
            {"server", "RiakAPI/4.0 SilverMachine"},
            lists:keyfind("server", 1, Rsp1Headers)
        ),
        Value = crypto:strong_rand_bytes(64),
        ExpectedVTag =
            binary_to_list(
                base64:encode(crypto:hash(md5, Value), #{mode => urlsafe})
            ),
        {ok, {{"HTTP/1.1", 204, "No Content"}, Rsp2Headers, <<>>}} =
            httpc:request(
                put,
                {URI, [], "application/binary", Value},
                [],
                [{body_format, binary}],
                test_client
            ),
        ?assertMatch(
            {"etag", ExpectedVTag},
            lists:keyfind("etag", 1, Rsp2Headers)
        ),
        {ok, {{"HTTP/1.1", 200, "OK"}, _Rsp3Headers, Rsp3Body}} =
            httpc:request(
                get,
                {URI, []},
                [],
                [{body_format, binary}],
                test_client
            ),
        ?assert(is_binary(Rsp3Body))
    end.

put_too_big({A, B, C, D}, Port) ->
    fun() ->
        Key = <<"K0002">>,
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/ets_object/key/~s",
                    [A, B, C, D, Port, Key]
                )
            ),
        Value = crypto:strong_rand_bytes(64 * 1024),
        {ok, {{"HTTP/1.1", 413, "Content Too Large"}, _Rsp2Headers, <<>>}} =
            httpc:request(
                put,
                {URI, [], "application/binary", Value},
                [],
                [{body_format, binary}],
                test_client
            )
    end.

put_big_header({A, B, C, D}, Port) ->
    fun() ->
        Key = <<"K0003">>,
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/ets_object/key/~s",
                    [A, B, C, D, Port, Key]
                )
            ),
        HeaderValue =
            base64:encode(crypto:strong_rand_bytes(2048), #{mode => urlsafe}),
        Value = crypto:strong_rand_bytes(64),
        {
            ok,
            {{"HTTP/1.1", 431, "Request Header Fields Too Large"}, _, RspBdy}
        } =
            httpc:request(
                put,
                {
                    URI,
                    [{"X-Riak-Vclock", HeaderValue}],
                    "application/binary",
                    Value
                },
                [],
                [{body_format, binary}],
                test_client
            ),
        ?assertMatch(
            <<"Header x-riak-vclock exceeded maximum size of 1024">>,
            RspBdy
        )
    end.

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
