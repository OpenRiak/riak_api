%% -------------------------------------------------------------------
%%
%% riak_api_pb_registrar: Riak Client APIs Protocol Buffers Service Registration
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

%% @doc Encapsulates the Protocol Buffers service registration and
%% deregistration as a gen_server process. This is used to serialize
%% write access to the registration table so that it is less prone to
%% race-conditions.

-module(riak_api_pb_registrar).

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).
-endif.

-define(SERVER, ?MODULE).

%% External exports
-export([
         start_link/0,
         register/1,
         deregister/1,
         swap/3,
         services/0,
         lookup/1
        ]).

-record(state, {
          opq = [] :: [ tuple() ], %% A list of registrations to reply to once we have the table
          owned = true :: boolean() %% Whether the registrar owns the table yet
         }).

-include("riak_api_pb_registrar.hrl").

-include_lib("kernel/include/logger.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%--------------------------------------------------------------------
%%% Public API
%%--------------------------------------------------------------------

%% @doc Starts the registrar server
-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, Pid} = gen_server:start_link({local, ?SERVER}, ?MODULE, [], []),
    {ok, Pid}.

%% @doc Registers a range of message codes to named services.
-spec register([riak_api_pb_service:registration()]) -> ok | {error, Reason::term()}.
register(Registrations) ->
    gen_server:call(?SERVER, {register, Registrations}, infinity).

%% @doc Deregisters a range of message codes registered to named services.
-spec deregister([riak_api_pb_service:registration()]) -> ok | {error, Reason::term()}.
deregister(Registrations) ->
    try
        gen_server:call(?SERVER, {deregister, Registrations}, infinity)
    catch
        exit:{noproc, _} ->
            %% We assume riak_api is shutting down, and so silently
            %% ignore the deregistration.
            ?LOG_DEBUG("Deregistration ~p ignored, ~s not present", [Registrations, ?SERVER]),
            ok
    end.

%% @doc Atomically swap currently registered module with `NewModule'.
-spec swap(module(), pos_integer(), pos_integer()) -> ok | {error, Reason::term()}.
swap(NewModule, MinCode, MaxCode) ->
    gen_server:call(?SERVER, {swap, {NewModule, MinCode, MaxCode}}, infinity).

%% @doc Lists registered service modules.
-spec services() -> [ module() ].
services() ->
    lists:usort(
        lists:filtermap(
            fun(PKV) ->
                case PKV of
                    {{Name, _Code}, Service}
                            when Name == ?ETS_NAME, is_atom(Service) ->
                        {true, Service};
                    _ ->
                        false
                end
            end,
            persistent_term:get()
        )
    ).

%% @doc Looks up the registration of a given message code.
-spec lookup(non_neg_integer()) -> {ok, module()} | error.
lookup(Code) ->
    case persistent_term:get({?ETS_NAME, Code}, error) of
        error -> error;
        Service -> {ok, Service}
    end.

%%--------------------------------------------------------------------
%%% gen_server callbacks
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{}}.

handle_call({register, Registrations}, _From, State) ->
    Reply = do_register(Registrations),
    {reply, Reply, State};
handle_call({deregister, Registrations}, _From, State) ->
    Reply = do_deregister(Registrations),
    {reply, Reply, State};
handle_call({swap, {NewModule, MinCode, MaxCode}}, _From, State) ->
    Reply = do_swap(NewModule, MinCode, MaxCode),
    {reply, Reply, State}.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

do_register([]) ->
    ok;
do_register([{Module, MinCode, MaxCode}|Rest]) ->
    case do_register(Module, MinCode, MaxCode) of
        ok ->
            do_register(Rest);
        Error ->
            Error
    end.

do_register(_Module, MinCode, MaxCode) when MinCode > MaxCode orelse
                                            MinCode < 1 orelse
                                            MaxCode < 1 ->
    {error, invalid_message_code_range};
do_register(Module, MinCode, MaxCode) ->
    CodeRange = lists:seq(MinCode, MaxCode),
    case lists:filter(fun is_registered/1, CodeRange) of
        [] ->
            lists:map(
                fun(Code) ->
                    persistent_term:put({?ETS_NAME, Code}, Module)
                end,
                CodeRange
            ),
            riak_api_pb_sup:service_registered(Module),
            ok;
        AlreadyClaimed ->
            {error, {already_registered, AlreadyClaimed}}
    end.

do_swap(NewModule, MinCode, MaxCode) ->
    CodeRange = lists:seq(MinCode, MaxCode),
    Matching = lists:filter(fun is_registered/1, CodeRange),
    case length(Matching) == length(CodeRange) of
        true ->
            lists:map(
                fun(Code) ->
                    persistent_term:put({?ETS_NAME, Code}, NewModule)
                end,
                CodeRange
            ),
            riak_api_pb_sup:service_registered(NewModule);
        false ->
            {error, {range_not_registered, CodeRange}}
    end.

do_deregister([]) ->
    ok;
do_deregister([{Module, MinCode, MaxCode}|Rest]) ->
    case do_deregister(Module, MinCode, MaxCode) of
        ok ->
            do_deregister(Rest);
        Other ->
            Other
    end.

do_deregister(_Module, MinCode, MaxCode) when MinCode > MaxCode orelse
MinCode < 1 orelse
MaxCode < 1 ->
    {error, invalid_message_code_range};
do_deregister(Module, MinCode, MaxCode) ->
    CodeRange = lists:seq(MinCode, MaxCode),
    %% Figure out whether all of the codes can be deregistered.
    ToRemove =
        lists:map(
            fun(Code) ->
                case persistent_term:get({?ETS_NAME, Code}, error) of
                    error ->
                        {error, {unregistered, Code}};
                    Module ->
                        Code;
                    _OtherModule ->
                        {error, {not_owned, Code}}
                end
            end,
            CodeRange
        ),
    case ToRemove of
        CodeRange ->
            %% All codes are valid, so remove them.
            lists:foreach(
                fun(Code) ->
                    persistent_term:erase({?ETS_NAME, Code})
                end,
                CodeRange
            ),
            riak_api_pb_sup:service_registered(Module),
            ok;
        _ ->
            %% There was at least one error, return it.
            lists:keyfind(error, 1, ToRemove)
    end.

is_registered(Code) ->
    error =/= persistent_term:get({?ETS_NAME, Code}, error).

-ifdef(TEST).

test_start() ->
    %% Since registration is now a pair of processes, we need both.
    {ok, test_start(?MODULE)}.

test_start(Module) ->
    case gen_server:start({local, Module}, Module, [], []) of
        {error, {already_started, Pid}} ->
            exit(Pid, brutal_kill),
            test_start(Module);
        {ok, Pid} ->
            Pid
    end.

setup() ->
    {ok, Pid} = test_start(),
    Pid.

cleanup(Pid) ->
    lists:foreach(
        fun(PKT) ->
            case PKT of
                {{Name, Code}, Service}
                        when Name == ?ETS_NAME, is_atom(Service) ->
                    persistent_term:erase({Name, Code});
                _ ->
                    ok
            end
        end,
        persistent_term:get()
    ),
    exit(Pid, brutal_kill).

deregister_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
        %% Deregister a previously registered service
        ?_assertEqual(
            ok, 
            begin
                ok = riak_api_pb_service:register(foo, 1, 2),
                riak_api_pb_service:deregister(foo, 1, 2)
            end
        ),
        %% Invalid deregistration: range is invalid
        ?_assertEqual({error, invalid_message_code_range}, riak_api_pb_service:deregister(foo, 2, 1)),
        %% Invalid deregistration: unregistered range
        ?_assertEqual({error, {unregistered, 1}}, riak_api_pb_service:deregister(foo, 1, 1)),
        %% Invalid deregistration: registered to other service
        ?_assertEqual(
            {error, {not_owned, 1}},
            begin
                ok = riak_api_pb_service:register(foo, 1, 2),
                riak_api_pb_service:deregister(bar, 1)
            end
        ),
        %% Deregister multiple
        ?_assertEqual(
            ok,
            begin
                ok = riak_api_pb_service:register([{foo, 1, 2}, {bar, 3, 4}]),
                riak_api_pb_service:deregister([{bar, 3, 4}, {foo, 1, 2}])
            end
        )
     ]}.

register_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [
      %% Valid registration range
      ?_assertEqual({ok, foo}, begin
                             ok = riak_api_pb_service:register(foo,1,2),
                             lookup(1)
                         end),
      %% Registration ranges that are invalid
      ?_assertEqual({error, invalid_message_code_range},
                    riak_api_pb_service:register(foo, 2, 1)),
      ?_assertEqual({error, {already_registered, [1, 2]}},
                    begin
                        ok = riak_api_pb_service:register(foo, 1, 2),
                        riak_api_pb_service:register(bar, 1, 3)
                    end),
      %% Register multiple
      ?_assertEqual(ok, register([{foo, 1, 2}, {bar, 3, 4}]))
     ]}.

services_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      ?_assertEqual([], services()),
      ?_assertEqual([bar, foo], begin
                                    riak_api_pb_service:register(foo, 1, 2),
                                    riak_api_pb_service:register(bar, 3, 4),
                                    services()
                                end)
     ]}.


-endif.
