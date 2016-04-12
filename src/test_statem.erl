-module(test_statem).

-behaviour(gen_statem2).

-export([init/1]).
-export([send/3]).
-export([code_change/4]).
-export([terminate/3]).

init(Path) ->
    Headers = [{<<"server">>, <<"Hippo">>},
               {<<"content-type">>, <<"text/plain">>}],
    Body = <<"Hello World!">>,
    {state_functions, send, Path,
     {next_event, internal, {hippo_send_response, 200, Headers, Body}}}.

send(_, hippo_sent_response, _) ->
    stop.

code_change(_, State, StateData, _) ->
    {ok, State, StateData}.

terminate(_, _, _) ->
    ok.
