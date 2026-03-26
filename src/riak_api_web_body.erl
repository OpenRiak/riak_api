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
%% @doc Handling functions for receiving and sending object bodies over HTTP
%% 
%% Handling of chunked requests, and some other parts inspired by webmachine.

-module(riak_api_web_body).

-export([get_buffer/1, initiate_body/5, get_body/3]).

-ifdef(TEST).
-record(req_body, 
    {
        buffer :: binary(),
        content_length :: non_neg_integer() | chunked,
        gzip :: boolean(),
        acc_size :: non_neg_integer(),
        max_size :: pos_integer(),
        buffer_fun :: buffer_fun(),
        test_only = undefined :: any()| undefined
            % to be used in tests to mimic scenarios
    }
).
-else.
-record(req_body, 
    {
        buffer :: binary(),
        content_length :: non_neg_integer() | chunked,
        gzip :: boolean(),
        acc_size :: non_neg_integer(),
        max_size :: pos_integer(),
        buffer_fun :: buffer_fun()
    }
).
-endif.

-type req_body() :: #req_body{}.

-type buffer_fun() ::
    fun((binary(), pos_integer(), non_neg_integer()|undefined) -> binary()).

-export_type([req_body/0, buffer_fun/0]).

%%%============================================================================
%%% API
%%%============================================================================

-spec get_buffer(req_body()) -> binary().
get_buffer(ReqBody) ->
    ReqBody#req_body.buffer.

-spec initiate_body(
    buffer_fun(),
    binary(),
    chunked | non_neg_integer(),
    boolean(),
    pos_integer()
) ->
    {ok, req_body()}.
initiate_body(BufferFun, BdyBuffer, CLorChunk, UseGzip, MaxBodySize) ->
    {
        ok,
        #req_body{
            buffer = BdyBuffer,
            content_length = CLorChunk,
            gzip = UseGzip,
            acc_size = 0,
            max_size = MaxBodySize,
            buffer_fun = BufferFun
        }
    }.

-spec get_body(
    req_body(), all|pos_integer(), pos_integer()|undefined
) -> 
    {binary()|done, req_body()} | {error, content_too_large}.
get_body(#req_body{content_length = CL, max_size = MS}, _SL, _TO)
        when is_integer(CL), CL > MS ->
    {error, content_too_large};
get_body(#req_body{content_length = CL, acc_size = AS} = RqBdy, _SL, _TO)
        when is_integer(CL), CL == AS ->
    {done, RqBdy};
get_body(
    #req_body{content_length = CL, acc_size = AccSize, buffer = Bin} = RqBdy,
    all,
    TO
) when is_integer(CL) ->
    case byte_size(Bin) + AccSize of
        AccSize0 when AccSize0 > CL ->
            <<ReqBody:(CL - AccSize)/binary, Rest/binary>> = Bin,
            {
                ReqBody,
                RqBdy#req_body{
                    buffer = Rest,
                    acc_size = CL
                }
            };
        AccSize0 ->
            get_body(
                extend_buffer(RqBdy, CL - AccSize0, TO),
                all,
                TO
            )
    end;
get_body(
    #req_body{content_length = CL, acc_size = AccSize, buffer = Bin} = RqBdy,
    SL,
    TO
) when is_integer(CL), is_integer(SL) ->
    case CL - AccSize of
        Remaining when Remaining =< SL ->
            case byte_size(Bin) of
                BS when BS >= Remaining ->
                    <<SliceBody:Remaining/binary, Rest/binary>> = Bin,
                    {
                        SliceBody,
                        RqBdy#req_body{
                            buffer = Rest,
                            acc_size = CL
                        }
                    };
                BS ->
                    get_body(
                        extend_buffer(RqBdy, Remaining - BS, TO),
                        all,
                        TO
                    )
            end;
        _Remaining ->
            case byte_size(Bin) of
                BS when BS >= SL ->
                    <<SliceBody:SL/binary, Rest/binary>> = Bin,
                    {
                        SliceBody,
                        RqBdy#req_body{
                            buffer = Rest,
                            acc_size = RqBdy#req_body.acc_size + SL
                        }
                    };
                BS ->
                    get_body(
                        extend_buffer(RqBdy, SL - BS, TO),
                        SL,
                        TO
                    )
            end
    end;
get_body(
    #req_body{content_length = CL, max_size = MS, acc_size = AS},
    _SL,
    _TO
) when CL == chunked, AS > MS ->
    {error, content_too_large}.

-spec extend_buffer(
    req_body(),
    pos_integer(),
    non_neg_integer()|undefined
) -> 
    req_body().
extend_buffer(#req_body{buffer_fun = BufferFun} = ReqBody, Size, Timeout) ->
    ReqBody#req_body{
        buffer =
            BufferFun(ReqBody#req_body.buffer, Size, Timeout)
    }.

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-endif.