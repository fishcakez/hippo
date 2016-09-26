-module(test_view).

-behaviour(hippo_view).

-define(TIMEOUT, 5000).

-export([init/1]).
-export([callback_mode/0]).
-export([recv/3]).
-export([send/3]).
-export([await/3]).
-export([code_change/4]).
-export([terminate/3]).

init(Path) ->
    {ok, recv, Path,
     {next_event, hippo, {recv, ?TIMEOUT}}}.

callback_mode() ->
    state_functions.

recv(http, done, StateData) ->
    {next_state, send, StateData, {next_event, controller, get}};
recv(http, {error, Reason}, _) ->
    {stop, Reason};
recv(http, _,  _) ->
    {keep_state_and_data, {next_event, hippo, {recv, ?TIMEOUT}}}.

send(view, {data, Data}, StateData) when Data /= chunk ->
    Headers = [{<<"server">>, <<"Hippo">>}],
    {next_state, await, StateData,
     {next_event, hippo, {send_response, 200, Headers, Data}}}.

await(http, sent_response, _) ->
    stop.

code_change(_, State, StateData, _) ->
    {ok, State, StateData}.

terminate(_, _, _) ->
    ok.
