-module(test_controller).

-behaviour(hippo_controller).

-define(TIMEOUT, 5000).

-export([init/1]).
-export([callback_mode/0]).
-export([handle/3]).
-export([code_change/4]).
-export([terminate/3]).

init(Data) ->
    {ok, handle, Data}.

callback_mode() ->
    state_functions.

handle(controller, get, Data) ->
    {keep_state_and_data, {next_event, view, {data, Data}}}.

code_change(_, State, Data, _) ->
    {ok, State, Data}.

terminate(_, _, _) ->
    ok.
