%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2009 Basho Technologies
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
%%
%% @doc Some security helper functions for Riak API endpoints

-module(riak_api_web_security).
-include_lib("kernel/include/logger.hrl").

-export([is_authorised/4]).

-define(AUTH_PREFIX, "Basic ").

-spec is_authorised(
    boolean(),
    http | https,
    riak_api_web_headers:headers(),
    {ip, inet:ip_address()}
) ->
    {ok, riak_core_security:context() | undefined}
    | riak_api_web_acceptor:halt_response().
is_authorised(Enabled, Scheme, ReqHeaders, Peer) ->
    is_authorised(
        Enabled,
        Scheme,
        ReqHeaders,
        Peer,
        fun(User, Pass, {ip, Pip}) ->
            riak_core_security:authenticate(User, Pass, [{ip, Pip}])
        end
    ).

is_authorised(true, https, ReqHeaders, Peer, AuthFun) ->
    case riak_api_web_headers:get_unique_value('Authorization', ReqHeaders) of
        <<?AUTH_PREFIX, Base64UP/binary>> ->
            try
                UserPass = base64:decode(Base64UP),
                [User, Pass] = string:lexemes(UserPass, ":"),
                case AuthFun(User, Pass, [Peer]) of
                    {ok, SecContext} ->
                        {ok, SecContext};
                    {error, Error} ->
                        {halt, 401, <<"~0p">>, [Error]}
                end
            catch
                _:ExError ->
                    ?LOG_WARNING("Error decoding credentials ~0p", [ExError]),
                    {halt, 400, none, <<"Error decoding credentials">>, []}
            end;
        Unexpected ->
            ?LOG_WARNING("Error decoding credentials ~0p", [Unexpected]),
            {halt, 400, none, <<"Error decoding credentials">>, []}
    end;
is_authorised(true, http, _ReqHeaders, _Peer, _AuthFun) ->
    {halt, 426, none, <<"Upgrade required to https">>};
is_authorised(false, _, _ReqHeaders, _Peer, _AuthFun) ->
    {true, undefined}.

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-endif.
