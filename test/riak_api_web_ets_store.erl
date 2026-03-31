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
    key :: unicode:chardata(),
    method :: 'GET' | 'PUT',
    type :: object | file
}).

-type context() :: #context{}.

%% @doc match_route for the module
-spec match_route(
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) ->
    no_match
    | {method_not_allowed, list(riak_api_web_acceptor:method())}
    | {ok, context(), riak_api_web_handler:limits()}.
match_route(Method, _P, [<<>>, <<"ets_store">>, <<"key">>, Key]) when
    Method == 'GET'; Method == 'PUT'
->
    {
        ok,
        #context{key = Key, method = Method, type = object},
        {10, 1024, 16 * 1024}
    };
match_route(_, _, [<<>>, <<"ets_store">>, <<"key">>, _Key]) ->
    {method_not_allowed, ['GET', 'PUT']};
match_route(_, _, _) ->
    no_match.

%% @doc check_permissions for using this module or route
-spec check_permissions(
    context(),
    riak_api_web_headers:headers(),
    riak_api_web_socket:scheme(),
    riak_api_web_handler:peer()
) ->
    {ok, context()}.
check_permissions(Ctx, _Hdrs, _Scheme, _Peer) ->
    {ok, Ctx}.

%% @doc parse and validate query params, passed as a map
-spec parse_query_params(
    context(),
    riak_api_web_handler:query_params()
) ->
    {ok, context()} | riak_api_web_acceptor:halt_response().
parse_query_params(Ctx, _Params) ->
    {ok, Ctx}.

%% @doc parse and validate the request headers
-spec parse_request_headers(
    context(),
    riak_api_web_headers:headers()
) ->
    {ok, context()} | riak_api_web_acceptor:halt_response().
parse_request_headers(Ctx, _ReqHeaders) ->
    {ok, Ctx}.

%% @doc Process the request and produce a response
-spec process_request(
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
process_request(
    Ctx = #context{key = Key, method = 'GET', type = object}, RqBdy
) ->
    case ets:lookup(?MODULE, Key) of
        [{Key, Value}] ->
            {ok, Ctx, {200, [], Value, true, RqBdy}};
        [] ->
            {ok, Ctx, {404, [], <<>>, true, RqBdy}}
    end;
process_request(
    Ctx = #context{key = Key, method = 'PUT', type = object}, RqBdy
) ->
    case riak_api_web_body:get_body(RqBdy, all, 10000) of
        {Value, UpdRqBdy} when is_binary(Value) ->
            ets:insert(?MODULE, {Key, Value}),
            ETag = base64:encode(crypto:hash(md5, Value), #{mode => urlsafe}),
            {ok, Ctx, {204, [{'Etag', ETag}], <<>>, true, UpdRqBdy}};
        {error, content_too_large} ->
            {ok, Ctx, {413, [], <<>>, false, RqBdy}}
    end.

%% @doc Record the output of the interaction
-spec record_request(
    context(),
    riak_api_web_handler:timings(),
    riak_api_web_handler:completion()
) ->
    ok.
record_request(Ctx, Timings, Completion) ->
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
        put_big_header(IPAddr, Port)
    ].

cleanup({SpecName, _IPAddr, _Port}) ->
    ok = inets:stop(),
    ?assertMatch(4, riak_api_web_socket:get_active_pool_size(SpecName)),
    riak_api_web_socket:stop(SpecName),
    ok.

put_then_get({A, B, C, D}, Port) ->
    fun() ->
        Key = <<"K0001">>,
        URI =
            lists:flatten(
                io_lib:format(
                    "http://~w.~w.~w.~w:~w/ets_store/key/~s",
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
                    "http://~w.~w.~w.~w:~w/ets_store/key/~s",
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
                    "http://~w.~w.~w.~w:~w/ets_store/key/~s",
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
        ?assertMatch(<<"Header exceeded maximum size of 1024">>, RspBdy)
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
