# `riak_api` - Riak Client APIs

![Riak API OpenRiak Status](https://github.com/OpenRiak/riak_api/actions/workflows/erlang.yml/badge.svg?branch=openriak-4.0)

This OTP application encapsulates services for presenting Riak's public-facing interfaces.

There two APIs:

- An API using protocol buffers, with a codec defined in [riak_pb](https://github.com/OpenRiak/riak_pb), with the handling of messages managed using `riak_kv_pb_*` modules within Riak KV.
- A HTTP REST-based API (code-named Silver Machine), with the handling of requests defined using `riak_kv_ag_*` modules that implement the callbacks defined in the `riak_api_web_handler` behaviour.

For further information on using [Sliver Machine see the provided document](/docs/silverMachine.md).
