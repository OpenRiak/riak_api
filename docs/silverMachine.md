# Silver Machine

## Overview

Silver Machine is a HTTP/REST request handler.  It is designed to be simpler and more performant than Webmachine/Mochiweb, with the trade-off that it provides less complete compliance with standards within the framework:

- "simpler" means reduced volume of code within the framework (less than half), better use of dialyzer specs to clarify safe usage, and a behaviour module with a smaller and fixed number callbacks.
- "performant" means less CPU overhead when handling Riak requests, especially those carrying a large volume of information via HTTP request headers.

Silver Machine took direct inspiration from the [Elli HTTP server](https://github.com/elli-lib/elli), using it as a source of ideas for improving performance.

Silver Machine is not intended to be used outside of Riak.  It is a framework developed specifically for the Riak use-case, and may have breaking changes within the framework at any time if such a change is required to support efficiency in Riak.

Using Silver Machine requires three actions:

- configuration to start [listeners](#listeners);
- the [loading of routes](#adding-routes), a prioritised list of modules that will provide endpoints via the listener;
- the definition of those modules to handle requests, implemented following the `riak_api_web_handler` [behaviour](#the-riak_api_web_handler-behaviour).

### Listeners

A listener is started using `riak_api_web_socket:start_link/1`, where the function takes as its argument a list of options:

```erlang
-type option() ::
    {acceptor_pool_start_size, pos_integer()}
    | {acceptor_pool_max_size, pos_integer()}
    | {ssl, boolean()}
    | {ssl_opts, [ssl:tls_server_option()]}
    | {ip, inet:ip_address()}
    | {port, inet:port_number()}
    | {name, server_name()}.
```

Within Riak the `riak_api_sup` sueprvisor is used to discover the bindings (IP and Port pairs) from the configuration, and start a listener for each binding.

In addition to the passed-in options, three further options can be set using environment variables:

- `riak_api/web_kernel_buffer` - which will set the TCP `buffer`;
- `riak_api/web_receive_buffer` - which will set the TCP `recbuf`;
- `riak_api/web_send_buffer` - which will set the TCP `sndbuf`.

If no environment variables are set, then the `recbuf` will be changed from its default setting to `131072`, and this will automatically [change the `buffer` setting](https://github.com/erlang/otp/issues/9355).

Each listener is a socket (SSL or TCP), with a pool of acceptors.  The acceptors will listen on the socket, and when new connections are made the listen results in the connection being managed by an available acceptor.  The acceptor will live for the duration of the connection, but only for the duration of the connection.  When an acceptor is assigned a connection (at the start), a new acceptor is started and added to the pool to replace the busy acceptor.  There should always be a pool of acceptors ready; however due to the potential timing delays in the assignment of connections to acceptors the `backlog` on the socket (i.e. the backlog of unhandled connections) is configured to 128 (normal OTP default is 5) to avoid unnecessary connection resets.

The acceptor pool maximum and starting size is defined at startup via the passed in options. If no such options are passed for that listener the defaults are taken from environment variables `riak_api/web_acceptor_pool_start_size` and `riak_api/web_acceptor_pool_max_size`.

### Adding routes

There are multiple routing tables - one for `default` routes, and one for each Port.  Routes are lists of {1..100, module()} tuples.  When a request is processed each module in the routing table will be matched against the request (using the `match_route/3` callback function) until a match is found.  If port-specific routes are provided these will be used, default routes will only be used if no port-specific routes have been added.

Routes can be added using `riak_api_web:add_routes/1`, `riak_api_web:add_routes/2`.

For each module in the list the `Module:match_routes/3` function will be called, until a match is found.  For path mismatches, `nomatch` should be returned and for path matches with Method mismatches `{method_not_allowed, AllowedMethods}` should be returned from the callback function.

Note that different modules may support the same path but with different methods.  The routes will be checked until the first `ok` match; if a `method_not_allowed` response is returned, routes will continue to be checked.  If subsequent routes also return `method_not_allowed`, and no matches are found, then a `405` (not a `404`) error response will be returned.  In that `405` response the list of Allowed Methods will be the union of all allowed methods returned from the individual `match_route/3` calls.

In the current `riak_kv` implementation only `default` routes are set, so all HTTP/HTTPS listeners have the same functionality.

### The `riak_api_web_handler` behaviour

The acceptor has a standard workflow of functions for handling a request (`riak_api_web_acceptor:handle_request/5`), and included in that workflow are the calls to the six callbacks required in the `riak_api_web_handler` behaviour:

- [`match_route/3`](#match_route);
  - Passed path information, to be potentially matched against the routing needs for the module.
- [`check_permissions/5`](#check_permissions);
  - Passed credential information (request headers and peer details), to be potentially screen requests based on authentication and authorisation needs.
- [`parse_query_params/2`](#parse_query_params)
  - Passed any parsed query parameters included in the request for validation.
- [`parse_request_headers/2`](#parse_request_headers)
  - Passed all request headers included in the request for validation.
- [`process_request/2`](#process_request)
  - Passed a `riak_api_web_body:req_body/0` object (or `none`) so that the value may be fetched, and the request processed and the response returned (either as a binary or a streaming function that will incrementally generate the binary).
- [`record_request/3`](#record_request)
  - Passed timing information about the request to be recorded as required.

At each callback a `context` object is required to be returned.  The format of this object is opaque to the acceptor, but the object will be forwarded as an attribute as-is to the next callback in the list.  So as the request is parsed and validated through its callback functions, the module should update the `context` with any information that might be relevant to its own callback functions later in the handling of the request.

For `check_permissions/5`, `parse_query_params/2`, `parse_request_headers/2` and `process_request` the workflow can be terminated by returning a `riak_api_web_acceptor:halt_response()` rather than a positive response.  This will prompt the workflow to be immediately terminated, and a response returned with the information contained within the `halt_response()` (e.g. response code, headers and message body).

When a `halt_response()` is returned the connection will be closed, even where a `keepalive` request has been made.

#### match_route

This callback function should attempt to match the module to the path, and either return:

- an `ok` process with the size limits for the module (count of headers, maximum byte-size of an individual header, and the maximum size of the body of the request), and an initial context object for the request.
- a `nomatch` response indicating the module does not support that path (and so the next module in the route priority list should be tried).
- a `method_not_allowed` response to indicate that the path matched but the method is not in the supported list of methods for this module.

The `match_route` callback will receive:

- 'Method'; an atom representing the HTTP request method.
- 'Path'; the full path as a binary string - using Syntax-Based Normalization as defined by [RFC 3986](https://www.ietf.org/rfc/rfc3986.txt).
- 'Split Path'; the full path split into a list of individual elements separated by "/", with each element percent decoded.

e.g. `GET /types/T/buckets/B/keys/K?returnbody=true HTTP/1.1` will lead to call to:

```erlang
match_route('GET', <<"/types/T/buckets/B/keys/K">>, [<<"types">>, <<"T">>, <<"buckets">>, <<"B">>, <<"keys">>, <<"K">>])
```

The split path (list) is trimmed of any leading or trailing empty elements e.g. "/stats/" and "/stats" will be equivalent.  The URL will be normalised and unquoted before calling `match_route/3` - e.g. handling any "\..\"-style directory traversal and % encoding of non-standard characters.

All modules are tried until either an `ok` is returned.  If all modules return `nomatch` a '404' error is returned.  If at least one module returns `method_not_allowed` a [HTTP 405](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/405) error response will be triggered, with the allowed methods indicated in the response being the union of all methods returned in `method_not_allowed` responses.

#### check_permissions

The check_permissions callback function will be passed:

- All request headers as a `riak_api_web_headers:headers()` object which can be managed via the `riak_api_web_headers` module.
- The scheme for the listener (e.g. http or https).
- The IP address of the peer making the request.
- The client certificate used in any TLS negotiation (or `undefined` if no certificate used).
- The context object returned from the `match_route` function call.  The context object should have been initiated with any details necessary to make a permission check from the path (e.g. in Riak the object Bucket).

The check_permission should return either an `ok` response with a potentially updated context or a `halt_response()`.

Within Riak, most check_permissions implementation should use the `riak_kv_web_common:check_permissions/5` function, to standardise the application of security controls.

#### parse_query_params

The query parameters will be passed as list of `{Key, Value}` tuples with the Key and Value both being binaries as they were presented in the URI (following percent decoding).  If a key is provided as a parameter within the query parameters without value, the value will be the atom `true`.

As with other callbacks, valid responses are either an `ok` with updated context object, or a `halt_response()` (for example if an invalid query parameter has been provided).

#### parse_request_headers

The request headers will be passed as `riak_api_web_headers:headers()` object which can be managed via the `riak_api_web_headers` module.  Note this will be the same information as passed into the `check_permissions` callback.  It is recommended to defer parsing non-security request headers until this stage (when permissions have already been checked), to reduce the workload undertaken on unverified requests.

As with other callbacks, valid responses are either an `ok` with updated context object, or a `halt_response()` (for example if an invalid request header has been provided).

The `riak_api_web_headers` module requires knowledge if the header has an `atom()` or a `binary()` as a key. The module has a `standard_header_key()` type which list all header keys which will be atoms and not binaries.  For binary keys, as well as fetching individual headers by key, it is also possible to fold to return all headers with a given prefix.  When fetching binary header keys, it can be specified that the header key being request has already been lower-cased (using `string:casefold/1`) so that lower-casing does not need to be repeated within the function.

Note that headers may have single values or multiple values, check the function spec and ensure both cases are handled if required.  Multiple values will occur either because the header value is a comma-separated list, or because multiple header values have been provided under a repeated header key.

Only the 'Content-Length' and 'Transfer-Encoding' headers are parsed within the framework - to obtain a static content length, or prepare for a chunked request body.  Only the transfer-encoding of `chunked` is managed within the framework.

There is no handling of information in other request headers within Silver Machine, all other headers are only handled within the callback functions.  So all headers that are expected to have meaning must be parsed and have appropriate details added to the context for downstream consideration in the `process_request/2` callback function (e.g. handling conditional headers such as 'If-None-Match', matching 'Accept' header to content-types provided, or validating `Referer' details).

#### process_request

The process_request callback function will be passed a `riak_api_web_body:req_body/0` object, or the atom `none`; as well as the context.

The atom `none` is provided instead of a `req_body` if and only if it had been stipulated in the size limits returned from the `match_route/3` callback that only a 0-length body is supported.  Before providing a `none` request body, the buffer is checked by the acceptor to confirm no body has been provided (and a ['413 Content Too Large'](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/413) response is returned if there is a body present).

At this stage the request body, if present, has not been read from the TCP buffer, and so sending of a large body will be suspended at the client (if the TCP window is full).  The acceptor (and the service it supports) is protected from a memory perspective until the body is fetched by the `process_request/2` callback function.  Fetching the body is managed through `riak_api_web_body:get_body/3` function, and the body may be fetched entirely, or partially up to a size limit.  Selecting the body in slices may be used if the intention is to slice and store large inbound requests without reading the whole request into memory.  There is no relationship between slices and chunks - slice sizes are defined on the server side, and chunk sizes are defined on the client side.

Calls to the `riak_api_web_body:get_body/3` will return either:

- `{binary(), req_body()}`; if the whole body has been requested it can be assumed the binary() is the whole body (no need to confirm by calling the function again to receive `done`).
- `{done, req_body()}`; if there is no further body to be received.
- `{error, content_too_large}`; the content has exceeded the limit returned from `match_route/3` callback.
- `{error, chunk_too_large}`; an individual chunk has been sent that is >= 4GB.
- `{error, trailer_fields_not_supported}`; a chunked encoded message has attempted to provided content after the end of the body, which is not presently supported in Silver Machine.

The `process_request/2` callback function should not return a positive response unless the entirety of the body has been read.  If the reading of the body is curtailed then a `halt_response()` must be returned as otherwise the handling of further requests in a keepalive connection may be corrupted.

A positive response to `process_request/2` must contain a response tuple as well as `ok` and the updated context object.  This tuple consists of:

```erlang
{
    riak_api_web_acceptor:response_code(),
    riak_api_web_headers:header_list(),
    response_body(),
    boolean(),
    riak_api_web_body:req_body()|none
}.
```

- response_code; the HTTP response code to be returned, this may be an error code as well as a positive code.  If supporting pipelined requests, it may be preferable to return `404` errors as a positive response rather than as a `halt_response()` that would cause the connection to be terminated.
- response header_list; a list of Key/Value tuples representing the headers to be added to the response.  Keys should be atom() if it is a standard_key, and otherwise a binary in the case it is intended to be presented.  The only headers added by SilverMachine will be a 'Date' Header, a 'Server' header, a 'Connection' header and either a 'Content-Length' header or 'Transfer-Encoding` header as appropriate.  Any user-provided headers that overlap with these default headers will override the defaults.
- The response body; either a binary() (in which case the response will be sent immediately with a fixed `Content-Length`), or a stream function in which case every binary returned from the stream function will be returned as a 'chunk' in a chink-encoded response (until the function returns the atom `done`).
- A keepalive supported boolean; may be switched from true to false if there is a requirement to close this connection rather than allow further requests to be received.
- the `req_body` remainder, i.e. the final `req_body` object returned from the call to `riak_api_web_body:get_body/3`.  In fetching the body, when supporting pipelined requests some of a subsequent request may be read into the buffer, and returning the final req_body object ensures that this buffer is available to the acceptor to process that request.  The atom `none` should be returned if the atom `none` was received as the request body.

For an example stream function to return the body, see the `riak_kv_ag_index` module.  Note that when calling `riak_api_web_body:get_body/3` the req_body object tracks the volume of data received versus the configured size limit - and may return `{error, content_too_large}` if the size is exceeded.

#### record_request

The record_request callback function is passed timing information from the handling of the request, as well as the request context object.  This is intended to be used for any statistics or logging activity required by the module.

## Limitations

Silver Machine is designed to support a subset of the HTTP protocol, the restrictions include:

- Limited to only support HTTP 1.0 and HTTP 1.1 connections;
  - HTTP 1.1 request pipelining is supported, but currently subject to limited testing.  Adding multiplexed requests (i.e. HTTP 2.0) will require a significant change.
- Supported methods are limited to 'OPTIONS', 'GET', 'HEAD', 'POST', 'PUT', 'DELETE' and 'TRACE' - but all functionality must exist within the callback functions of the handler modules.  The framework is unaware of what method is being used (and so may return a body to a HEAD request for example).
- Only 'Content-Length' and 'Transfer-Encoding' request headers are understood by the framework, and only chunked (rather than compressed) encoding is handled automatically.  Only 'Server', 'Date' and 'Connection' response headers are added by the framework, if not present in the output from the callback function.
- There is no control in the ordering of response HTTP headers, headers in the response on the wire by be returned in a different order to headers in the response returned by a callback function.
- TLS support is limited by that offered in the OTP deployment.
