-module(hippo_statem).

-behaviour(gen_statem2).

-export([start_link/1]).
-export([start_link/2]).

-export([init_it/2]).
-export([init_it/3]).
-export([handle_event/4]).
-export([format_status/2]).
-export([code_change/4]).
-export([terminate/3]).

-define(INIT_TIMEOUT, infinity).
-define(REQUEST_TIMEOUT, 5000).

-record(init, {conn :: {pid(), reference()},
               sock :: port(),
               until = infinity :: integer() | infinity,
               spec = await :: hippo_router:spec() | await,
               next = await :: {pid(), reference()} | await}).

-record(state, {req :: {headers, [{binary(), binary()}]} | chunk | async | done,
                resp = await :: await | chunk | done,
                next :: {pid(), reference()},
                mode = handle_event_function :: gen_statem2:callback_mode(),
                conn :: {pid(), reference()},
                sock :: port(),
                parser :: hippo_http:parse() | done,
                mod :: module()}).

-spec start_link(Sock) -> {ok, Pid, Ref} when
      Sock :: port(),
      Pid :: pid(),
      Ref :: reference().
start_link(Sock) ->
    Ref = make_ref(),
    Conn = {self(), Ref},
    Pid = proc_lib:spawn_link(?MODULE, init_it, [Sock, Conn]),
    {ok, Pid, Ref}.

-spec start_link(Parser, Sock) -> {ok, Pid, Ref} when
      Parser :: hippo_http:parse(),
      Sock :: port(),
      Pid :: pid(),
      Ref :: reference().
start_link(Parser, Sock) ->
    Ref = make_ref(),
    Conn = {self(), Ref},
    Pid = proc_lib:spawn_link(?MODULE, init_it, [Parser, Sock, Conn]),
    {ok, Pid, Ref}.

-spec init_it(Sock, Conn) -> no_return() when
      Sock :: port(),
      Conn :: {pid(), reference()}.
init_it(Sock, {_, Ref} = Conn) ->
    InitState = #init{conn=Conn, sock=Sock},
    receive
        {keep_alive, Ref, Parser} ->
            init_parse(hippo_http:parse(Parser), InitState)
    end.

-spec init_it(Parser, Sock, Conn) -> no_return() when
      Parser :: hippo_http:parse(),
      Sock :: port(),
      Conn :: {pid(), reference()}.
init_it(Parser, Sock, Conn) ->
    InitState = #init{conn=Conn, sock=Sock},
    init_recv(gen_tcp:recv(Sock, 0, ?INIT_TIMEOUT), Parser, InitState).

handle_event(internal, {hippo_recv, _}, _,
             {#state{req={headers, Headers}} = HippoState, StateData}) ->
    NHippoState = HippoState#state{req=chunk},
    keep_insert(NHippoState, StateData, {hippo_recv_headers, Headers});
handle_event(internal, {hippo_recv, Timeout}, _,
             {#state{req=chunk, parser=Parser, sock=Sock} = HippoState,
              StateData}) ->
    case parse(Parser, Sock, Timeout) of
        {more, _, NParser} when Timeout == async ->
            NHippoState = HippoState#state{req=async, parser=NParser},
            {keep_state, {NHippoState, StateData}};
        {chunk, Chunk, NParser} ->
            NHippoState = HippoState#state{parser=NParser},
            keep_insert(NHippoState, StateData, {hippo_recv_chunk, Chunk});
        {trailers, Trailers, NParser} ->
            NHippoState = HippoState#state{req=done, parser=NParser},
            Event = {hippo_recv_trailers, Trailers},
            keep_insert(NHippoState, StateData, Event);
        {done, NParser} ->
            NHippoState = req_done(NParser, HippoState),
            keep_insert(NHippoState, StateData, hippo_recv_done);
        {error, Reason, NParser} ->
            NHippoState = recv_error(NParser, HippoState),
            keep_insert(NHippoState, StateData, {hippo_recv_error, Reason})
    end;
handle_event(internal, {hippo_recv, _}, _, {#state{req=done}, _}) ->
    {keep_state_and_data, {next_event, internal, hippp_recv_done}};
handle_event(internal, {hippo_recv, _}, _, {#state{req=async}, _}) ->
    {keep_state_and_data, {next_event, internal, hippo_recv_async}};
handle_event(internal, {hippo_send_response, Status, Headers, Body}, _,
             {HippoState, StateData}) ->
    case send_response(Status, Headers, Body, HippoState) of
        {sent_response, NParser} when Body == chunk ->
            NHippoState = HippoState#state{resp=chunk, parser=NParser},
            keep_insert(NHippoState, StateData, hippo_sent_response);
        {sent_response, NParser} ->
            NHippoState = resp_done(NParser, HippoState),
            keep_insert(NHippoState, StateData, hippo_sent_response);
        {error, {hippo_http,  Reason}, NParser} ->
            send_stop(Reason, NParser, HippoState, StateData);
        {error, Reason, _} ->
            NHippoState = send_error(HippoState),
            keep_insert(NHippoState, StateData, {hippo_send_error, Reason})
    end;
handle_event(internal, {hippo_send_chunk, Chunk}, _,
             {#state{sock=Sock, parser=Parser} = HippoState, StateData}) ->
    case send_chunk(Sock, Chunk, Parser) of
        {sent_chunk, NParser} ->
            NHippoState = HippoState#state{parser=NParser},
            keep_insert(NHippoState, StateData, hippo_sent_chunk);
        {error, {hippo_http,  Reason}, NParser} ->
            send_stop(Reason, NParser, HippoState, StateData);
        {error, Reason, _} ->
            NHippoState = send_error(HippoState),
            keep_insert(NHippoState, StateData, {hippo_send_error, Reason})
   end;
handle_event(internal, {hippo_send_last_chunk, Chunk}, _,
             {#state{sock=Sock, parser=Parser} = HippoState, StateData}) ->
    case send_last_chunk(Sock, Chunk, Parser) of
        {sent_last_chunk, NParser} ->
            NHippoState = resp_done(NParser, HippoState),
            keep_insert(NHippoState, StateData, hippo_sent_last_chunk);
        {error, {hippo_http,  Reason}, NParser} ->
            send_stop(Reason, NParser, HippoState, StateData);
        {error, Reason, _} ->
            NHippoState = send_error(HippoState),
            keep_insert(NHippoState, StateData, {hippo_send_error, Reason})
    end;
handle_event(Type, Event, State,
             {#state{mode=state_functions, mod=Mod} = HippoState, StateData}) ->
    try Mod:State(Type, Event, StateData) of
        Result ->
            state_function(Result, HippoState)
    catch
        throw:Result ->
            state_function(Result, HippoState)
    end;
handle_event(Type, Event, State,
             {#state{mode=handle_event_function, mod=Mod} = HippoState,
              StateData}) ->
    try Mod:handle_event(Type, Event, State, StateData) of
        Result ->
            handle_event_function(Result, HippoState)
    catch
        throw:Result ->
            handle_event_function(Result, HippoState)
    end.

format_status(Opt, [PDict, State, {#state{mod=Mod}, StateData}]) ->
    case erlang:function_exported(Mod, format_status, 2) of
        true ->
            Mod:format_status(Opt, [PDict, State, StateData]);
        false when Opt == terminate ->
            {State, StateData};
        false when Opt == normal ->
            [{data, [{"State", {State, StateData}}]}]
    end.

code_change(OldVsn, State, {#state{mod=Mod, mode=Mode} = HippoState, StateData},
            Extra) ->
    try Mod:code_change(OldVsn, State, StateData, Extra) of
        {ok, NState, StateData} when Mode == state_functions, is_atom(NState) ->
            {ok, NState, {HippoState, StateData}};
        {ok, NState, StateData} when Mode == handle_event_function ->
            {ok, NState, {HippoState, StateData}}
    catch
        throw:{ok, NState, StateData}
          when Mode == state_functions, is_atom(NState) ->
            {ok, NState, {HippoState, StateData}};
        throw:{ok, NState, StateData}
          when Mode == handle_event_function ->
            {ok, NState, {HippoState, StateData}}
    end.

terminate(Reason, State, {#state{mod=Mod}, StateData}) ->
    Mod:terminate(Reason, State, StateData).

%% Internal

init_parse({request, Request, Parser}, #init{sock=Sock} = InitState) ->
    case hippo_http:parse(Parser) of
        {headers, Headers, NParser} ->
            loop_await(NParser, Request, Headers, InitState);
        {more, _, NParser} ->
            Recv = gen_tcp:recv(Sock, 0, ?INIT_TIMEOUT),
            init_recv(Recv, NParser, Request, InitState)
    end;
init_parse({more, _, Parser}, #init{sock=Sock} = InitState) ->
    init_recv(gen_tcp:recv(Sock, 0, ?INIT_TIMEOUT), Parser, InitState).

init_parse({headers, Headers, NParser}, Request, InitState) ->
    loop_await(NParser, Request, Headers, InitState);
init_parse({more, _, NParser}, Request, InitState) ->
    loop_await(NParser, Request, InitState).

init_recv({ok, Data}, Parser, InitState) ->
    case hippo_http:parse(Data, Parser) of
        {request, Request, NParser} ->
            init_parse(hippo_http:parse(NParser), Request, InitState);
        {more, _, NParser} ->
            loop_await(NParser, InitState)
    end.

init_recv({ok, Data}, Parser, Request, InitState) ->
    case hippo_http:parse(Data, Parser) of
        {headers, Headers, NParser} ->
            loop_await(hippo_http:parse(NParser), Request, Headers, InitState);
        {more, _, NParser} ->
            loop_await(NParser, Request, InitState)
    end.

loop_await(Parser, #init{sock=Sock} = InitState) ->
    NInitState = loop_await(InitState),
    Recv = gen_tcp:recv(Sock, 0, ?REQUEST_TIMEOUT),
    loop_recv(Recv, Parser, NInitState).

loop_await(Parser, Request, #init{sock=Sock} = InitState) ->
    NInitState = loop_await(InitState),
    Recv = gen_tcp:recv(Sock, 0, ?REQUEST_TIMEOUT),
    loop_recv(Recv, Parser, Request, NInitState).

loop_await(Parser, Request, Headers, InitState) ->
    NInitState = loop_await(InitState),
    loop_route(Parser, Request, Headers, NInitState).

loop_await(#init{conn={_, Ref}} = InitState) ->
    receive
        {keep_alive, Ref, Spec, Next} ->
            InitState#init{spec=Spec, next=Next}
    end.

loop_recv({ok, Data}, Parser, InitState) ->
    case hippo_http:parse(Data, Parser) of
        {request, Request, NParser} ->
            loop_parse(hippo_http:parse(NParser), Request, InitState);
        {more, _, NParser} ->
            loop_recv(loop_recv(InitState), NParser, InitState)
    end.

loop_recv({ok, Data}, Parser, Request, InitState) ->
    loop_parse(hippo_http:parse(Data, Parser), Request, InitState).

loop_recv(#init{sock=Sock, until=Until}) ->
    Timeout = max(Until - erlang:monotonic_time(milli_seconds), 0),
    gen_tcp:recv(Sock, 0, Timeout).

loop_parse({headers, Headers, Parser}, Request, InitState) ->
    loop_route(Parser, Request, Headers, InitState);
loop_parse({more, _, Parser}, Request, InitState) ->
    loop_recv(loop_recv(InitState), Parser, Request, InitState).

loop_route(Parser, Request, Headers, #init{spec=Spec} = InitState) ->
    case hippo_router:run(Request, Spec) of
        {ok, {Mod, Args, Opts}} ->
            loop_init(Mod, Args, Opts, Parser, Headers, InitState)
    end.

loop_init(Mod, Args, Opts, Parser, Headers,
          #init{sock=Sock, conn=Conn, next=Next}) ->
    HippoState = #state{req={headers, Headers}, conn=Conn, sock=Sock, next=Next,
                        parser=Parser, mod=Mod},
    hippo_conn:request(Conn, Mod),
    try Mod:init(Args) of
        Result ->
            loop_init(Result, HippoState, Opts)
    catch
        throw:Result ->
            loop_init(Result, HippoState, Opts)
    end.

loop_init({Mode, State, StateData}, HippoState, Opts)
  when Mode == state_functions; Mode == handle_event_function ->
    enter_loop(Opts, State, HippoState#state{mode=Mode}, StateData, []);
loop_init({Mode, State, StateData, StateOps}, HippoState, Opts)
  when Mode == state_functions; Mode == handle_event_function ->
    NHippoState = HippoState#state{mode=Mode},
    enter_loop(Opts, State, NHippoState, StateData, StateOps);
loop_init({stop, Reason}, _, _) ->
    exit(Reason);
loop_init(ignore, _, _) ->
    exit(normal);
loop_init(Other, _, _) ->
    exit({bad_return_value, Other}).

enter_loop(Opts, State, HippoState, StateData, Actions) ->
    gen_statem2:enter_loop(?MODULE, Opts, handle_event_function, State,
                           {HippoState, StateData}, self(), Actions).

keep_insert(HippoState, StateData, Event) ->
    {keep_state, {HippoState, StateData}, {next_event, internal, Event}}.

state_function({next_state, State, StateData} = Result, HippoState)
  when is_atom(State) ->
    setelement(3, Result, {HippoState, StateData});
state_function({next_state, State, StateData, _} = Result, HippoState)
  when is_atom(State) ->
    setelement(3, Result, {HippoState, StateData});
state_function(Other, HippoState) ->
    common_state(Other, HippoState).

handle_event_function({next_state, _, StateData} = Result, HippoState) ->
    setelement(3, Result, {HippoState, StateData});
handle_event_function({next_state, _, StateData, _} = Result, HippoState) ->
    setelement(3, Result, {HippoState, StateData});
handle_event_function(Other, HippoState) ->
    common_state(Other, HippoState).

common_state({keep_state, StateData}, HippoState) ->
    {keep_state, {HippoState, StateData}};
common_state({keep_state, StateData, _} = Result, HippoState) ->
    setelement(2, Result, {HippoState, StateData});
common_state({stop, _, StateData} = Result, HippoState) ->
    setelement(3, Result, {HippoState, StateData});
common_state({stop_and_reply, _, _, StateData} = Result, HippoState) ->
    setelement(4, Result, {HippoState, StateData});
common_state(Other, _) ->
    Other.

parse(Parser, Sock, Timeout) ->
    case hippo_http:parse(Parser) of
        {more, _, NParser} when Timeout =/= async ->
            recv_parse(gen_tcp:recv(Sock, 0, Timeout), NParser);
        {error, Reason, NParser} ->
            {error, {hippo_http, Reason}, NParser};
        Result ->
            Result
    end.

recv_parse({ok, Buffer}, Parser) ->
    case hippo_http:parse(Buffer, Parser) of
        {more, 0, NParser} ->
            {chunk, <<>>, NParser};
        {error, Reason, NParser} ->
            {error, {hippo_http, Reason}, NParser};
        Result ->
            Result
    end;
recv_parse({error, Reason}, Parser) ->
    {error, {inet, Reason}, Parser}.

recv_error(Parser, #state{resp=Resp, conn=Conn} = HippoState) ->
    case Resp of
        done ->
            hippo_conn:done(Conn, close),
            HippoState#state{req=done, next=close, parser=done};
        _ ->
            HippoState#state{resp=done, parser=Parser}
    end.

send_response(Status, Headers, Body,
              #state{sock=Sock, parser=Parser, next=Next}) ->
    case hippo_http:response(Status, Headers, Body, Parser) of
        {response, Data, Connection, NParser} ->
            next(Next, Connection),
            send(Sock, Data, sent_response, NParser);
        {error, Reason, NParser} ->
            {error, {hippo_http, Reason}, NParser}
    end.

next({Pid, Ref}, {keep_alive, NextParser}) ->
    _ = Pid ! {keep_alive, Ref, NextParser},
    ok;
next({Pid, Ref}, close) ->
    _ = Pid ! {close, Ref},
    ok;
next({Pid, Ref}, shutdown) ->
    _ = Pid ! {shutdown, Ref},
    ok.

send_chunk(Sock, Chunk, Parser) ->
    case hippo_http:chunk(Chunk, Parser) of
        {more, _, NParser} ->
            {sent_chunk, NParser};
        {chunk, Data, NParser} ->
            send(Sock, Data, sent_chunk, NParser);
        {error, Reason, NParser} ->
            {error, {hippo_http, Reason}, NParser}
    end.

send_last_chunk(Sock, Chunk, Parser) ->
    case hippo_http:last_chunk(Chunk, Parser) of
        {last_chunk, Data, NParser} ->
            send(Sock, Data, sent_last_chunk, NParser);
        {error, Reason, NParser} ->
            {error, {hippo_http, Reason}, NParser}
    end.

send(Sock, Data, Result, Parser) ->
    case gen_tcp:send(Sock, Data) of
        ok ->
            {Result, Parser};
        {error, Reason} ->
            {error, {inet, Reason}, Parser}
    end.

resp_done(_, #state{req=done} = HippoState) ->
    done(HippoState);
resp_done(Parser, HippoState) ->
    HippoState#state{resp=done, parser=Parser}.

req_done(_, #state{resp=done} = HippoState) ->
    done(HippoState);
req_done(Parser, HippoState) ->
    HippoState#state{req=done, parser=Parser}.

done(#state{conn=Conn} = HippoState) ->
    hippo_conn:done(Conn),
    HippoState#state{req=done, resp=done, parser=done}.

send_error(#state{conn=Conn, sock=Sock} = HippoState) ->
    gen_tcp:close(Sock),
    hippo_conn:done(Conn),
    HippoState#state{req=done, resp=done, next=close, parser=done}. 

send_stop(Reason, Parser, HippoState, StateData) ->
    NHippoState = HippoState#state{parser=Parser},
    {stop, {hippo_send_error, Reason}, {NHippoState, StateData}}.
