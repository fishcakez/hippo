-module(hippo_listener).

-behaviour(gen_server).

%% public api

-export([start_link/3]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

%% public api

-spec start_link(Pool, Acceptors, Opts) ->
    {ok, Pid} | {error, {inet, Reason} | Reason2} when
      Pool :: hippo_pool:pool(),
      Acceptors :: pos_integer(),
      Opts :: [gen_tcp:listen_option()],
      Pid :: pid(),
      Reason :: system_limit | inet:posix(),
      Reason2 :: any().
start_link(Pool, Acceptors, Opts) when is_integer(Acceptors), Acceptors > 0 ->
    gen_server:start_link(?MODULE, {Pool, Acceptors, Opts}, []).

%% gen_server api

init({Pool, Acceptors, Opts}) ->
    process_flag(trap_exit, true),
    % TODO: support ssl
    NOpts = [{reuseaddr, true}, {active, false}, {mode, binary} | Opts],
    case gen_tcp:listen(80, NOpts) of
        {ok, Sock} ->
            Ref = hippo_pool:attach(Pool, Sock, Acceptors),
            {ok, {Sock, Ref}};
        {error, Reason} ->
            {stop, {inet, Reason}}
    end.

handle_call(Req, _, State) ->
    {stop, {bad_call, Req}, State}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({'EXIT', Sock, Reason}, {Sock, Ref}) ->
    {stop, Reason, {undefined, Ref}};
handle_info({'DOWN', Ref, _, _, Reason}, {_, Ref} = State) ->
    {stop, {shutdown, Reason}, State};
handle_info(_, State) ->
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, {undefined, _}) ->
    ok;
terminate(_, {Sock, _}) ->
    gen_tcp:close(Sock).
