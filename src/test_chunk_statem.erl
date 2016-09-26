-module(test_chunk_statem).

-behaviour(hippo_statem).

-define(TIMEOUT, 5000).

-export([init/1]).
-export([callback_mode/0]).
-export([headers/3]).
-export([recv/3]).
-export([send/3]).
-export([code_change/4]).
-export([terminate/3]).

init(Path) ->
    {ok, headers, Path,
     {next_event, hippo, {recv, ?TIMEOUT}}}.

callback_mode() ->
    state_functions.

headers(http, {headers,  _Headers}, StateData) ->
    {next_state, recv, StateData, {next_event, hippo, {recv, async}}}.

recv(http, {chunk, _Chunk},  _) ->
    {keep_state_and_data, {next_event, hippo, {recv, async}}};
recv(http, done, StateData) ->
    Headers = [{<<"server">>, <<"Hippo">>}],
    {next_state, send, StateData,
     {next_event, hippo, {send_response, 200, Headers, chunk}}}.

send(http, sent_response, _) ->
    {keep_state_and_data,
     [{next_event, hippo, {send_chunk, <<"Hello ">>}},
      {next_event, hippo, {send_last_chunk, <<"World!">>}}]};
send(http, sent_chunk, _) ->
    keep_state_and_data;
send(http, sent_last_chunk, _) ->
    stop.

code_change(_, State, StateData, _) ->
    {ok, State, StateData}.

terminate(_, _, _) ->
    ok.
