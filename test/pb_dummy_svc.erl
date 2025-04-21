%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013-2016 Basho Technologies, Inc.
%% Copyright (c) 2025 Workday, Inc.
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

-module(pb_dummy_svc).
-behaviour(riak_api_pb_service).
-export([init/0,
         decode/2,
         encode/1,
         process/2,
         process/3,
         process_stream/3,
         process_stream/4]).

init() ->
    undefined.

decode(101, <<>>) ->
    {ok, dummyreq};
decode(_,_) ->
    {error, unknown_message}.

encode(ok) ->
    {ok, <<102,$s,$w,$a,$p>>};
encode(_) ->
    error.

process(dummyreq, State) ->
    {reply, ok, State}.

process(dummyreq, State, _Options) ->
    {reply, ok, State}.

process_stream(_, _, State) ->
    {ignore, State}.

process_stream(_, _, State, _) ->
    {ignore, State}.

