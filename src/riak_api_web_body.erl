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

-record(req_body, 
    {
        buffer :: binary(),
        content_length :: non_neg_integer() | chunked,
        gzip :: boolean(),
        acc_size = 0 :: non_neg_integer(),
        max_size :: pos_integer(),
        buffer_fun :: buffer_fun(),
        test_packets = [] :: list(binary())
            % only used in tests
    }
).

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
        AccSize0 when AccSize0 >= CL ->
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

-ifdef(TEST).
extend_buffer(ReqBody, Size, _Timeout) ->
    {NextBin, RestPackets} =
        accrue_packets(
            ReqBody#req_body.test_packets,
            Size,
            ReqBody#req_body.buffer
        ),
    ReqBody#req_body{
        buffer = NextBin,
        test_packets = RestPackets
    }.
-else.
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
-endif.

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

slicing_fixed_length_test() ->
    %% Receive a 11KB body in 1KB packets
    %% Slicing into 2 4KB portions, and 1 3KB
    Body = crypto:strong_rand_bytes(11 * 1024),
    Packets = packet_testbin(Body, []),
    RqBdyInit =
        #req_body{
            buffer = <<>>,
            content_length = 11 * 1024,
            max_size = 1024 * 1024,
            test_packets = Packets
        },
    {Slice1, RqBdy1} = get_body(RqBdyInit, 4 * 1024, 60 * 1000),
    {Slice2, RqBdy2} = get_body(RqBdy1, 4 * 1024, 60 * 1000),
    {Slice3, RqBdy3} = get_body(RqBdy2, 4 * 1024, 60 * 1000),
    ?assertMatch(4096, byte_size(Slice1)),
    ?assertMatch(4096, byte_size(Slice2)),
    ?assertMatch(3072, byte_size(Slice3)),
    CompleteResult = <<Slice1/binary, Slice2/binary, Slice3/binary>>,
    ?assertMatch(Body, CompleteResult),
    ?assertMatch(<<>>, get_buffer(RqBdy3)),
    ?assertMatch(done, element(1, get_body(RqBdy3, 4 * 1024, 60 * 1000))),
    
    %% Request the full content-length in one shot
    {AllBin, RqBody4} = get_body(RqBdyInit, all, 60 * 1000),
    ?assertMatch(AllBin, Body),
    ?assertMatch(<<>>, get_buffer(RqBody4)),

    % Start with some of the first packet on the buffer, and end with
    % some of a pipelined request in the buffer
    [FirstPacket|RestPackets] = Packets,
    <<OnBuffer:64/binary, OnSocket/binary>> = FirstPacket,
    DummyRequest = crypto:strong_rand_bytes(64),
    RqBdyAlt0 =
        #req_body{
            buffer = OnBuffer,
            content_length = 11 * 1024,
            max_size = 1024 * 1024,
            test_packets = [OnSocket|RestPackets] ++ [DummyRequest]
        },
    {SliceAlt1, RqBdyAlt1} = get_body(RqBdyAlt0, 4 * 1024, 60 * 1000),
    {SliceAlt2, RqBdyAlt2} = get_body(RqBdyAlt1, 4 * 1024, 60 * 1000),
    {SliceAlt3, RqBdyAlt3} = get_body(RqBdyAlt2, 4 * 1024, 60 * 1000),
    ?assertMatch(4096, byte_size(SliceAlt1)),
    ?assertMatch(4096, byte_size(SliceAlt2)),
    ?assertMatch(3072, byte_size(SliceAlt3)),
    CompleteResult = <<Slice1/binary, Slice2/binary, Slice3/binary>>,
    ?assertMatch(
        Body,
        <<SliceAlt1/binary, SliceAlt2/binary, SliceAlt3/binary>>
    ),
    SocketBin = iolist_to_binary(RqBdyAlt3#req_body.test_packets),
    Remainder = <<(RqBdyAlt3#req_body.buffer)/binary, SocketBin/binary>>, 
    ?assertMatch(DummyRequest, Remainder)
    .

packet_testbin(<<>>, Acc) ->
    lists:reverse(Acc);
packet_testbin(<<Bin:1024/binary, Rest/binary>>, Acc) ->
    packet_testbin(Rest, [Bin|Acc]).

accrue_packets(Rest, 0, Buffer) ->
    {Buffer, Rest};
accrue_packets([NextPacket|Rest], Size, Buffer) ->
    case Size of
        Needed when Needed < byte_size(NextPacket) ->
            <<PartPacket:Needed/binary, RestPacket/binary>> = NextPacket,
            {<<Buffer/binary, PartPacket/binary>>, [RestPacket|Rest]};
        Needed ->
            accrue_packets(
                Rest,
                Needed - byte_size(NextPacket),
                <<Buffer/binary, NextPacket/binary>>
            )
    end.

-endif.