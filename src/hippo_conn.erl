-module(hippo_conn).

-behaviour(gen_statem2).

-include("hippo.hrl").

%% public api

-export([spawn_monitor/2]).
-export([done/1]).
-export([request/2]).

%% proc_lib api

-export([init_it/3]).

%% gen_statem2 api

-export([init/1]).
-export([accept/3]).
-export([await/3]).
-export([handle/3]).
-export([close/3]).
-export([idle/3]).
-export([code_change/4]).
-export([terminate/3]).

-record(init, {starter :: pid(),
               accept_ref :: reference(),
               sock_ref :: non_neg_integer(),
               spec :: hd_statem_router:spec()}).

-record(state, {sock :: port(),
                spec :: hippo_router:spec(),
                handler :: {pid(), reference()} |
                           {pid(), reference(), module()} | close,
                next :: {pid(), reference()} | close,
                handlers = #{} :: #{pid() => module()}}).

-spec spawn_monitor(LSock, Spec) -> {Pid, Ref} when
      LSock :: port(),
      Spec :: hippo_router:spec(),
      Pid :: pid(),
      Ref :: reference().
spawn_monitor(LSock, Spec) ->
    SRef = make_ref(),
    Pid = proc_lib:spawn_link(?MODULE, init_it, [SRef, LSock, Spec]),
    ARef = monitor(process, Pid),
    _ = Pid ! {ack, SRef, self(), ARef},
    {Pid, ARef}.

-spec done(Conn) -> ok when
      Conn :: {pid(), reference()}.
done({Pid, Ref}) ->
    gen_statem2:cast(Pid, {done, Ref}).

request({Pid, Ref}, Mod) ->
    gen_statem2:cast(Pid, {request, Ref, Mod}).

-spec init_it(SRef, LSock, Spec) -> no_return when
      SRef :: reference(),
      LSock :: port(),
      Spec :: hippo_router:spec().
init_it(SRef, LSock, Spec) ->
    _ = process_flag(trap_exit, true),
    receive
        {ack, SRef, Starter, ARef} ->
           {ok, Ref} = prim_inet:async_accept(LSock, -1),
            Init = #init{spec=Spec, starter=Starter, accept_ref=ARef,
                         sock_ref=Ref},
            Opts = [], %[{debug, [trace]}],
            gen_statem2:enter_loop(?MODULE, Opts, state_functions, accept, Init,
                                   [])
    end.

init(Args) ->
    {stop, {bad_init, Args}}.

accept(info, {inet_async, _, Ref, {ok, Sock}},
       #init{sock_ref=Ref, starter=Starter, accept_ref=ARef, spec=Spec}) ->
    _ = Starter ! {'ACCEPT', ARef},
    _ = inet_db:register_socket(Sock, inet_tcp),
    {ok, PeerName} = inet:peername(Sock),
    {ok, SockName} = inet:sockname(Sock),
    Parser = hippo_http:new(SockName, PeerName),
    {ok, Pid1, Ref1} = hippo_statem:start_link(Parser, Sock),
    {ok, Pid2, Ref2} = hippo_statem:start_link(Sock),
    Next = {Pid2, Ref2},
    _ = Pid1 ! {keep_alive, Ref1, Spec, Next},
    State = #state{sock=Sock, spec=Spec, handler={Pid1, Ref1}, next=Next},
    {next_state, await, State};
accept(info, {inet_async, LSock, Ref, {error, Reason}}, #init{sock_ref=Ref}) ->
    gen_tcp:close(LSock),
    {stop, {shutdown, {inet, Reason}}}.

await(cast, {request, Ref, Mod}, #state{handler={Pid, Ref}} = State) ->
    {next_state, handle, State#state{handler={Pid, Ref, Mod}}};
await(info, {'EXIT', Pid, _}, #state{handler={Pid, _}} = State) ->
    handler_exit(State);
await(info, {'EXIT', Pid, _}, #state{next={Pid, _}} = State) ->
    next_exit(State);
await(info, {'EXIT', Pid, _}, State) ->
    handlers_exit(Pid, State).

handle(cast, {done, Ref},
       #state{handler={_, Ref, _}, next={Pid1, Ref1} = Handler,
              sock = Sock, spec=Spec} = State) ->
    {ok, Pid2, Ref2} = hippo_statem:start_link(Sock),
    Next = {Pid2, Ref2},
    _ = Pid1 ! {keep_alive, Ref1, Spec, Next},
    {next_state, await, State#state{handler=Handler, next=Next}};
handle(info, {'EXIT', Pid, _},
       #state{handler={Pid, _, _}, next={Pid2, Ref2}} = State) ->
    _ = Pid2 ! {error_response, Ref2, 500},
    Handler = {Pid2, Ref2, hippo_close},
    {next_state, close, State#state{handler=Handler, next=close}};
handle(info, {'EXIT', Pid, _}, #state{next={Pid, _}} = State) ->
    next_exit(State);
handle(info, {'EXIT', Pid, _}, State) ->
    handlers_exit(Pid, State).

close(info, {'EXIT', Pid, normal},
      #state{handler={Pid, _, hippo_close}, handlers=Handlers} = State) ->
    NHandlers = Handlers#{Pid => hipp_close},
    handlers_exit(Pid, State#state{handler=close, handlers=NHandlers});
close(info, {'EXIT', Pid, _}, #state{handler={Pid, _, _}} = State) ->
    handler_exit(State);
close(info, {'EXIT', Pid, _}, State) ->
    handlers_exit(Pid, State).

idle(info, {'EXIT', Pid, _}, State) ->
    handlers_exit(Pid, State).

code_change(_, State, StateData, _) ->
    {ok, State, StateData}.

terminate(_, _, _) ->
    ok.

%% Internal

handler_exit(#state{sock=Sock, handlers=Handlers} = State) ->
   ok = gen_tcp:close(Sock),
   case map_size(Handlers) of
        0 ->
            {stop, {shutdown, done}};
        _ ->
           % TODO: Stop next
           {next_state, idle, State#state{handler=close}}
    end.

next_exit(#state{sock=Sock}) ->
   ok = gen_tcp:close(Sock),
   {stop, shutdown}.

handlers_exit(Pid, #state{handler=Handler, handlers=Handlers} = State) ->
    case maps:remove(Pid, Handlers) of
        NHandlers when map_size(NHandlers) =:= 0, map_size(Handlers) =:= 1,
                       Handler == close ->
            {stop, {shutdown, done}};
        NHandlers ->
            {keep_state, State#state{handlers=NHandlers}}
    end.
