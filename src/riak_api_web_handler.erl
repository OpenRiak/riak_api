%% -------------------------------------------------------------------
%%
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
%% @doc Behaviour definition for a web handler
%% 
%% the callbacks will be called in the following order, with the context
%% returned from the previous call included in the next
%% - match_route/3
%% - check_permissions/4
%% - parse_query_params/2
%% - parse_request_headers/2
%% - process_request/2
%% - record_request/3

-module(riak_api_web_handler).

-type context() :: term().


-type max_header_count() :: pos_integer().
    %% The maximum number of headers that will be parsed
    %% A header split over multiple lines will be counted once for each line
    %% e.g.
    %% X-Riak-Index_field1_bin : value1
    %% X-Riak-Index_field1_bin : value2
    %% 
    %% Will count as two headers
-type max_header_size() :: pos_integer().
    %% The maximum size of a single header value.  If concatenating multiple
    %% values causes issues with this limit - the may be split across headers.
-type max_body_size() :: pos_integer().
    %% The maximum size of the body (on the wire) i.e. prior to being unzipped
    %% if compression is allowed
-type limits() :: {max_header_count(), max_header_size(), max_body_size()}.

-export_type(
    [
        limits/0,
        peer_ip/0,
        query_params/0,
        stream_fun/0,
        response_body/0,
        timings/0,
        completion/0
    ]
).

%% @doc match_route for the module
%% When called each route handled by this module must be checked, and either
%% `nomatch` returned should none match - or the initial context with the
%% limits for that route.
-callback match_route(
    riak_api_web_acceptor:method(),
    unicode:chardata(),
    list(unicode:chardata())
) -> 
    nomatch |
    {method_not_allowed, list(riak_api_web_acceptor:method())} |
    {ok, limits(), context()}.

-type peer_ip() :: inet:ip_address().
    %% The IP address of the client device connected to the socket

%% @doc check_permissions for using this module or route
%% The context() passed will be the context() returned from match_route/2 - so
%% if route information is required for permissions checks, it should be added
%% to the context.
%% 
%% On failure return a halt_response with e.g. 401 /403 response codes
-callback
    check_permissions(
        riak_api_web_headers:headers(),
        riak_api_web_socket:scheme(),
        peer_ip(),
        context()
    ) -> 
        {ok, context()}|riak_api_web_acceptor:halt_response().


-type query_params() :: [{binary(), binary()}].

%% @doc parse and validate query params, passed as a map
%% Any parameter will have both key and value as a binary, except if the
%% parameter had no value - in which case the value will be the atom `true`
-callback 
    parse_query_params(
        query_params(),
        context()
    ) -> 
        {ok, context()}|riak_api_web_acceptor:halt_response().

%% @doc parse and validate the request headers
-callback 
    parse_request_headers(
        riak_api_web_headers:headers(),
        context()
    ) -> 
        {ok, context()}|riak_api_web_acceptor:halt_response().

-type stream_fun() :: fun(() -> {binary(), done|stream_fun()}).
-type response_body() ::
    binary() | {stream, stream_fun()}.

%% @doc Process the request and produce a response
%% The request may receive an object body, the request body element is a
%% riak_api_web_body:req_body() record.  Calling riak_api_web_body:get_body/3
%% will return the body, either in whole or one slice at a time (by setting a
%% slice length as the second attribute of the get_body/3 function, and
%% re submitting the req_body() returned into subsequent get_body/3 calls).
%% 
%% Thw headers in the response need not contain the following header elements
%% which will be generated automatically:
%% - 'Server'
%% - 'Date'
%% - 'Connection'
%% - 'Content-Length'/'Transfer-Encoding'
%% 
%% The response_body() may either be a binary to be sent with a fixed content
%% length, or a stream_fun() where calls to the stream_fun() will produce
%% either:
%% - a binary() chunk and an updated stream_fun()
%% - the atom() done
%% 
%% The response object may be gzipped - the callback function should handle
%% this, or error as appropriate. the riak_api_web_body:is_gzip/1 function can
%% be checked to see if the object is gzipped.
%% 
%% Each binary() returned from the stream_fun() will be sent as a chunk in the
%% response.
%% 
%% The KeepAliveOK boolean() indicates if it is OK to reuse this connection.
%% Validation of the version and request headers is not required, this is
%% performed by the acceptor if the callback indicates that keepalive is
%% acceptable.
%% 
%% The final req_body() must also be returned, so that any remaining data on
%% the buffer is available to the acceptor. 
-callback
    process_request(
        riak_api_web_body:req_body(),
        context()
    ) ->
        {
            ok,
            {
                riak_api_web_acceptor:response_code(),
                riak_api_web_headers:header_list(),
                response_body(),
                boolean(),
                riak_api_web_body:req_body()
            },
            context()
        } | riak_api_web_acceptor:halt_response().

-type timings() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}.
    % The result of os:system_time(microsecond) for
    % - the start of the request (after accepting a connection, but prior to
    % receiving and routing the request)
    % - the completion of receipt and processing the request, and calling
    % process_request/2.
    % - the completion of sending the response to the socket
-type completion() :: stream_complete | send_complete.
    % was the output sent chunk encoded, or sent as a whole body

%% @doc Record the output of the interaction
-callback record_request(timings(), completion(), context()) -> ok.