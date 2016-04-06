-module(test_statem).

-behaviour(gen_statem2).

-define(TIMEOUT, 5000).

-export([init/1]).
-export([headers/3]).
-export([recv/3]).
-export([send/3]).
-export([code_change/4]).
-export([terminate/3]).

init(Path) ->
    {state_functions, headers, Path,
     {next_event, internal, {hippo_recv, ?TIMEOUT}}}.

headers(_, {hippo_recv_headers,  _Headers}, StateData) ->
    {next_state, recv, StateData,
     {next_event, internal, {hippo_recv, ?TIMEOUT}}}.

recv(_, {hippo_recv_chunk, _Chunk},  _) ->
    {keep_state_and_data,
     {next_event, internal, {hippo_recv, ?TIMEOUT}}};
recv(_, hippo_recv_done, StateData) ->
    Headers = [{<<"date">>, <<"Tue, 29 Mar 2016 23:29:38 GMT">>},
               {<<"server">>, <<"Hippo">>}],
    Body = <<"Hello World!">>,
    {next_state, send, StateData,
     {next_event, internal, {hippo_send_response, 200, Headers, Body}}}.

send(_, hippo_sent_response, _) ->
    stop.

code_change(_, State, StateData, _) ->
    {ok, State, StateData}.

terminate(_, _, _) ->
    ok.
