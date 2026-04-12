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
        get_route/3,
        spec_name/3,
        rfc1123_date/1,
        rfc1123_date/2,
        rfc1123_date_now/0,
        cache_today/0
    ]
).

-define(ROUTE_KEY, {?MODULE, web_routes}).

-type route() :: {1..100, module()}.

%%%============================================================================
%%% Routing
%%%============================================================================

-spec add_routes(list(route())) -> ok.
add_routes(Routes) ->
    CurrentRoutes = persistent_term:get(?ROUTE_KEY, []),
    NewRoutes = lists:keysort(1, CurrentRoutes ++ Routes),
    persistent_term:put(?ROUTE_KEY, NewRoutes).

-spec get_route(
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) ->
    {
        ok,
        module(),
        {pos_integer(), pos_integer(), pos_integer()},
        any()
    }
    | riak_api_web_acceptor:halt_response().
get_route(Method, Path, SplitPath) ->
    CurrentRoutes = persistent_term:get(?ROUTE_KEY, []),
    get_route(CurrentRoutes, Method, Path, SplitPath).

get_route([], _Method, _Path, _SP) ->
    {halt, 404, [], <<>>, []};
get_route([{_P, CallbackMod} | Rest], Method, Path, SplitPath) ->
    case CallbackMod:match_route(Method, Path, SplitPath) of
        nomatch ->
            get_route(Rest, Method, Path, SplitPath);
        {method_not_allowed, AllowedMethods} ->
            AllowHdrVal =
                iolist_to_binary(
                    lists:join(
                        <<", ">>,
                        lists:map(fun atom_to_binary/1, AllowedMethods)
                    )
                ),
            {halt, 405, [{'Allow', AllowHdrVal}], <<>>, []};
        {ok, {MaxHdrCount, MaxHdrSize, MaxBodySize}, Context} ->
            {ok, CallbackMod, {MaxHdrCount, MaxHdrSize, MaxBodySize}, Context}
    end.

%%%============================================================================
%%% Configure and Initiate Listeners
%%%============================================================================

get_listeners() ->
    get_listeners(http) ++ get_listeners(https).

get_listeners(Scheme) ->
    Listeners =
        case app_helper:try_envs([{riak_api, Scheme}], []) of
            {riak_api, Scheme, List} when is_list(List) ->
                List;
            _ ->
                []
        end,
    lists:usort([{Scheme, Binding} || Binding <- Listeners]).

binding_config(Scheme, Binding) ->
    {Ip, Port} = Binding,
    Name = spec_name(Scheme, Ip, Port),
    Config = spec_from_binding(Scheme, Name, Binding),

    {
        Name,
        {riak_api_web_socket, start_link, [Config]},
        permanent,
        5000,
        worker,
        [riak_api_web_socket]
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

spec_name(Scheme, Ip, Port) ->
    FormattedIP =
        if
            is_tuple(Ip); tuple_size(Ip) == 4 ->
                inet_parse:ntoa(Ip);
            is_tuple(Ip); tuple_size(Ip) == 8 ->
                [$[, inet_parse:ntoa(Ip), $]];
            true ->
                Ip
        end,
    iolist_to_binary(io_lib:format("~s://~s:~p", [Scheme, FormattedIP, Port])).

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
        {Date, DateBin} ->
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

-endif.
