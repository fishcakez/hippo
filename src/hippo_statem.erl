-module(hippo_statem).

-behaviour(acceptor).
-behaviour(gen_statem).

%% acceptor api

-export([acceptor_init/3]).
-export([acceptor_continue/3]).
-export([acceptor_terminate/2]).

%% gen_statem api

-export([init/1]).
-export([callback_mode/0]).
-export([handle_event/4]).
-export([format_status/2]).
-export([code_change/4]).
-export([terminate/3]).

-define(REQUEST_TIMEOUT, 5000).

-record(hippo, {recv = sync :: {headers, [{binary(), binary()}]} | sync | async,
                mode = handle_event_function :: gen_statem:callback_mode(),
                sock :: port(),
                ref :: reference(),
                parser :: hippo_http:parser() | done,
                conn = close :: close | shutdown | {keep_alive,
                                                    hippo_http:parser()},
                spec :: hippo_router:spec()}).


%% acceptor api

acceptor_init(SockName, LSock, Spec) ->
    Ref = monitor(port, LSock),
    {ok, #{sockname => SockName, ref => Ref, spec => Spec}}.

acceptor_continue(PeerName, Sock, AcceptState) ->
    #{sockname := SockName, ref := Ref, spec := Spec} = AcceptState,
    Parser = hippo_http:new(SockName, PeerName),
    HippoData = #hippo{sock=Sock, ref=Ref, spec=Spec, parser=Parser},
    gen_statem:enter_loop(?MODULE, [], await, HippoData, []).

acceptor_terminate(_, _) ->
    ok.

%% gen_statem api

init(_) ->
    {stop, enotsup}.

callback_mode() ->
    handle_event_function.

handle_event(info, {tcp, Sock, Data}, await,
             #hippo{sock=Sock, parser=Parser} = HippoData) ->
   case request(hippo_http:parse(Data, Parser), Sock) of
       {request, Request, Headers, NParser} ->
           {keep_state, HippoData#hippo{parser=NParser},
            {next_event, internal, {request, Request, Headers}}};
       {error, Reason, NParser} ->
           {keep_state, HippoData#hippo{parser=NParser},
            {next_event, internal, {error, Reason}}}
   end;
handle_event(info, {tcp_closed, Sock}, await, #hippo{sock=Sock}) ->
    {stop, {shutdown, {inet, closed}}};
handle_event(info, {tcp_error, Sock, Reason}, await, #hippo{sock=Sock}) ->
    {stop, {shutdown, {inet, Reason}}};
handle_event(internal, {request, Request, Headers}, await,
             #hippo{spec=Spec} = HippoData) ->
    case hippo_router:run(Request, Spec) of
        {init, _Mod, _Args} = Init ->
            {keep_state, HippoData#hippo{recv={headers, Headers}},
             {next_event, internal, Init}};
        {error, Reason} ->
            {keep_state_and_data,
             {next_event, internal, {error, {hippo_router, Reason}}}}
    end;
handle_event(internal, {init, Mod, Args}, await, HippoData) ->
    try Mod:init(Args) of
        Result ->
            init(Result, Mod, HippoData)
    catch
        throw:Result ->
            init(Result, Mod, HippoData)
    end;
handle_event(internal, {hippo_recv, _}, _,
             {StateData, #hippo{recv={headers, Headers}} = HippoData}) ->
    NHippoData = HippoData#hippo{recv=sync},
    keep_insert(NHippoData, StateData, {hippo_recv_headers, Headers});
handle_event(internal, {hippo_recv, Timeout}, _,
             {StateData,
              #hippo{recv=sync, parser=Parser, sock=Sock} = HippoData}) ->
    case parse(Parser, Sock, Timeout) of
        {chunk, Chunk, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser},
            keep_insert(NHippoData, StateData, {hippo_recv_chunk, Chunk});
        {trailers, Trailers, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser},
            Event = {hippo_recv_trailers, Trailers},
            keep_insert(NHippoData, StateData, Event);
        {done, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser},
            keep_insert(NHippoData, StateData, hippo_recv_done);
        {more, _, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=async},
            {keep_state, {StateData, NHippoData}};
        {error, Reason, NParser} ->
            NHippoData = recv_error(NParser, HippoData),
            keep_insert(NHippoData, StateData, {hippo_recv_error, Reason})
    end;
handle_event(internal, {hippo_recv, async}, _, {_, #hippo{recv=async}}) ->
    keep_state_and_data;
handle_event(internal, {hippo_recv, Timeout}, _,
             {StateData,
              #hippo{recv=async, parser=Parser, sock=Sock} = HippoData}) ->
    case async_parse(Parser, Sock, Timeout) of
        {chunk, Chunk, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=sync},
            keep_insert(NHippoData, StateData, {hippo_recv_chunk, Chunk});
        {trailers, Trailers, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=sync},
            Event = {hippo_recv_trailers, Trailers},
            keep_insert(NHippoData, StateData, Event);
        {done, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=sync},
            keep_insert(NHippoData, StateData, hippo_recv_done);
        {error, Reason, NParser} ->
            NHippoData = recv_error(NParser, HippoData#hippo{recv=sync}),
            keep_insert(NHippoData, StateData, {hippo_recv_error, Reason})
    end;
handle_event(internal, {hippo_send_response, Status, Headers, Body}, _,
             {StateData, HippoData}) ->
    case send_response(Status, Headers, Body, HippoData) of
        {sent_response, Conn, NParser} when Body == chunk ->
            NHippoData = HippoData#hippo{parser=NParser, conn=Conn},
            keep_insert(NHippoData, StateData, hippo_sent_response);
        {sent_response, Conn, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, conn=Conn},
            keep_insert(NHippoData, StateData, hippo_sent_response);
        {error, {hippo_http,  Reason}, NParser} ->
            send_stop(Reason, NParser, HippoData, StateData);
        {error, Reason, _} ->
            NHippoData = send_error(HippoData),
            keep_insert(NHippoData, StateData, {hippo_send_error, Reason})
    end;
handle_event(internal, {hippo_send_chunk, Chunk}, _,
             {StateData, #hippo{sock=Sock, parser=Parser} = HippoData}) ->
    case send_chunk(Sock, Chunk, Parser) of
        {sent_chunk, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser},
            keep_insert(NHippoData, StateData, hippo_sent_chunk);
        {error, {hippo_http,  Reason}, NParser} ->
            send_stop(Reason, NParser, HippoData, StateData);
        {error, Reason, _} ->
            NHippoData = send_error(HippoData),
            keep_insert(NHippoData, StateData, {hippo_send_error, Reason})
   end;
handle_event(internal, {hippo_send_last_chunk, Chunk}, _,
             {StateData, #hippo{sock=Sock, parser=Parser} = HippoData}) ->
    case send_last_chunk(Sock, Chunk, Parser) of
        {sent_last_chunk, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser},
            keep_insert(NHippoData, StateData, hippo_sent_last_chunk);
        {error, {hippo_http,  Reason}, NParser} ->
            send_stop(Reason, NParser, HippoData, StateData);
        {error, Reason, _} ->
            NHippoData = send_error(HippoData),
            keep_insert(NHippoData, StateData, {hippo_send_error, Reason})
    end;
handle_event(info, {tcp, Sock, Data}, {_, _},
             {StateData,
              #hippo{recv=async, sock=Sock, parser=Parser} = HippoData}) ->
    case recv_parse({ok, Data}, Parser) of
        {chunk, Chunk, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=sync},
            keep_insert(NHippoData, StateData, {hippo_recv_chunk, Chunk});
        {trailers, Trailers, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=sync},
            Event = {hippo_recv_trailers, Trailers},
            keep_insert(NHippoData, StateData, Event);
        {done, NParser} ->
            NHippoData = HippoData#hippo{parser=NParser, recv=sync},
            keep_insert(NHippoData, StateData, hippo_recv_done);
        {error, Reason, NParser} ->
            NHippoData = recv_error(NParser, HippoData#hippo{recv=sync}),
            keep_insert(NHippoData, StateData, {hippo_recv_error, Reason})
    end;
handle_event(info, {tcp_closed, Sock}, {_, _},
             {StateData, #hippo{recv=async, sock=Sock} = HippoData}) ->
    NHippoData = HippoData#hippo{recv=sync},
    keep_insert(NHippoData, StateData, {hippo_recv_error, {inet, closed}});
handle_event(info, {tcp_error, Sock, Reason}, {_, _},
             {StateData, #hippo{recv=async, sock=Sock} = HippoData}) ->
    NHippoData = HippoData#hippo{recv=sync},
    keep_insert(NHippoData, StateData, {hippo_recv_error, {inet, Reason}});
handle_event(info, {tcp_error, Sock, Reason}, await, #hippo{sock=Sock}) ->
    {stop, {shutdown, {inet, Reason}}};
handle_event(Type, Event, {Mod, State},
             {StateData, #hippo{mode=state_functions} = HippoData}) ->
    try Mod:State(Type, Event, StateData) of
        Result ->
            state_function(Result, Mod, State, StateData, HippoData)
    catch
        throw:Result ->
            state_function(Result, Mod, State, StateData, HippoData)
    end;
handle_event(Type, Event, {Mod, State},
             {StateData, #hippo{mode=handle_event_function} = HippoData}) ->
    try Mod:handle_event(Type, Event, State, StateData) of
        Result ->
            handle_event_function(Result, Mod, State, StateData, HippoData)
    catch
        throw:Result ->
            handle_event_function(Result, Mod, State, StateData, HippoData)
    end;
handle_event(internal, {terminate, Reason}, {terminate, Mod, State},
             {StateData, HippoData}) ->
    try Mod:terminate(Reason, State, StateData) of
        _ ->
            flush(HippoData)
    catch
        throw:_ ->
            flush(HippoData)
   end;
handle_event(cast, flushed, flush, #hippo{recv=sync, sock=Sock} = HippoData) ->
    case inet:setopts(Sock, [{active, once}]) of
        ok ->
            {next_state, await, HippoData};
        {error, Reason} ->
            {stop, {shutdown, {inet, Reason}}, HippoData}
    end;
handle_event(_, _, flush, _) ->
    keep_state_and_data.

format_status(Opt, [PDict, {Mod, State}, {StateData, _}]) ->
    case erlang:function_exported(Mod, format_status, 2) of
        true ->
            Mod:format_status(Opt, [PDict, State, StateData]);
        false when Opt == terminate ->
            {State, StateData};
        false when Opt == normal ->
            [{data, [{"State", {State, StateData}}]}]
    end;
format_status(terminate, [_, State, HippoData]) when is_atom(State) ->
    {State, HippoData};
format_status(normal, [_, State, HippoData]) when is_atom(State) ->
    [{data, [{"State", {State, HippoData}}]}];
format_status(Opt, [PDict, {terminate, Mod, State} | Data]) ->
    format_status(Opt, [PDict, {Mod, State} | Data]).

code_change(OldVsn, {Mod, State}, {StateData, #hippo{mode=Mode} = HippoState},
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
    end;
code_change(_, State, HippoState, _) when is_atom(State) ->
    {ok, State, HippoState}.

terminate(Reason, {Mod, State}, {StateData, _}) ->
    Mod:terminate(Reason, State, StateData);
terminate(_, State, _) when is_atom(State) ->
    ok;
terminate(_, {terminate, _, _}, _) ->
    % Terminate raised an error/exit
    ok.

%% Internal

request({request, Request, Parser}, Sock) ->
    headers(hippo_http:parse(Parser), Request, Sock);
request({more, _, _} = More, Sock) ->
    request(More, Sock, until());
request({error, Reason, Parser}, _) ->
    {error, {hippo_http, Reason}, Parser}.

request({request, Request, Parser}, Sock, Until) ->
    headers(hippo_http:parse(Parser), Request, Sock, Until);
request({more, _, Parser}, Sock, Until) ->
    case gen_tcp:recv(Sock, 0, timeout(Until)) of
        {ok, Data} ->
            request(hippo_http:parse(Data, Parser), Sock, Until);
        {error, Reason} ->
            {error, {inet, Reason}, Parser}
    end;
request({error, Reason, Parser}, _, _) ->
    {error, {hippo_http, Reason}, Parser}.

headers({headers, Headers, Parser}, Request, _) ->
    {request, Request, Headers, Parser};
headers({more, _, _} = More, Request, Sock) ->
    headers(More, Request, Sock, until());
headers({error, Reason, Parser}, _, _) ->
    {error, {hippo_http, Reason}, Parser}.

headers({headers, Headers, Parser}, Request, _, _) ->
    {request, Request, Headers, Parser};
headers({more, _, Parser}, Request, Sock, Until) ->
    case gen_tcp:recv(Sock, 0, timeout(Until)) of
        {ok, Data} ->
            headers(hippo_http:parse(Data, Parser), Request, Sock, Until);
        {error, Reason} ->
            {error, {inet, Reason}, Parser}
    end;
headers({error, Reason, Parser}, _, _, _) ->
    {error, {hippo_http, Reason}, Parser}.

until() ->
    erlang:monotonic_time(milli_seconds) + ?REQUEST_TIMEOUT.

timeout(Until) ->
    max(Until - erlang:monotonic_time(milli_seconds), 0).

init({ok, State, StateData}, Mod, HippoData) ->
    enter_loop(State, StateData, [], Mod, HippoData);
init({ok, State, StateData, Actions}, Mod, HippoData) ->
    enter_loop(State, StateData, Actions, Mod, HippoData);
init(ignore, Mod, _) ->
    {keep_state_and_data, {next_event, internal, {error, {Mod, normal}}}};
init({stop, Reason}, Mod, _) ->
    {keep_state_and_data, {next_event, internal, {error, {Mod, Reason}}}};
init(Other, Mod, _) ->
    {keep_state_and_data,
     {next_event, internal, {error, {Mod, {bad_return_value, Other}}}}}.

enter_loop(State, StateData, Actions, Mod, HippoState) ->
    NHippoState = HippoState#hippo{mode=callback_mode(Mod)},
    {next_state, {Mod, State}, {StateData, NHippoState}, Actions}.

callback_mode(Mod) ->
    try Mod:callback_mode() of
        Mode ->
            Mode
    catch
        throw:Mode ->
            Mode
    end.

keep_insert(HippoData, StateData, Event) ->
    {keep_state, {StateData, HippoData}, {next_event, internal, Event}}.

state_function({next_state, State, StateData}, Mod, _, _, HippoData)
  when is_atom(State) ->
    {next_state, {Mod, State}, {StateData, HippoData}};
state_function({next_state, State, StateData, Actions}, Mod, _, _, HippoData)
  when is_atom(State) ->
    {next_state, {Mod, State}, {StateData, HippoData}, Actions};
state_function(Other, Mod, State, StateData, HippoData) ->
    common_state(Other, Mod, State, StateData, HippoData).

handle_event_function({next_state, State, StateData}, Mod, _, _, HippoData) ->
    {next_state, {Mod, State}, {StateData, HippoData}};
handle_event_function({next_state, State, StateData, Actions}, Mod, _, _,
                      HippoData) ->
    {next_state, {Mod, State}, {StateData, HippoData}, Actions};
handle_event_function(Other, Mod, State, StateData, HippoData) ->
    common_state(Other, Mod, State, StateData, HippoData).

common_state({keep_state, StateData}, _, _, _, HippoData) ->
    {keep_state, {HippoData, StateData}};
common_state({keep_state, StateData, _} = Result, _, _, _, HippoData) ->
    setelement(2, Result, {HippoData, StateData});
common_state(stop, Mod, State, StateData, HippoData) ->
    {next_state, {terminate, Mod, State}, {StateData, HippoData},
     {next_event, internal, {terminate, normal}}};
common_state({stop, normal, StateData}, Mod, State, _, HippoData) ->
   {next_state, {terminate, Mod, State}, {StateData, HippoData},
     {next_event, internal, {terminate, normal}}};
common_state({stop, _, StateData} = Result, _, _, _, HippoData) ->
    setelement(3, Result, {HippoData, StateData});
common_state({stop_and_reply, normal, Replies}, Mod, State, StateData,
             HippoData) ->
    reply_then_stop(Replies, Mod, State, StateData, HippoData);
common_state({stop_and_reply, normal, Replies, StateData}, Mod, State, _,
             HippoData) ->
    reply_then_stop(Replies, Mod, State, StateData, HippoData);
common_state({stop_and_reply, _, _, StateData} = Result, _, _, _, HippoData) ->
    setelement(4, Result, {HippoData, StateData});
common_state(Other, _, _, _, _) ->
    Other.

reply_then_stop(Replies, Mod, State, StateData, HippoData) ->
    %% TODO: check replies are just replies!
    {next_state, {terminate, Mod, State}, {StateData, HippoData},
     Replies ++ [{next_event, internal, {terminate, normal}}]}.

flush(#hippo{conn={keep_alive, Parser}} = HippoData) ->
    %% TODO: include reference
    gen_statem:cast(self(), flushed),
    NHippoData = HippoData#hippo{conn=close, parser=Parser},
    {next_state, flush, NHippoData};
flush(#hippo{conn=close}) ->
    {stop, close};
flush(#hippo{conn=shutdown, sock=Sock}) ->
    _ = gen_tcp:shutdown(Sock, write),
    {stop, shutdown_close}.

parse(Parser, Sock, Timeout) ->
    case hippo_http:parse(Parser) of
        {more, _, NParser} when Timeout =/= async ->
            recv_parse(gen_tcp:recv(Sock, 0, Timeout), NParser);
        {more, _, _} = Result when Timeout =:= async ->
            async_recv(inet:setopts(Sock, [{active, once}]), Result);
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

async_recv(ok, Result) ->
    Result;
async_recv({error, Reason}, {_, _, Parser}) ->
    {error, {inet, Reason}, Parser}.

async_parse(Parser, Sock, Timeout) ->
    receive
        {tcp, Sock, Data} ->
            recv_parse({ok, Data}, Parser);
        {tcp_error, Sock, Reason} ->
            recv_parse({error, Reason}, Parser);
        {tcp_closed, Sock} ->
            recv_parse({error, closed}, Parser)
    after
        Timeout ->
            timeout_parse(Parser, Sock)
    end.

timeout_parse(Parser, Sock) ->
    case inet:setopts(Sock, [{active, false}]) of
        ok ->
            flush_parse(Parser, Sock, {error, timeout});
        {error, _} = Error ->
            flush_parse(Parser, Sock, Error)
    end.

flush_parse(Parser, Sock, Error) ->
    receive
        {tcp, Sock, Data} ->
            recv_parse({ok, Data}, Parser);
        {tcp_error, Sock, Reason} ->
            recv_parse({error, Reason}, Parser);
        {tcp_closed, Sock} ->
            recv_parse({error, closed}, Parser)
    after
        0 ->
            recv_parse(Error, Parser)
    end.

recv_error(Parser, HippoData) ->
    HippoData#hippo{parser=Parser}.

send_response(Status, Headers, Body,
              #hippo{sock=Sock, parser=Parser}) ->
    case hippo_http:response(Status, Headers, Body, Parser) of
        {response, Data, Connection, NParser} ->
            send(Sock, Data, {sent_response, Connection}, NParser);
        {error, Reason, NParser} ->
            {error, {hippo_http, Reason}, NParser}
    end.

send_chunk(Sock, Chunk, Parser) ->
    case hippo_http:chunk(Chunk, Parser) of
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
        ok when is_atom(Result) ->
            {Result, Parser};
        ok when is_tuple(Result) ->
            erlang:append_element(Result, Parser);
        {error, Reason} ->
            {error, {inet, Reason}, Parser}
    end.

send_error(#hippo{sock=Sock} = HippoData) ->
    gen_tcp:close(Sock),
    HippoData.

send_stop(Reason, Parser, HippoData, StateData) ->
    NHippoData = HippoData#hippo{parser=Parser},
    {stop, {hippo_send_error, Reason}, {StateData, NHippoData}}.
