hippo
=====

A proof of concept OTP style HTTP library with minimal learning curve beyond OTP but no docs and no tests. There are only single process abstractions with OTP style behaviours. Side effects and pure code separated are where possible.

Build
-----

    $ rebar3 compile

Run
---

```erlang
 {ok, _} = application:ensure_all_started(hippo),
 {ok, _} = test_pool:start_link(),
 {ok, _} = hippo_listener:start_link(test_pool, 32, [{port, 8000}, {nodelay, true}]),
 ok.
 ```
