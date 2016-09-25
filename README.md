hippo
=====

A proof of concept OTP style HTTP library with minimal learning curve beyond OTP but no docs and no tests. There are only single process abstractions with OTP style behaviours. Side effects and pure code separated are where possible.

Build
-----

    $ rebar3 compile

Run
---

    $ rebar3 shell

```erlang
 {ok, _} = application:ensure_all_started(hippo),
 {ok, Pool} = test_pool:start_link(),
 Opts = [{nodelay, true}, {reuseaddr, true}, {active, once}, {mode, binary}],
 {ok, Sock} = gen_tcp:listen(8000, Opts),
 {ok, _} = test_pool:accept_socket(Pool, Sock, 32).
```
