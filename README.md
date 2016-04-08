hippo
=====

An OTP library

Build
-----

    $ rebar3 compile

Run
---

```erlang
 {ok, _} = test_pool:start_link(),
 {ok, _} = hippo_listener:start_link(test_pool, 32, [{port, 8000}, {nodelay, true}]),
 ok.
 ```
