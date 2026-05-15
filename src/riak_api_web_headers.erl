%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007 Mochi Media, Inc
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
%% @doc Case preserving (but case insensitive) HTTP Header dictionary.
%%
%% The headers are stored in a map, and the header keys will be an atom if
%% in the standard list of headers decoded by Erlang/OTP - and otherwise a
%% binary().
%%
%% The values will always be binaries, comma(-and-space)-separated for values
%% with multiple items
%%
%% The module was initially a refactoring of the mochiweb_headers module.

-module(riak_api_web_headers).

-on_load(compile_separators/0).

-export([make/1, make_rsp_header/1]).
-export([enter_from_list/2, default_from_list/2, enter/3]).
-export([get_value/2, get_unique_value/2, lookup/3, prefix_fold/3]).
-export([parse_primary_header_value/1]).
-export([output_response_block/1, parse_request_block/3]).

-define(KV_SEPARATOR, <<": ">>).
-define(V_SEPARATOR, <<", ">>).
-define(L_SEPARATOR, <<"\r\n">>).
-define(OWS, [<<" ">>, <<"\t">>]).

-record(headers, {
    type = request :: request | response,
    %% response headers do not support the lookup of non-standard
    %% header keys - and hence avoid the need to lower case those
    %% keys for comparison
    header_map = maps:new() :: header_map()
}).

-type standard_header_key() ::
    'Cache-Control'
    | 'Connection'
    | 'Date'
    | 'Pragma'
    | 'Transfer-Encoding'
    | 'Upgrade'
    | 'Via'
    | 'Accept'
    | 'Accept-Charset'
    | 'Accept-Encoding'
    | 'Accept-Language'
    | 'Authorization'
    | 'Proxy-Authorization'
    | 'Proxy-Authenticate'
    | 'Www-Authenticate'
    | 'From'
    | 'Host'
    | 'If-Modified-Since'
    | 'If-Match'
    | 'If-None-Match'
    | 'If-Range'
    | 'If-Unmodified-Since'
    | 'Max-Forwards'
    | 'Range'
    | 'Referer'
    | 'User-Agent'
    | 'Age'
    | 'Location'
    | 'Public'
    | 'Retry-After'
    | 'Server'
    | 'Vary'
    | 'Warning'
    | 'Allow'
    | 'Content-Base'
    | 'Content-Encoding'
    | 'Content-Language'
    | 'Content-Length'
    | 'Content-Location'
    | 'Content-Md5'
    | 'Content-Range'
    | 'Content-Type'
    | 'Etag'
    | 'Expires'
    | 'Last-Modified'
    | 'Accept-Ranges'
    | 'Set-Cookie'
    | 'Set-Cookie2'
    | 'X-Forwarded-For'
    | 'Cookie'
    | 'Keep-Alive'
    | 'Proxy-Connection'.
% This list is controlled by Erlang/OTP - i.e. there may be further atoms
% added in the future, but it has been stable since OTP 13.
-type binary_header_key() :: unicode:chardata() | binary().
-type header_key() :: standard_header_key() | binary_header_key().
-type header_value() :: {binary(), list(binary())}.
-type header_map() :: #{header_key() => header_value()}.
-type header_list() :: [{header_key(), binary()}].
-type headers() :: #headers{}.
-type buffer_fun() :: fun((binary()) -> binary()).

-export_type([headers/0, header_list/0]).

%%%============================================================================
%%% API
%%%============================================================================

%% @doc
%% Construct a headers() from the given list of headers received in a
%% request.
-spec make([{header_key(), binary()}]) -> headers().
make(HeaderList) when is_list(HeaderList) ->
    HeaderMap = from_list(HeaderList, true),
    #headers{header_map = HeaderMap}.

%% @doc
%% Specific constructor when forming response headers.
%% With response headers it is not possible to lookup non-standard header keys,
%% and the value may be a list of elements - that will be joined into a single
%% comma-separated value before creating the response header.
-spec make_rsp_header([{header_key(), list(binary()) | binary()}]) ->
    headers().
make_rsp_header(HeaderList) ->
    HeaderMap = from_list(HeaderList, false),
    #headers{type = response, header_map = HeaderMap}.

%% @doc
%% Insert pairs into the headers, replace any values for existing keys.
%% Specifically used in response headers when setting ranges into existing
%% headers.
-spec enter_from_list([{header_key(), binary()}], headers()) ->
    headers().
enter_from_list(HeaderList, #headers{type = T, header_map = HM}) when
    T == response
->
    #headers{
        type = response,
        header_map = maps:merge(HM, from_list(HeaderList, false))
    }.

%% @doc
%% Insert pairs into response headers for keys that do not already exist.
-spec default_from_list([{header_key(), binary()}], headers()) ->
    headers().
default_from_list(HeaderList, #headers{type = T, header_map = HM}) when
    T == response
->
    #headers{
        type = response,
        header_map = maps:merge(from_list(HeaderList, false), HM)
    }.

%% @doc
%% Add a single value for a single key to the response map
-spec enter(header_key(), binary(), headers()) ->
    headers().
enter(HeaderKey, Value, #headers{type = T, header_map = HM}) when
    T == response
->
    {HK, HV} = normalize_header({HeaderKey, Value}, false),
    #headers{
        type = response,
        header_map = maps:put(HK, HV, HM)
    }.

%% @doc
%% Return the value of the given standard header key. `undefined` will be
%% returned for keys that are not present.
%% For non-standard (binary) keys use lookup/2.
%% If the values was a comma-separated list, or multiple headers have been
%% folded together - then a list rather than a single value is returned.
-spec get_value(standard_header_key(), headers()) ->
    unicode:chardata() | list(unicode:chardata()) | undefined.
get_value(K, H) when is_atom(K) ->
    case maps:get(K, H#headers.header_map, undefined) of
        undefined ->
            undefined;
        {_OK, [V]} ->
            V;
        {_OK, VL} when is_list(VL) ->
            VL
    end.

%% @doc
%% If multiple values may be provided for a field, but it is illegal
%% for those values to differ (e.g. in the case of content-length), only return
%% a value, if there is only one unique value.
-spec get_unique_value(standard_header_key(), headers()) ->
    unicode:chardata() | undefined | {error, multiple_values}.
get_unique_value(K, H) ->
    case maps:get(K, H#headers.header_map, undefined) of
        undefined ->
            undefined;
        {_OK, [V]} ->
            V;
        {_OK, VL} when is_list(VL) ->
            case lists:uniq(VL) of
                [V] ->
                    V;
                _ ->
                    {error, multiple_values}
            end
    end.

%% @doc
%% some header values consist of primary information supported by secondary
%% information.  The primary information is presented before a ';', and the
%% secondary information is `;` separated list
-spec parse_primary_header_value(binary()) -> unicode:chardata().
parse_primary_header_value(HeaderValue) ->
    binary:split(HeaderValue, <<";">>, [global, trim_all]).

%% @doc
%% Fetch the {original key, values} for a binary (non-standard) header key.
%% There is a boolean flag to indicate if the key has already been subject to
%% casefold.
-spec lookup(binary_header_key(), headers(), boolean()) ->
    {binary(), list(unicode:chardata())} | undefined.
lookup(CaseFoldedKey, H, true) when is_binary(CaseFoldedKey) ->
    maps:get(CaseFoldedKey, H#headers.header_map, undefined);
lookup(RawKey, Headers, false) when is_binary(RawKey) ->
    lookup(normalize_key(RawKey), Headers, true).

%% @doc
%% Fetch a list of non-standard headers with a given prefix.  The list is a
%% list of {K, [V]} where K is the remainder of the original key once the
%% original prefix has been stripped
-spec prefix_fold(binary_header_key(), headers(), boolean()) ->
    list({unicode:chardata(), list(unicode:chardata())}).
prefix_fold(CaseFoldPrefix, Headers, true) when is_binary(CaseFoldPrefix) ->
    Keys = maps:keys(Headers#headers.header_map),
    filter_headers(
        Keys,
        CaseFoldPrefix,
        byte_size(CaseFoldPrefix),
        Headers#headers.header_map,
        []
    );
prefix_fold(RawPrefix, Headers, false) ->
    prefix_fold(normalize_key(RawPrefix), Headers, true).

%% @doc
%% Output a binary representing the block of response headers to be pushed to
%% the socket.  Includes trailing line feed at end of last line, but not a
%% separating line feed to the response body
-spec output_response_block(headers()) -> binary().
output_response_block(#headers{type = T, header_map = HM}) when T == response ->
    HeaderList = maps:values(HM),
    iolist_to_binary(
        lists:map(
            fun({BK, VL}) ->
                <<
                    BK/binary,
                    (?KV_SEPARATOR)/binary,
                    (join_values(VL))/binary,
                    (?L_SEPARATOR)/binary
                >>
            end,
            HeaderList
        )
    ).

-define(COUNT_EXCEEDED, <<"Headers exceeded maximum count of ~w">>).
-define(SIZE_EXCEEDED, <<"Header ~s exceeded maximum size of ~w">>).

%% @doc
%% Parse a binary block representing the start of a block of request headers,
%% with a buffer function to request more should the block be incomplete.
-spec parse_request_block(
    binary(),
    buffer_fun(),
    {pos_integer(), pos_integer()}
) ->
    {ok, headers(), binary()} | riak_api_web_acceptor:halt_response().
parse_request_block(Buffer, BufferFun, {MaxCount, MaxSize}) ->
    parse_request_block(Buffer, BufferFun, {MaxCount, MaxSize}, {[], 0}).

parse_request_block(_B, _BFun, {MaxCount, _MS}, {_H, C}) when C > MaxCount ->
    {halt, 431, [], ?COUNT_EXCEEDED, [MaxCount]};
parse_request_block(Buffer, BufferFun, {MaxCount, MaxSize}, {HeaderAcc, C}) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
        {ok, {http_header, _, _, OrigKey, V}, _} when byte_size(V) > MaxSize ->
            {halt, 431, [], ?SIZE_EXCEEDED, [OrigKey, MaxSize]};
        {ok, {http_header, _, Key, _OrigKey, Value}, Rest} when is_atom(Key) ->
            parse_request_block(
                Rest,
                BufferFun,
                {MaxCount, MaxSize},
                {[{Key, Value} | HeaderAcc], C + 1}
            );
        {ok, {http_header, _, _Key, OrigKey, Value}, Rest} ->
            parse_request_block(
                Rest,
                BufferFun,
                {MaxCount, MaxSize},
                {[{OrigKey, Value} | HeaderAcc], C + 1}
            );
        {ok, http_eoh, Rest} ->
            {ok, make(HeaderAcc), Rest};
        {ok, {http_error, _}, Rest} ->
            parse_request_block(
                Rest,
                BufferFun,
                {MaxCount, MaxSize},
                {HeaderAcc, C}
            );
        {more, _} ->
            parse_request_block(
                BufferFun(Buffer),
                BufferFun,
                {MaxCount, MaxSize},
                {HeaderAcc, C}
            )
    end.

%%%============================================================================
%%% Internal Functions
%%%============================================================================

-spec join_values(list(unicode:chardata())) -> binary().
-if(?OTP_RELEASE >= 28).
join_values(VL) ->
    binary:join(VL, ?V_SEPARATOR).
-else.
join_values(VL) ->
    iolist_to_binary(lists:join(?V_SEPARATOR, VL)).
-endif.

-spec filter_headers(
    list(header_key()),
    unicode:chardata(),
    pos_integer(),
    header_map(),
    list(header_value())
) ->
    list(header_value()).
filter_headers([], _Prefix, _PL, _HMap, Acc) ->
    Acc;
filter_headers([Key | RestKeys], Prefix, PL, HMap, Acc) ->
    case Key of
        <<Prefix:PL/binary, _/binary>> ->
            {<<_Ignore:PL/binary, Suffix/binary>>, Values} =
                maps:get(Key, HMap),
            filter_headers(RestKeys, Prefix, PL, HMap, [{Suffix, Values} | Acc]);
        _ ->
            filter_headers(RestKeys, Prefix, PL, HMap, Acc)
    end.

-spec from_list([{header_key(), binary() | list(binary())}], boolean()) ->
    header_map().
from_list(HeaderList, IsReqHeader) ->
    lists:foldl(
        fun(Header, Acc) ->
            {NK, {RK, HVL}} = normalize_header(Header, IsReqHeader),
            maps:update_with(
                NK,
                fun({ERK, EHVL}) -> {ERK, HVL ++ EHVL} end,
                {RK, HVL},
                Acc
            )
        end,
        maps:new(),
        HeaderList
    ).

-spec normalize_header(
    {header_key(), binary() | list(binary())}, boolean()
) ->
    {header_key(), header_value()}.
normalize_header({KAtom, Value}, _) when is_atom(KAtom) ->
    {KAtom, {atom_to_binary(KAtom), normalize_value(Value)}};
normalize_header({KBin, Value}, true) when is_binary(KBin) ->
    {string:casefold(KBin), {KBin, normalize_value(Value)}};
normalize_header({KBin, Value}, false) when is_binary(KBin) ->
    {KBin, {KBin, normalize_value(Value)}}.

-spec normalize_key
    (standard_header_key()) -> standard_header_key();
    (binary_header_key()) -> binary_header_key().
normalize_key(KAtom) when is_atom(KAtom) ->
    KAtom;
normalize_key(KBin) when is_binary(KBin) ->
    string:casefold(KBin).

-spec normalize_value(binary() | list(binary())) ->
    list(binary()).
normalize_value(MultipleValues) when is_list(MultipleValues) ->
    lists:filter(fun is_binary/1, MultipleValues);
normalize_value(FieldValue) when is_binary(FieldValue) ->
    {CP, WS} =
        persistent_term:get(
            {?MODULE, compiled_separators},
            {?V_SEPARATOR, ?OWS}
        ),
    lists:map(
        fun(V) ->
            case binary:split(V, WS, [global, trim_all]) of
                [V0] when is_binary(V0) ->
                    V0;
                _ ->
                    string:trim(V, both)
            end
        end,
        binary:split(FieldValue, CP, [global])
    ).

%% @doc Call this function when initialising API
-spec compile_separators() -> ok.
compile_separators() ->
    CP = binary:compile_pattern(?V_SEPARATOR),
    WS = binary:compile_pattern(?OWS),
    persistent_term:put({?MODULE, compiled_separators}, {CP, WS}).

%%%============================================================================
%%% Eunit tests
%%%============================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

split_perf_test() ->
    HV1 = <<"SOME-INDEX|HEADER|NOTSPLIT">>,
    HV2 = <<"HDR1, HDR2, HDR3">>,
    L = [HV1, HV1, HV1, HV1, HV2],
    FullL = lists:flatten(lists:map(fun(_I) -> L end, lists:seq(1, 1000))),
    {TS1, L1} =
        timer:tc(
            fun() ->
                lists:map(
                    fun(HV) -> binary:split(HV, ?V_SEPARATOR, [global]) end,
                    FullL
                )
            end
        ),
    CPVS = binary:compile_pattern(?V_SEPARATOR),
    {TS2, L2} =
        timer:tc(
            fun() ->
                lists:map(
                    fun(HV) -> binary:split(HV, CPVS, [global]) end,
                    FullL
                )
            end
        ),
    ?assertMatch(L1, L2),
    io:format(user, "No-compile ~w compile ~w microseconds", [TS1, TS2]).

parse_block_test() ->
    RequestHeader1 =
        <<
            "content-length: 1024\r\n"
            "x-riak-Index-field1_bin:  NAME1|DOB1, NAME2|DOB1\r\n"
            "x-riak-index-Field1_bin:  NAME3|DOB1\r\n"
            "X-Riak-Index-field2_bin: POSTCODE1|DOB1\r\n"
        >>,
    RequestHeader2 =
        <<
            "x-riak-index-field2_bin: POSTCODE2|DOB1\r\n"
            "\r\n"
        >>,
    parse_block_tester(RequestHeader1, RequestHeader2).

parse_splitblock_test() ->
    RequestHeader1 =
        <<
            "content-length: 1024\r\n"
            "x-riak-Index-field1_bin:  NAME1|DOB1, NAME2|DOB1\r\n"
            "x-riak-index-Field1_bin: NAME3|DOB1\r\n"
            "X-Riak-Index-field2_bin: POSTCODE1"
        >>,
    RequestHeader2 =
        <<
            "|DOB1\r\nx-riak-index-field2_bin: POSTCODE2|DOB1\r\n"
            "\r\n"
        >>,
    parse_block_tester(RequestHeader1, RequestHeader2).

parse_block_tester(RequestHeader1, RequestHeader2) ->
    BufferFun = fun(B) -> <<B/binary, RequestHeader2/binary>> end,
    {ok, Headers, <<>>} =
        parse_request_block(RequestHeader1, BufferFun, {1024, 2048}),
    ?assertMatch(
        <<"1024">>,
        get_value('Content-Length', Headers)
    ),
    ?assertMatch(
        {
            <<"x-riak-index-Field1_bin">>,
            [<<"NAME1|DOB1">>, <<"NAME2|DOB1">>, <<"NAME3|DOB1">>]
        },
        lookup(<<"x-riak-index-field1_bin">>, Headers, true)
    ),
    ?assertMatch(
        {
            <<"x-riak-index-field2_bin">>,
            [<<"POSTCODE1|DOB1">>, <<"POSTCODE2|DOB1">>]
        },
        lookup(<<"x-riak-index-Field2_bin">>, Headers, false)
    ),
    ?assertMatch(
        <<"1024">>,
        get_unique_value('Content-Length', Headers)
    ).

riak_metadata_test() ->
    RequestHeader1 =
        <<
            "content-length: 1024\r\n"
            "x-riak-Index-field1_bin:  NAME1|DOB1, NAME2|DOB1\r\n"
            "x-riak-index-Field1_bin: NAME3|DOB1 \r\n"
            "X-Riak-Index-field2_bin: POSTCODE1|DOB1\r\n"
        >>,
    RequestHeader2 =
        <<
            "x-riak-index-field2_bin: POSTCODE2|DOB1\r\n"
            "x-riak-meta-key1: METAVALUE1\r\n"
            "x-riak-meta-key2: METAVALUE2\r\n"
            "\r\n"
        >>,
    BufferFun = fun(B) -> <<B/binary, RequestHeader2/binary>> end,
    {ok, Headers, <<>>} =
        parse_request_block(RequestHeader1, BufferFun, {1024, 2048}),
    IndexList = prefix_fold(<<"x-riak-index-">>, Headers, true),
    ?assertMatch(
        {
            <<"Field1_bin">>,
            [<<"NAME1|DOB1">>, <<"NAME2|DOB1">>, <<"NAME3|DOB1">>]
        },
        lists:keyfind(<<"Field1_bin">>, 1, IndexList)
    ),
    MetaList = prefix_fold(<<"X-Riak-Meta-">>, Headers, false),
    ?assertMatch(
        {<<"key1">>, [<<"METAVALUE1">>]},
        lists:keyfind(<<"key1">>, 1, MetaList)
    ).

content_smuggling_test() ->
    RequestHeader1 =
        <<
            "content-length: 1024\r\n"
            "x-riak-Index-field1_bin:  NAME1|DOB1, NAME2|DOB1\r\n"
            "x-riak-index-Field1_bin: NAME3|DOB1 \t \r\n"
            "X-Riak-Index-field2_bin: POSTCODE1|DOB1\r\n"
            "content-length: 16384\r\n"
            "\r\n"
        >>,
    {ok, Headers, <<>>} =
        parse_request_block(RequestHeader1, fun() -> <<>> end, {1024, 2048}),
    ?assertMatch(
        {error, multiple_values},
        get_unique_value('Content-Length', Headers)
    ).

response_header_test() ->
    InitHeaders =
        [
            {'Server', <<"Riak Web API">>},
            {'Content-Length', <<"1024">>},
            {'Etag', <<"sometag">>},
            {<<"X-Riak-Index-field1_bin">>, [
                <<"NAME1|DOB1">>, <<"NAME2|DOB1">>
            ]},
            {<<"X-Riak-Index-field1_bin">>, <<"NAME3|DOB1">>},
            {<<"X-Riak-Index-field2_bin">>, <<"POSTCODE1|DOB1">>}
        ],
    RespHeaders1 = make_rsp_header(InitHeaders),
    DefaultList =
        [
            {'Server', <<"Riak Web API 1.0">>},
            {'Date', <<"Mon, 15 Apr 2025 10:06:15 GMT">>}
        ],
    RespHeaders2 = default_from_list(DefaultList, RespHeaders1),
    EntryList =
        [
            {'Etag', <<"some_md5_tag">>},
            {'Vary', <<"*">>}
        ],
    RespHeaders3 = enter_from_list(EntryList, RespHeaders2),
    Response = output_response_block(RespHeaders3),
    ExpectedResponse =
        <<
            "Date: Mon, 15 Apr 2025 10:06:15 GMT\r\n"
            "Server: Riak Web API\r\n"
            "Vary: *\r\n"
            "Content-Length: 1024\r\n"
            "Etag: some_md5_tag\r\n"
            "X-Riak-Index-field1_bin: NAME3|DOB1, NAME1|DOB1, NAME2|DOB1\r\n"
            "X-Riak-Index-field2_bin: POSTCODE1|DOB1\r\n"
        >>,
    ?assertMatch(ExpectedResponse, Response).

-endif.
