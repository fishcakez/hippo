-module(test_chunk_statem).

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
     {next_event, internal, {hippo_recv, async}}}.

recv(_, {hippo_recv_chunk, _Chunk},  _) ->
    {keep_state_and_data,
     {next_event, internal, {hippo_recv, async}}};
recv(_, hippo_recv_done, StateData) ->
    Headers = [{<<"server">>, <<"Hippo">>}],
    {next_state, send, StateData,
     {next_event, internal, {hippo_send_response, 200, Headers, chunk}}}.

send(_, hippo_sent_response, _) ->
    {keep_state_and_data,
     [{next_event, internal, {hippo_send_chunk, <<"Hello ">>}},
      {next_event, internal, {hippo_send_last_chunk, <<"World!">>}}]};
send(_, hippo_sent_chunk, _) ->
    keep_state_and_data;
send(_, hippo_sent_last_chunk, _) ->
    stop.

code_change(_, State, StateData, _) ->
    {ok, State, StateData}.

terminate(_, _, _) ->
    ok.
