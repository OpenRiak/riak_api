-module(uri_eqc).
-include_lib("eqc/include/eqc.hrl").

-export([prop_uri_gen/0,
         prop_split_path/0,
         prop_uri_string_roundtrip/0]).

-doc """
Test the generator for URIs, ensuring that it produces valid URIs that can be parsed by `uri_string:recompose/1`.
""".
-spec prop_uri_gen() -> eqc:property().
prop_uri_gen() ->
    ?FORALL(URIMap, fault_rate(2, 20, uri_map()),
        try recompose(URIMap) of
            {error, Error, _} ->
                ?WHENFAIL(eqc:format("URIMap: ~p, Error: ~p\n", [URIMap, Error]),
                collect(Error, false));
            _ -> 
                collect(uri, true)
        catch _:Reason -> 
            ?WHENFAIL(eqc:format("URIMap: ~p, Error: ~p\n", [URIMap, Reason]),
            collect(crash, false))
        end).

-doc """
Verify that for a given URI, the path and query parameters are correctly extracted by `riak_api_web_acceptor:split_path/1`.
""".
-spec prop_split_path() -> eqc:property().
prop_split_path() ->
    ?SETUP(
        fun() -> 
            %% TODO remove this when we have onload for the detectors
            riak_api_web_acceptor:compile_detectors(),
            fun() -> ok end
        end,
    fault_rate(1, 100,
    ?FORALL(URIMap, uri_map(),
        begin
            URI = recompose(URIMap),
            ?FORALL({BinURI, Fault}, fault_inject(iolist_to_binary(URI)),
              case riak_api_web_acceptor:split_path(BinURI) of
                 {ok, {Path, DecodedPath, Params}} ->
                    StartWithSlash = starts_with_slash(Path),
                    ?WHENFAIL(eqc:format("BinURI: ~p, Path: ~p, StartWithSlash: ~p, DecodedPath: ~p, Params: ~p\n", 
                                        [BinURI, Path, StartWithSlash, DecodedPath, Params]),
                    conjunction(
                        [{path, equals(Path, mk_path(StartWithSlash, DecodedPath))}
                        || not ends_with_slash(Path)] ++
                        [{slash_path, equals(string:trim(Path, trailing, "/"), mk_path(StartWithSlash, DecodedPath))} 
                        || ends_with_slash(Path) ] ++
                        [{params, equals(Params, maps:get(query, URIMap, []))} || Fault == none]
                    ));
                {halt, Status, _, _Msg, _} ->
                    ?WHENFAIL(eqc:format("BinURI: ~p, Status: ~p\n", [BinURI, Status]),
                    Fault /= none)
              end)
        end))).


fault_inject(BinURI) ->
    fault(oneof([{utf8(), arbitrary}]), {BinURI, none}).

-doc """
When a URI is parsed, the normalization of the resulting binary cannot return an error.
This means that 
""".
prop_uri_string_roundtrip() ->
    ?FORALL(String, utf8(), 
        try uri_string:normalize(String) of
            URI when is_binary(URI) -> 
                collect(uri, true);
            {error, Error, _} ->
                ?WHENFAIL(eqc:format("String: ~p, Error: ~p\n", [String, Error]),
                collect(Error, false))
        catch _:_ -> 
            collect(crash, true)
        end).

uri_map() ->
    ?LET({Path, Params}, {list(valid_path_element()), list(query_param())},
    maps:without([query || Params == []],
         #{path => filename:join(["/" | Path]),
           scheme => oneof(["http", "https"]),
           host => oneof(["example.com", "localhost", "127.0.0.1"]),
           port => oneof([80, 443, 8080, 8443]),
           query => Params
          })).

valid_chars() ->
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:?/#[]@!$&'()*+,;=".

valid_path_element() ->
    list(oneof([elements(valid_chars() -- "/"), 32, 61, 62, choose(128, 255)])).

query_param() ->
    %% {~"company", ~"Bausch & Lomb Canada Inc."}.
    {non_empty(unicode()), oneof([non_empty(unicode()), 
                                  ?LET(N, int(), integer_to_binary(N)),
                                  true])}.


unicode() ->
  ?LET(Chars, list(choose(32, 16#D7FF)),
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
    case maps:get(query, URIMap, []) of
        [] -> uri_string:recompose(URIMap);
        Q -> uri_string:recompose(URIMap#{query => uri_string:compose_query(Q)})
    end.