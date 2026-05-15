%% -------------------------------------------------------------------
%%
%% riak_api_web: setup Riak's HTTP interface
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
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

%% @doc Convenience functions for setting up the HTTP interface
%%      of Riak.
-module(riak_api_web).

-export(
    [
        get_listeners/0,
        binding_config/2,
        add_routes/1,
        add_routes/2,
        get_route/4,
        get_all_routes/0,
        spec_name/3,
        rfc1123_date/1,
        rfc1123_date/2,
        rfc1123_date_now/0,
        cache_today/0
    ]
).

-type binding() :: {inet:ip_address(), inet:port_number()}.
-type route() :: {1..100, module()}.

%%%============================================================================
%%% Routing
%%%============================================================================

-spec add_routes(list(route())) -> ok.
add_routes(Routes) ->
    add_routes(default, Routes).

-spec add_routes(
    inet:port_number() | default,
    list(route())
) ->
    ok.
add_routes(Port, Routes) ->
    CurrentRoutes = persistent_term:get({?MODULE, routes, Port}, []),
    NewRoutes = lists:keysort(1, CurrentRoutes ++ Routes),
    persistent_term:put({?MODULE, routes, Port}, NewRoutes).

-spec get_route(
    inet:port_number(),
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) ->
    {
        ok,
        module(),
        {pos_integer(), pos_integer(), non_neg_integer()},
        any()
    }
    | riak_api_web_acceptor:halt_response().
get_route(Port, Method, Path, SplitPath) ->
    select_route(current_routes(Port), Method, Path, SplitPath, false).

-spec current_routes(pos_integer()) -> list(route()).
current_routes(Port) ->
    persistent_term:get(
        {?MODULE, routes, Port},
        persistent_term:get({?MODULE, routes, default}, [])
    ).

-spec get_all_routes() -> #{pos_integer() | default => list(route())}.
get_all_routes() ->
    maps:from_list(
        lists:filtermap(
            fun({K, V}) ->
                case K of
                    {?MODULE, routes, P} when is_integer(P); P == default ->
                        {true, {P, V}};
                    _ ->
                        false
                end
            end,
            persistent_term:get()
        )
    ).

-spec select_route(
    list(route()),
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata()),
    false | {true, list(riak_api_web_acceptor:method())}
) ->
    {
        ok,
        module(),
        {pos_integer(), pos_integer(), non_neg_integer()},
        any()
    }
    | riak_api_web_acceptor:halt_response().
select_route([], _Method, _Path, _SP, false) ->
    {halt, 404, [], <<>>, []};
select_route([], _Method, _Path, _SP, {true, AllowedMethods}) ->
    AllowHdrVal =
        iolist_to_binary(
            lists:join(
                <<", ">>,
                lists:map(
                    fun atom_to_binary/1,
                    lists:usort(AllowedMethods)
                )
            )
        ),
    {halt, 405, [{'Allow', AllowHdrVal}], <<>>, []};
select_route([{_P, CallbackMod} | Rest], Method, Path, SplitPath, MNA) ->
    case CallbackMod:match_route(Method, Path, SplitPath) of
        nomatch ->
            select_route(Rest, Method, Path, SplitPath, MNA);
        {method_not_allowed, AllowedMethods} ->
            UpdAMs =
                case MNA of
                    false ->
                        AllowedMethods;
                    {true, AlreadyAllowedMethods} ->
                        AllowedMethods ++ AlreadyAllowedMethods
                end,
            select_route(Rest, Method, Path, SplitPath, {true, UpdAMs});
        {ok, {MaxHdrCount, MaxHdrSize, MaxBodySize}, Context} when
            MaxHdrCount > 0, MaxHdrSize > 0, MaxBodySize >= 0
        ->
            {ok, CallbackMod, {MaxHdrCount, MaxHdrSize, MaxBodySize}, Context}
    end.

%%%============================================================================
%%% Configure and Initiate Listeners
%%%============================================================================

get_listeners() ->
    get_listeners(http) ++ get_listeners(https).

-spec get_listeners(http | https) -> list({https | https, binding()}).
get_listeners(Scheme) ->
    Listeners = application:get_env(riak_api, Scheme, []),
    lists:usort([{Scheme, Binding} || Binding <- Listeners]).

-spec binding_config(
    http | https,
    {string() | tuple(), pos_integer()}
) ->
    supervisor:child_spec().
binding_config(Scheme, Binding) ->
    {Ip, Port} = Binding,
    Name = spec_name(Scheme, Ip, Port),
    Config = spec_from_binding(Scheme, Name, Binding),
    #{
        id => Name,
        start => {riak_api_web_socket, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [riak_api_web_socket]
    }.

spec_from_binding(http, Name, {Ip, Port}) ->
    lists:flatten(
        [
            {name, Name},
            {ip, Ip},
            {port, Port},
            {nodelay, true}
        ],
        common_config()
    );
spec_from_binding(https, Name, {Ip, Port}) ->
    lists:flatten(
        [
            {name, Name},
            {ip, Ip},
            {port, Port},
            {ssl, true},
            {ssl_opts, riak_api_ssl:options()},
            {nodelay, true}
        ],
        common_config()
    ).

%% @doc For Ipv6 address - https://www.rfc-editor.org/rfc/rfc2732
%% The expectation based on the cuttlefish IP datatype is that both IP4 and
%% IP6 address will be returned as tuples of integers of full length (4 for IP4
%% and 8 for IP6)
%% However - cuttlefish may retain the parsed address as a string
%% e.g.
%% application:get_env(riak_api, http, []).
%% [{"127.0.0.1",8098}]
%% Either scenario is handled.
%% There may be issues with addresses added by advanced.config in alternative
%% formats - so backwards compatibility maintained (although ipV6 address now
%% are encapsulated in [] in 4.0)
spec_name(Scheme, Ip, Port) when is_integer(Port) ->
    FormattedIP =
        if
            is_tuple(Ip), tuple_size(Ip) == 4 ->
                inet_parse:ntoa(Ip);
            is_tuple(Ip), tuple_size(Ip) == 8 ->
                [$[, inet_parse:ntoa(Ip), $]];
            true ->
                Ip
        end,
    iolist_to_binary(
        lists:flatten(
            io_lib:format("~s://~s:~w", [Scheme, FormattedIP, Port])
        )
    ).

common_config() ->
    [
        {log_dir,
            app_helper:get_env(
                riak_api,
                http_logdir,
                app_helper:get_env(riak_core, platform_log_dir, "log")
            )},
        {backlog, 128}
    ].

%%%============================================================================
%%% RFC1123 Clock Management
%%%============================================================================

-spec cache_today() -> ok.
cache_today() ->
    {Date, Time} = calendar:now_to_universal_time(os:timestamp()),
    case persistent_term:get({?MODULE, cache_today}, undefined) of
        {Date, _DateBin} ->
            ok;
        _ ->
            <<DateBin:17/binary, _/binary>> = rfc1123_date(Date, Time),
            persistent_term:put({?MODULE, cache_today}, {Date, DateBin})
    end.

-spec rfc1123_date_now() -> binary().
rfc1123_date_now() ->
    {Date, Time} = calendar:now_to_universal_time(os:timestamp()),
    case persistent_term:get({?MODULE, cache_today}, undefined) of
        {CachedDate, DateBin} when CachedDate == Date ->
            rfc1123_date(DateBin, Time);
        _ ->
            spawn(fun cache_today/0),
            rfc1123_date(Date, Time)
    end.

-spec rfc1123_date(erlang:timestamp()) -> binary().
rfc1123_date(TS) ->
    {Date, Time} = calendar:now_to_universal_time(TS),
    rfc1123_date(Date, Time).

rfc1123_date({YYYY, MM, DD}, {Hr, Mn, Sc}) ->
    DateBin =
        <<
            (day_bin(calendar:day_of_the_week({YYYY, MM, DD})))/binary,
            (i2_bin(DD))/binary,
            (mon_bin(MM))/binary,
            (integer_to_binary(YYYY))/binary,
            <<" ">>/binary
        >>,
    rfc1123_date(DateBin, {Hr, Mn, Sc});
rfc1123_date(DateBin, {Hr, Mn, Sc}) when is_binary(DateBin) ->
    <<
        DateBin/binary,
        (i2_bin(Hr))/binary,
        $:,
        (i2_bin(Mn))/binary,
        $:,
        (i2_bin(Sc))/binary,
        <<" GMT">>/binary
    >>.

i2_bin(I) when I < 10 ->
    <<$0, (integer_to_binary(I))/binary>>;
i2_bin(I) ->
    integer_to_binary(I).

day_bin(1) ->
    <<"Mon, ">>;
day_bin(2) ->
    <<"Tue, ">>;
day_bin(3) ->
    <<"Wed, ">>;
day_bin(4) ->
    <<"Thu, ">>;
day_bin(5) ->
    <<"Fri, ">>;
day_bin(6) ->
    <<"Sat, ">>;
day_bin(7) ->
    <<"Sun, ">>.

mon_bin(1) ->
    <<" Jan ">>;
mon_bin(2) ->
    <<" Feb ">>;
mon_bin(3) ->
    <<" Mar ">>;
mon_bin(4) ->
    <<" Apr ">>;
mon_bin(5) ->
    <<" May ">>;
mon_bin(6) ->
    <<" Jun ">>;
mon_bin(7) ->
    <<" Jul ">>;
mon_bin(8) ->
    <<" Aug ">>;
mon_bin(9) ->
    <<" Sep ">>;
mon_bin(10) ->
    <<" Oct ">>;
mon_bin(11) ->
    <<" Nov ">>;
mon_bin(12) ->
    <<" Dec ">>.

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

wm_rfc1123_date(TS) ->
    {{YYYY, MM, DD}, {Hour, Min, Sec}} = calendar:now_to_universal_time(TS),
    DayNumber = calendar:day_of_the_week({YYYY, MM, DD}),
    iolist_to_binary(
        lists:flatten(
            io_lib:format(
                "~s, ~2.2.0w ~3.s ~4.4.0w ~2.2.0w:~2.2.0w:~2.2.0w GMT",
                [
                    httpd_util:day(DayNumber),
                    DD,
                    httpd_util:month(MM),
                    YYYY,
                    Hour,
                    Min,
                    Sec
                ]
            )
        )
    ).

date_speed_test() ->
    {_, S, MicroS} = os:timestamp(),
    Dates = lists:map(fun(I) -> {775 + I, S, MicroS} end, lists:seq(1, 1000)),
    {TC1, DL1} =
        timer:tc(
            fun() -> lists:map(fun(TS) -> rfc1123_date(TS) end, Dates) end
        ),
    {TC2, DL2} =
        timer:tc(
            fun() -> lists:map(fun(TS) -> wm_rfc1123_date(TS) end, Dates) end
        ),
    io:format(user, "Timing for ours ~w vs wm ~w~n", [TC1, TC2]),
    ?assert(DL1 == DL2),

    PreCalcDates = lists:map(fun(<<D:17/binary, _/binary>>) -> D end, DL1),
    NewInputs = lists:zip(PreCalcDates, Dates),
    {TC3, DL3} =
        timer:tc(
            fun() ->
                lists:map(
                    fun({CachedDate, TS}) ->
                        rfc1123_date(
                            CachedDate,
                            element(2, calendar:now_to_universal_time(TS))
                        )
                    end,
                    NewInputs
                )
            end
        ),
    io:format(user, "With pre-cached dates ~w~n", [TC3]),
    ?assert(DL1 == DL3).

check_date_is_autocached_test() ->
    persistent_term:erase({?MODULE, cache_today}),
    rfc1123_date_now(),
    true =
        lists:foldl(
            fun(I, Acc) ->
                case Acc of
                    true ->
                        true;
                    false ->
                        timer:sleep(I),
                        not_cached =/=
                            persistent_term:get(
                                {?MODULE, cache_today}, not_cached
                            )
                end
            end,
            false,
            lists:seq(1, 100)
        ),
    rfc1123_date_now().

spec_name_test() ->
    %% Taken from https://www.rfc-editor.org/rfc/rfc2732 - but lowercase hex
    Part = [16#FEDC, 16#BA98, 16#7654, 16#3210],
    E1 = list_to_tuple(Part ++ Part),
    E2 = {16#1080, 0, 0, 0, 8, 16#800, 16#200C, 16#417A},
    E3 = {16#3FFE, 16#2A00, 16#100, 16#7031, 0, 0, 0, 1},
    E4 = {16#1080, 0, 0, 0, 16#8, 16#800, 16#200C, 16#417A},
    Scheme = http,
    Port = 8080,
    ?assertMatch(
        <<"http://[fedc:ba98:7654:3210:fedc:ba98:7654:3210]:8080">>,
        spec_name(Scheme, E1, Port)
    ),
    ?assertMatch(
        <<"http://[1080::8:800:200c:417a]:8080">>,
        spec_name(Scheme, E2, Port)
        % this gets re-summarised by parse_address (not as in the RFC)
    ),
    ?assertMatch(
        <<"http://[3ffe:2a00:100:7031::1]:8080">>,
        spec_name(Scheme, E3, Port)
    ),
    ?assertMatch(
        <<"http://[1080::8:800:200c:417a]:8080">>,
        spec_name(Scheme, E4, Port)
    ),
    ?assertMatch(
        <<"http://127.0.0.1:8098">>,
        spec_name("http", "127.0.0.1", 8098)
    ),
    ?assertMatch(
        <<"http://127.0.0.1:8098">>,
        spec_name("http", {127, 0, 0, 1}, 8098)
    ).

load_routes_test() ->
    clear_all_routes(),
    add_routes(80, [{10, riak_api_web_ets_store}]),
    add_routes([{20, riak_api_web_get_random}, {10, riak_api_web_trigger}]),
    ?assertMatch(
        [{10, riak_api_web_ets_store}],
        current_routes(80)
    ),
    ?assertMatch(
        [{10, riak_api_web_trigger}, {20, riak_api_web_get_random}],
        current_routes(8000)
    ),
    AllRoutes =
        #{
            80 => [{10, riak_api_web_ets_store}],
            default =>
                [{10, riak_api_web_trigger}, {20, riak_api_web_get_random}]
        },
    ?assertMatch(AllRoutes, get_all_routes()),
    clear_all_routes().

clear_all_routes() ->
    lists:foreach(
        fun({P, _V}) -> persistent_term:erase({?MODULE, routes, P}) end,
        maps:to_list(get_all_routes())
    ).

-endif.
