-module(hippo_app).

-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_, _) ->
    hippo_sup:start_link().

stop(_) ->
    ok.
