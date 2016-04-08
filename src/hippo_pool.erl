-module(hippo_pool).

-behaviour(gen_server).

%% public api

-export([start_link/2]).
-export([start_link/3]).
-export([attach/3]).

%% gen_server api

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-define(DEFAULT_POOL_FLAGS, #{size => infinity, intensity => 1, period => 5}).

-type pool() :: pid() | atom() | {atom(), node()} | {via, module(), any()} |
                {global, any()}.

-export_type([pool/0]).

-record(state, {name,
                mod :: module(),
                args :: any(),
                size :: non_neg_integer() | infinity,
                intensity :: non_neg_integer(),
                period :: pos_integer(),
                spec :: hippo_router:spec(),
                listeners = #{} :: #{reference() => {pid(), port()}},
                accepting = #{} :: #{reference() => reference()},
                conns = #{} :: #{pid() => reference()}}).

%% TODO: support pool flags as {ok, PoolFlags, MatchSpec}
-callback init(Args) -> {ok, MatchSpec} | ignore when
      Args :: any(),
      MatchSpec :: ets:match_spec().

%% public api

-spec start_link(Module, Args) -> {ok, Pid} | ignore | {error, Reason} when
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: any().
start_link(Module, Args) ->
    gen_server:start_link(?MODULE, {self, Module, Args}, []).

-spec start_link(Name, Module, Args) ->
    {ok, Pid} | ignore | {error, Reason} when
      Name :: {local, atom()} | {via, module, any()} | {global, any()},
      Module :: module(),
      Args :: any(),
      Pid :: pid(),
      Reason :: any().
start_link(Name, Module, Args) ->
    gen_server:start_link(Name, ?MODULE, {Name, Module, Args}, []).

-spec attach(Pool, Sock, Acceptors) -> Ref when
      Pool :: pool(),
      Sock :: port(),
      Acceptors :: pos_integer(),
      Ref :: reference().
attach(Pool, Sock, Acceptors) when is_integer(Acceptors), Acceptors > 0 ->
    Req = {attach, self(), Sock, Acceptors},
    {attached, Pid} = gen_server:call(Pool, Req, infinity),
    monitor(process, Pid).

%% gen_server api

init({self, Mod, Args}) ->
    init({self(), Mod, Args});
init({Name, Mod, Args}) ->
    _ = process_flag(trap_exit, true),
    try Mod:init(Args) of
        Res ->
            init(Name, Mod, Args, Res)
    catch
        throw:Res ->
            init(Name, Mod, Args, Res)
    end.

%% TODO: Reply to supervisor calls
handle_call({attach, Owner, Sock, Acceptors}, _, State) ->
    Listener = monitor(process, Owner),
    NState = start_conns(Listener, Owner, Sock, Acceptors, State),
    {reply, {attached, self()}, NState}.

handle_cast(Req, State) ->
    {stop, {bad_cast, Req}, State}.

handle_info({'EXIT', Conn, _}, #state{conns=Conns} = State) ->
    % TODO: send supervisor_report for abnormal exit
    {noreply, State#state{conns=maps:remove(Conn, Conns)}};
handle_info({'ACCEPT', Mon}, #state{accepting=Accepting} = State) ->
    case Accepting of
        #{Mon := Listener} ->
            demonitor(Mon, [flush]),
            {noreply, start_conn(Listener, maps:remove(Mon, Accepting), State)};
        _ ->
            {noreply, State}
    end;
handle_info({'DOWN', Mon, _, _, _}, #state{accepting=Accepting} = State) ->
    case Accepting of
        #{Mon := Listener} ->
            {noreply, start_conn(Listener, maps:remove(Mon, Accepting), State)};
        _ ->
            {noreply, listener_down(Mon, State)}
    end;
handle_info(_, State) ->
    % TODO: log unexpected message
    {noreply, State}.

code_change(_, State, _) ->
    % TODO: Support supervisor style reconfiguration with code change
    {ok, State}.

terminate(_, #state{conns=Conns}) ->
    _ = [exit(Conn, shutdown) || {Conn, _} <- maps:to_list(Conns)],
    terminate(Conns).

terminate(Conns) ->
    % TODO: send supervisor_report for abnormal exit
    Conn = receive {'EXIT', Pid, _} -> Pid end,
    case maps:remove(Conn, Conns) of
        NConns when map_size(NConns) == 0 ->
            ok;
        NConns ->
            terminate(NConns)
    end.

%% Internal

%% TODO: Require PoolFlags once PoolFlags is implemented
init(Name, Mod, Args, {ok, MatchSpec}) ->
    init(Name, Mod, Args, #{}, MatchSpec);
init(Name, Mod, Args, {ok, PoolFlags, MatchSpec}) ->
    init(Name, Mod, Args, PoolFlags, MatchSpec);
init(_, _, _, ignore) ->
    ignore;
init(_, Mod, _, Other) ->
    {stop, {bad_return, {Mod, init, Other}}}.

init(Name, Mod, Args, PoolFlags, MatchSpec) ->
    case hippo_router:compile(MatchSpec) of
        {ok, Spec} when is_map(PoolFlags) ->
            NPoolFlags = maps:merge(?DEFAULT_POOL_FLAGS, PoolFlags),
            init_flags(Name, Mod, Args, NPoolFlags, PoolFlags, Spec);
        {ok, Spec} when tuple_size(PoolFlags) == 3 ->
            {Size, Intensity, Period} = PoolFlags,
            NPoolFlags = #{size => Size, intensity => Intensity,
                           period => Period},
            init_flags(Name, Mod, Args, NPoolFlags, PoolFlags, Spec);
        {ok, _} ->
            {stop, {bad_pool_flags, PoolFlags}};
        {error, bad_match_spec} ->
            {stop, {bad_match_spec, MatchSpec}}
    end.

init_flags(Name, Mod, Args, PoolFlags, ResFlags, Spec) ->
    case PoolFlags of
        #{size := Size, intensity := Intensity, period := Period}
          when ((is_integer(Size) andalso Size >= 0) orelse Size == infinity)
               andalso is_integer(Intensity) andalso Size >= 0
               andalso is_integer(Period) andalso Period >= 0 ->
            % TODO: Handle size of pool
            % TODO: Handle intensity/period of abnormal exits
            State = #state{name=Name, mod=Mod, args=Args, size=Size,
                           intensity=Intensity, period=Period,
                           spec=Spec},
            {ok, State};
        _ ->
            {stop, {bad_pool_flags, ResFlags}}
    end.

start_conns(Listener, Owner, Sock, Acceptors, State) ->
    #state{listeners=Listeners, accepting=Accepting, conns=Conns,
           spec=Spec} = State,
    {NAccepting, NConns} = start_conns(Listener, Sock, Spec, Acceptors,
                                       Accepting, Conns),
    State#state{listeners=Listeners#{Listener => {Owner, Sock}},
                accepting=NAccepting, conns=NConns}.

start_conns(_, _, _, 0, Accepting, Conns) ->
    {Accepting, Conns};
start_conns(Listener, Sock, Spec, N, Accepting, Conns) ->
    {Pid, Ref} = hippo_statem:spawn_monitor(Sock, Spec),
    NAccepting = Accepting#{Ref => Listener},
    NConns = Conns#{Pid => Listener},
    start_conns(Listener, Sock, Spec, N-1, NAccepting, NConns).

start_conn(Listener, Accepting,
           #state{listeners=Listeners, spec=Spec, conns=Conns} = State) ->
    case Listeners of
        #{Listener := {_, Sock}} ->
            {Pid, Ref} = hippo_statem:spawn_monitor(Sock, Spec),
            State#state{accepting=Accepting#{Ref => Listener},
                        conns=Conns#{Pid => Listener}};
        _ ->
            State#state{accepting=Accepting}
    end.

listener_down(Listener, #state{listeners=Listeners} = State) ->
    State#state{listeners=maps:remove(Listener, Listeners)}.
