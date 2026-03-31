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
        get_route/2,
        spec_name/3
    ]
).

-include_lib("kernel/include/logger.hrl").

-define(ROUTE_KEY, {?MODULE, web_routes}).

-type route() :: {1..100, module()}.

-spec add_routes(list(route())) -> ok.
add_routes(Routes) ->
    CurrentRoutes = persistent_term:get(?ROUTE_KEY, []),
    NewRoutes = lists:keysort(1, CurrentRoutes ++ Routes),
    persistent_term:put(?ROUTE_KEY, NewRoutes).

-spec get_route(
    riak_api_web_acceptor:method(),
    unicode:chardata()
) ->
    {
        ok,
        module(),
        any(),
        {pos_integer(), pos_integer(), pos_integer()}
    }
    | riak_api_web_acceptor:halt_response().
get_route(Method, Path) ->
    CurrentRoutes = persistent_term:get(?ROUTE_KEY, []),
    get_route(CurrentRoutes, Method, Path).

get_route([], _Method, _Path) ->
    {halt, 404, [], <<>>, []};
get_route([{_P, CallbackMod} | Rest], Method, Path) ->
    case CallbackMod:match_route(Method, Path) of
        no_match ->
            get_route(Rest, Method, Path);
        {method_not_allowed, AllowedMethods} ->
            AllowHdrVal =
                iolist_to_binary(
                    lists:join(
                        <<", ">>,
                        lists:map(fun atom_to_binary/1, AllowedMethods)
                    )
                ),
            {halt, 405, [{'Allow', AllowHdrVal}], <<>>, []};
        {ok, Context, {MaxHdrCount, MaxHdrSize, MaxBodySize}} ->
            {ok, CallbackMod, Context, {MaxHdrCount, MaxHdrSize, MaxBodySize}}
    end.

get_listeners() ->
    get_listeners(http) ++ get_listeners(https).

get_listeners(Scheme) ->
    Listeners =
        case
            app_helper:try_envs(
                [
                    {riak_api, Scheme},
                    {riak_core, Scheme}
                ],
                []
            )
        of
            {riak_api, Scheme, List} when is_list(List) ->
                List;
            {riak_core, Scheme, List} when is_list(List) ->
                ?LOG_WARNING(
                    "Setting riak_core/~s is deprecated, please use riak_api/~s",
                    [Scheme, Scheme]
                ),
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
        {riak_api_web_socket, start, [Config]},
        permanent,
        5000,
        worker,
        [riak_api_web_socket]
    }.

spec_from_binding(http, Name, {Ip, Port}) ->
    Options =
        lists:flatten(
            [
                {name, Name},
                {ip, Ip},
                {port, Port},
                {nodelay, true}
            ],
            common_config()
        ),
    add_recbuf(Options);
spec_from_binding(https, Name, {Ip, Port}) ->
    Options =
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
        ),
    add_recbuf(Options).

add_recbuf(Options) ->
    case application:get_env(webmachine, recbuf) of
        {ok, RecBuf} ->
            [{recbuf, RecBuf} | Options];
        _ ->
            Options
    end.

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
        {backlog, 128},
        {dispatch, [{[], riak_api_wm_urlmap, []}]}
    ].
