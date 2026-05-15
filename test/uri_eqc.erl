-module(uri_eqc).
-include_lib("eqc/include/eqc.hrl").

-export([prop_uri_gen/0,
         prop_uri_gen/1,
         prop_split_path/0]).

-doc """
Test the generator for URIs, ensuring that it produces both valid URIs that can be normalized
as well as URIs on which normalization fails.
""".
-spec prop_uri_gen() -> eqc:property().
prop_uri_gen() ->
    prop_uri_gen(3).

%% Check that distribution is within 90% of given fault rate.
prop_uri_gen(N) ->
    in_parallel(
    ?FORALL({_URIMap, URIBin, Fault}, fault_rate(N, 100, uri_pair()),
       begin
         Normalize =
            case uri_string:normalize(URIBin) of
                {error, Error, _} -> Error;
                _ -> uri
            end,
        collect(with_title(path_types),
                    if Normalize /= uri -> invalid_uri;
                       true -> {dot_segment, string:find(URIBin, "..") /= nomatch}
                    end,
        collect(with_title(fault_injection), Normalize,
          check_distribution(positive, 9*(100-N)/1000, Normalize == uri,
            check_distribution(negative, 9*N/1000, Normalize /= uri,
              Normalize == uri orelse Fault /= none))))
        end)).


-doc """
Verify that for a given URI, the path and query parameters are correctly extracted by `riak_api_web_acceptor:split_path/1`.
""".
-spec prop_split_path() -> eqc:property().
prop_split_path() ->
    fault_rate(3, 100,
    ?FORALL({URIMap, URIBin, Fault}, uri_pair(),
        collect(with_title(fault_injection), Fault,
        case riak_api_web_acceptor:split_path(URIBin) of
            {ok, {Path, DecodedPath, Params}} ->
                StartWithSlash = starts_with_slash(Path),
                ?WHENFAIL(eqc:format("BinURI: ~p, Path: ~p, StartWithSlash: ~p, DecodedPath: ~p, Params: ~p\n",
                                    [URIBin, Path, StartWithSlash, DecodedPath, Params]),
                conjunction(
                    [{path, equal_path(Path, mk_path(StartWithSlash, DecodedPath))}
                    || not ends_with_slash(Path)] ++
                    [{slash_path, equal_path(string:trim(Path, trailing, "/"), mk_path(StartWithSlash, DecodedPath))}
                    || ends_with_slash(Path) ] ++
                    [{params, equals(Params, maps:get(query, URIMap, []))} || maps:get(query, URIMap, []) /= [{~"", true}] ]
                ));
             {halt, Status, _, _Msg, _} ->
                  ?WHENFAIL(eqc:format("BinURI: ~p, Status: ~p\n", [URIBin, Status]),
                      Fault /= none)
        end))).

equal_path(Path, DecodedPath) ->
    try uri_string:unquote(Path) of
        UnquotedPath ->
            equals(UnquotedPath, DecodedPath)
    catch _:_ ->
        {Path, '/=', DecodedPath}
    end.

%% This should return a URIMap and its string representation
%% but the string representation might be an invalid URI due to fault injection.
%% The uri_string module itself does not guarantee a round trip from
%% recompose to normalize (i.e. there are maps that one can recompose,
%% but fail normalization). However, if uri_string can be round tripped,
%% then there is guaranteed no failure in the URI.
uri_pair() ->
    ?LET(URIMap, uri_map(),
        try uri_string:recompose(recompose_query(URIMap)) of
          {error, _, _} ->
            {URIMap, recompose(URIMap), fault};
          URI ->
            try uri_string:normalize(URI) of
                {error, Error, _} ->
                    {URIMap, unicode:characters_to_nfc_binary(URI), Error};
                _ ->
                   {URIMap, unicode:characters_to_nfc_binary(URI), none}
            catch _:_ ->
                {URIMap, unicode:characters_to_nfc_binary(URI), non_normalizable}
            end
        catch _:_ ->
            {URIMap, recompose(URIMap), crash}
        end).

uri_map() ->
    ?LET({Path, Params}, {less_faulty(10, list(valid_path_element())), list(query_param())},
    maps:without([query || Params == []],
         #{path => filename:join(["/" | Path]),
           scheme => less_faulty(10, fault("http", oneof(["http", "https"]))),
           host => fault("2001::bd:1", oneof(["example.com", "localhost", "127.0.0.1"])),
           port => fault("twelve", oneof([80, 443, 8080, 8443])),
           query => Params
          })).

valid_chars(Kind) ->
    proplists:get_value(Kind, uri_string:allowed_characters(), []).

valid_path_element() ->
    frequency([{5, list(elements(valid_chars(path) -- [$%]))},  %% percent is valid, but only to encode
               {1, fault(oneof([[0], " ", ">", unicode(), "%x"]),
                         oneof([".", ".."]))}
              ]).

query_param() ->
    {unicode(), frequency([{9, unicode()}, {1, true}])}.

unicode() ->
  ?LET(Chars, list(choose(26, 16#D7FF)),
       unicode:characters_to_nfc_binary(Chars)).

%% helper functions

ends_with_slash(String) ->
    case string:find(String, "/", trailing) of
        nomatch -> false;
        Found -> string:equal(Found, "/")
    end.

starts_with_slash(String) ->
    string:prefix(String, "/") /= nomatch.

mk_path(_, []) -> ~"";
mk_path(true, DecodedPath) -> filename:join(["/" | DecodedPath]);
mk_path(false, DecodedPath) -> filename:join(DecodedPath).

-doc """
A recomposition of a generated URI string even if it contains certain injected faults.
""".
recompose(URIMap) ->
    %% Build Query map with potential injected faults in it
    URI =
        [maps:get(scheme, URIMap),
         "://",
         maps:get(host, URIMap),
         ":",
         case maps:get(port, URIMap) of
             P when is_integer(P) -> integer_to_list(P);
             P -> P
         end,
         maps:get(path, URIMap),
         case maps:get(query, URIMap, []) of
             [] -> "";
             Q -> "?" ++ lists:join("&", [ if V == true -> K; true -> [K, "=", V] end || {K, V} <- Q ])
         end],
    unicode:characters_to_nfc_binary(URI).

recompose_query(URIMap) ->
    maps:put(query,
            case maps:get(query, URIMap, []) of
                [] -> "";
                Q -> uri_string:compose_query(Q)
            end,
            URIMap).
