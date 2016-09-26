-module(hippo_vc).

-behaviour(hippo_statem).

-export([init/1]).
-export([callback_mode/0]).
-export([handle_event/4]).
-export([code_change/4]).
-export([terminate/3]).

-record(status, {view_timer :: reference() | undefined,
                 view_postpone = [] :: list(),
                 view_mode :: gen_statem:callback_mode(),
                 controller_timer :: reference() | undefined,
                 controller_postpone = [] :: list(),
                 controller_mode :: gen_statem:callback_mode()}).

init({VMod, VArgs, CMod, CArgs}) ->
    try VMod:init(VArgs) of
        Result -> view_init(Result, VMod, CMod, CArgs)
    catch
        throw:Result -> view_init(Result, VMod, CMod, CArgs)
    end.

callback_mode() -> handle_event_function.

handle_event(http, Event, State, Data) ->
    view_event(http, Event, State, Data);
handle_event(internal, {view, Event}, State, Data) ->
    view_event(view, Event, State, Data);
handle_event(internal, {view_internal, Event}, State, Data) ->
    view_event(internal, Event, State, Data);
handle_event(timeout, {view, Event}, State, Data) ->
    view_event(timeout, Event, State, Data);
handle_event(info, {timeout, VTimer, Event}, _,
             {VData, CData, #status{view_timer=VTimer} = Status}) ->
    {keep_state, {VData, CData, Status#status{view_timer=undefined}},
     {next_event, timeout, {view, Event}}};
handle_event(internal, {controller, Event}, State, Data) ->
    controller_event(controller, Event, State, Data);
handle_event(internal, {controller_internal, Event}, State, Data) ->
    controller_event(internal, Event, State, Data);
handle_event(timeout, {controller, Event}, State, Data) ->
    controller_event(timeout, Event, State, Data);
handle_event(info, {timeout, CTimer, Event}, _,
             {VData, CData, #status{controller_timer=CTimer} = Status}) ->
    {keep_state, {VData, CData, Status#status{controller_timer=undefined}},
     {next_event, timeout, {controller, Event}}};
handle_event(Type, Event, State, Data) when Type /= internal, Type /= timeout ->
    controller_event(Type, Event, State, Data).

code_change(OldVsn, {VMod, VState, _, _} = State, {VData, _, _} = Data,
            Extra) ->
    try VMod:code_change(OldVsn, VState, VData, Extra) of
        Result       -> view_code(Result, OldVsn, State, Data, Extra)
    catch
        throw:Result -> view_code(Result, OldVsn, State, Data, Extra)
    end.

terminate(Reason, {VMod, VState, CMod, CState}, {VData, CData, Status}) ->
    terminate(Status),
    try
        CMod:terminate(Reason, CState, CData)
    after
        VMod:terminate(Reason, VState, VData)
    end.

%% internal

view_init({ok, VState, VData}, VMod, CMod, CArgs) ->
    view_init({ok, VState, VData, []}, VMod, CMod, CArgs);
view_init({ok, VState, VData, VActions}, VMod, CMod, CArgs) ->
    case controller_init(CMod, CArgs) of
        {ok, CState, CData, CActions} ->
            VMode = callback_mode(VMod),
            {Actions, VTimer, _} = view_actions(VActions),
            CMode = callback_mode(CMod),
            {Actions2, CTimer, _} = controller_actions(CActions),
            Status = #status{view_timer=VTimer, view_mode=VMode,
                             controller_timer=CTimer, controller_mode=CMode},
            {ok, {VMod, VState, CMod, CState}, {VData, CData, Status},
             Actions ++ Actions2};
        ignore ->
            view_cancel(VMod, normal, VState, VData, ignore);
        {stop, Reason} = Stop ->
            view_cancel(VMod, Reason, VState, VData, Stop);
        {bad_return_value, Other} ->
            Reason = {CMod, {bad_return_value, Other}},
            view_cancel(VMod, Reason, VState, VData, {stop, Reason});
        {exit, Reason, _} = Raise ->
            view_cancel(VMod, Reason, VState, VData, Raise);
        {error, Reason, Stack} = Raise ->
            view_cancel(VMod, {Reason, Stack}, VState, VData, Raise)
    end;
view_init(Other, _, _, _) ->
    Other.

callback_mode(Mod) ->
    try Mod:callback_mode() of
        Mode ->
            Mode
    catch
        throw:Mode ->
            Mode
    end.

view_cancel(VMod, Reason, VState, VData, After) ->
    try VMod:terminate(Reason, VState, VData) of
        _       -> view_cancel(After)
    catch
        throw:_ -> view_cancel(After)
    end.

view_cancel({Class, Reason, Stack}) ->
    erlang:raise(Class, Reason, Stack);
view_cancel(Result) ->
    Result.

controller_init(CMod, CArgs) ->
    try CMod:init(CArgs) of
        Result       -> controller_init(Result)
    catch
        throw:Result -> controller_init(Result);
        Class:Reason -> {Class, Reason, erlang:get_stacktrace()}
    end.

controller_init({ok, CState, CData}) -> {ok, CState, CData, []};
controller_init({ok, _, _, _} = OK)  -> OK;
controller_init(ignore)              -> ignore;
controller_init({stop, _} = Stop)    -> Stop;
controller_init(Other)               -> {bad_return_value, Other}.

view_event(Type, Event, State,
           {VData, CData, #status{view_timer=VTimer} = Status})
  when is_reference(VTimer) ->
    NData = {VData, CData, Status#status{view_timer=cancel_timer(VTimer)}},
    view_event(Type, Event, State, NData);
view_event(Type, Event, {VMod, VState, _, _} = State,
           {VData, _, #status{view_mode=state_functions}} = Data) ->
    try VMod:VState(Type, Event, VData) of
        Result       -> view_state(Result, Type, Event, State, Data)
    catch
        throw:Result -> view_state(Result, Type, Event, State, Data)
    end;
view_event(Type, Event, {VMod, VState, _, _} = State,
           {VData, _, #status{view_mode=handle_event_function}} = Data) ->
    try VMod:handle_event(Type, Event, VState, VData) of
        Result       -> view_handle(Result, Type, Event, State, Data)
    catch
        throw:Result -> view_handle(Result, Type, Event, State, Data)
    end.

view_state({next_state, VState, VData}, Type, Event, State, Data)
  when is_atom(VState) ->
    view_next(VState, VData, [], Type, Event, State, Data);
view_state({next_state, VState, VData, Actions}, Type, Event, State,
                     Data) when is_atom(VState) ->
    view_next(VState, VData, Actions, Type, Event, State, Data);
view_state(Result, Type, Event, _, Data) ->
    view_common(Result, Type, Event, Data).

view_handle({next_state, VState, VData}, Type, Event, State, Data) ->
    view_next(VState, VData, [], Type, Event, State, Data);
view_handle({next_state, VState, VData, Actions}, Type, Event, State,
                  Data) ->
    view_next(VState, VData, Actions, Type, Event, State, Data);
view_handle(Result, Type, Event, _, Data) ->
    view_common(Result, Type, Event, Data).

view_next(VState, VData, Actions, Type, Event, {VMod, _, CMod, CState},
          {_, CData, Status}) ->
    {NActions, VTimer, Postpone} = view_actions(Actions),
    #status{view_postpone=Postponed} = Status,
    NActions2 = lists:reverse(Postponed, NActions),
    NStatus = Status#status{view_postpone=[], view_timer=VTimer},
    NStatus2 = view_postpone(NStatus, Postpone, Type, Event),
    {next_state, {VMod, VState, CMod, CState}, {VData, CData, NStatus2},
     NActions2}.

view_postpone(Status, false, _, _) ->
    Status;
view_postpone(#status{view_postpone=Postponed} = Status, true, Type, Event) ->
    {[Action], _, _} = view_actions({next_event, Type, Event}),
    Status#status{view_postpone=[Action | Postponed]}.

view_common({keep_state, VData}, _, _, {_, CData, Status}) ->
    {keep_state, {VData, CData, Status}};
view_common({keep_state, VData, Actions}, Type, Event, Data) ->
    view_keep_state(VData, Actions, Type, Event, Data);
view_common(keep_state_and_data, _, _, Data) ->
    {keep_state, Data};
view_common({keep_state_and_data, Actions}, Type, Event,
            {VData, _, _} = Data)->
    view_keep_state(VData, Actions, Type, Event, Data);
view_common(stop, _, _, Data) ->
    {stop, normal, Data};
view_common({stop, Reason}, _, _, Data) ->
    {stop, Reason, Data};
view_common({stop, Reason, VData}, _, _, {_, CData, Status}) ->
    {stop, Reason, {VData, CData, Status}}.

view_keep_state(VData, Actions, Type, Event, {_, CData, Status}) ->
    {NActions, VTimer, Postpone} = view_actions(Actions),
    NStatus = Status#status{view_timer=VTimer},
    NStatus2 = view_postpone(NStatus, Postpone, Type, Event),
    {keep_state, {VData, CData, NStatus2}, NActions}.

view_actions(Actions) when is_list(Actions) ->
    view_actions(Actions, undefined, false, []);
view_actions(Action) ->
    view_actions([Action], undefined, false, []).

view_actions([], Timeout, Postpone, Acc) ->
    {Acc, start_timer(Timeout), Postpone};
view_actions([{timeout, _, _} = Timeout | Actions], _, Postpone, Acc) ->
    view_actions(Actions, Timeout, Postpone, Acc);
view_actions([{next_event, hippo, _} = Next | Actions], Timeout, Postpone,
             Acc) ->
    view_actions(Actions, Timeout, Postpone, [Next | Acc]);
view_actions([{next_event, Type, Event} | Actions], Timeout, Postpone, Acc)
  when Type == controller; Type == view; Type == http ->
    NAcc = [{next_event, internal, {Type, Event}} | Acc],
    view_actions(Actions, Timeout, Postpone, NAcc);
view_actions([{next_event, internal, Event} | Actions], Timeout, Postpone,
             Acc) ->
    NAcc = [{next_event, internal, {view_internal, Event}} | Acc],
    view_actions(Actions, Timeout, Postpone, NAcc);
view_actions([{next_event, timeout, Event} | Actions], Timeout, Postpone,
             Acc) ->
    NAcc = [{next_event, timeout, {view, Event}} | Acc],
    view_actions(Actions, Timeout, Postpone, NAcc);
view_actions([postpone | Actions], Timeout, _, Acc) ->
    view_actions(Actions, Timeout, true, Acc);
view_actions([{postpone, false} | Actions], Timeout, _, Acc) ->
    view_actions(Actions, Timeout, false, Acc);
view_actions([{postpone, true} | Actions], Timeout, _, Acc) ->
    view_actions(Actions, Timeout, true, Acc).


controller_event(Type, Event, State,
           {VData, CData, #status{controller_timer=CTimer} = Status})
  when is_reference(CTimer) ->
    NData = {VData, CData,
             Status#status{controller_timer=cancel_timer(CTimer)}},
    controller_event(Type, Event, State, NData);
controller_event(Type, Event, {_, _, CMod, CState} = State,
           {_, CData, #status{controller_mode=state_functions}} = Data) ->
    try CMod:CState(Type, Event, CData) of
        Result       -> controller_state(Result, Type, Event, State, Data)
    catch
        throw:Result -> controller_state(Result, Type, Event, State, Data)
    end;
controller_event(Type, Event, {_, _, CMod, CState} = State,
           {_, CData, #status{controller_mode=handle_event_function}} = Data) ->
    try CMod:handle_event(Type, Event, CState, CData) of
        Result       -> controller_handle(Result, Type, Event, State, Data)
    catch
        throw:Result -> controller_handle(Result, Type, Event, State, Data)
    end.

controller_state({next_state, CState, CData}, Type, Event, State, Data)
  when is_atom(CState) ->
    controller_next(CState, CData, [], Type, Event, State, Data);
controller_state({next_state, CState, CData, Actions}, Type, Event, State,
                 Data) when is_atom(CState) ->
    controller_next(CState, CData, Actions, Type, Event, State, Data);
controller_state(Result, Type, Event, _, Data) ->
    controller_common(Result, Type, Event, Data).

controller_handle({next_state, CState, CData}, Type, Event, State, Data) ->
    controller_next(CState, CData, [], Type, Event, State, Data);
controller_handle({next_state, CState, CData, Actions}, Type, Event, State,
                  Data) ->
    controller_next(CState, CData, Actions, Type, Event, State, Data);
controller_handle(Result, Type, Event, _, Data) ->
    controller_common(Result, Type, Event, Data).

controller_next(CState, CData, Actions, Type, Event, {VMod, VState, CMod, _},
                {VData, _, Status}) ->
    {NActions, CTimer, Postpone} = controller_actions(Actions),
    #status{controller_postpone=Postponed} = Status,
    NActions2 = lists:reverse(Postponed, NActions),
    NStatus = Status#status{controller_postpone=[], controller_timer=CTimer},
    NStatus2 = controller_postpone(NStatus, Postpone, Type, Event),
    {next_state, {VMod, VState, CMod, CState}, {VData, CData, NStatus2},
     NActions2}.

controller_postpone(Status, false, _, _) ->
    Status;
controller_postpone(#status{controller_postpone=Postponed} = Status, true, Type,
                    Event) ->
    {[Action], _, _} = controller_actions({next_event, Type, Event}),
    Status#status{controller_postpone=[Action | Postponed]}.

controller_common({keep_state, CData}, _, _, {VData, _, Status}) ->
    {keep_state, {VData, CData, Status}};
controller_common({keep_state, CData, Actions}, Type, Event, Data) ->
    controller_keep_state(CData, Actions, Type, Event, Data);
controller_common(keep_state_and_data, _, _, Data) ->
    {keep_state, Data};
controller_common({keep_state_and_data, Actions}, Type, Event,
            {_, CData, _} = Data)->
    controller_keep_state(CData, Actions, Type, Event, Data);
controller_common(stop, _, _, Data) ->
    {stop, normal, Data};
controller_common({stop, Reason}, _, _, Data) ->
    {stop, Reason, Data};
controller_common({stop, Reason, CData}, _, _, {VData, _, Status}) ->
    {stop, Reason, {VData, CData, Status}}.

controller_keep_state(CData, Actions, Type, Event, {VData, _, Status}) ->
    {NActions, CTimer, Postpone} = controller_actions(Actions),
    NStatus = Status#status{controller_timer=CTimer},
    NStatus2 = controller_postpone(NStatus, Postpone, Type, Event),
    {keep_state, {VData, CData, NStatus2}, NActions}.

controller_actions(Actions) when is_list(Actions) ->
    controller_actions(Actions, undefined, false, []);
controller_actions(Action) ->
    controller_actions([Action], undefined, false, []).

controller_actions([], Timeout, Postpone, Acc) ->
    {Acc, start_timer(Timeout), Postpone};
controller_actions([{timeout, _, _} = Timeout | Actions], _, Postpone, Acc) ->
    controller_actions(Actions, Timeout, Postpone, Acc);
controller_actions([{next_event, Type, Event} | Actions], Timeout, Postpone,
                   Acc)
  when Type == controller; Type == view ->
    NAcc = [{next_event, internal, {Type, Event}} | Acc],
    controller_actions(Actions, Timeout, Postpone, NAcc);
controller_actions([{next_event, internal, Event} | Actions], Timeout, Postpone,
                   Acc) ->
    NAcc = [{next_event, internal, {controller_internal, Event}} | Acc],
    controller_actions(Actions, Timeout, Postpone, NAcc);
controller_actions([{next_event, timeout, Event} | Actions], Timeout, Postpone,
                   Acc) ->
    NAcc = [{next_event, timeout, {controller, Event}} | Acc],
    controller_actions(Actions, Timeout, Postpone, NAcc);
controller_actions([{next_event, Type, _} = Next | Actions], Timeout, Postpone,
                   Acc)
  when Type == cast; Type == info ->
    controller_actions(Actions, Timeout, Postpone, [Next | Acc]);
controller_actions([{next_event, {call, _}, _} = Next | Actions], Timeout,
                   Postpone, Acc) ->
    controller_actions(Actions, Timeout, Postpone, [Next | Acc]);
controller_actions([postpone | Actions], Timeout, _, Acc) ->
    controller_actions(Actions, Timeout, true, Acc);
controller_actions([{postpone, false} | Actions], Timeout, _, Acc) ->
    controller_actions(Actions, Timeout, false, Acc);
controller_actions([{postpone, true} | Actions], Timeout, _, Acc) ->
    controller_actions(Actions, Timeout, true, Acc);
controller_actions([{reply, _, _} = Reply | Actions], Timeout, Postpone, Acc) ->
    controller_actions(Actions, Timeout, Postpone, [Reply | Acc]).

start_timer(undefined) ->
    undefined;
start_timer({timeout, infinity, _}) ->
    undefined;
start_timer({timeout, Timeout, Event}) ->
    erlang:start_timer(Timeout, self(), Event).

cancel_timer(undefined) ->
    undefined;
cancel_timer(Timer) ->
    case erlang:cancel_timer(Timer) of
        false -> flush_timer(Timer);
        _     -> undefined
    end.

flush_timer(Timer) ->
    receive
        {timeout, Timer, _} -> undefined
    after
        0                   -> undefined
    end.

view_code({ok, VState, VData}, OldVsn, {VMod, _, CMod, CState},
          {_, CData, #status{view_mode=VMode} = Status}, Extra)
  when (VMode == state_functions andalso is_atom(VState)) orelse
       (VMode == handle_event_function) ->
    try CMod:code_change(OldVsn, CState, CData, Extra) of
        Result       -> controller_code(Result, VMod, VState, VData, CMod,
                                        Status)
    catch
        throw:Result -> controller_code(Result, VMod, VState, VData, CMod,
                                        Status)
    end.

controller_code({ok, CState, CData}, VMod, VState, VData, CMod,
                #status{controller_mode=CMode} = Status)
  when (CMode == state_functions andalso is_atom(CState)) orelse
       (CMode == handle_event_function) ->
    {ok, {VMod, VState, CMod, CState}, {VData, CData, Status}}.

terminate(#status{view_timer=VTimer, controller_timer=CTimer}) ->
    cancel_timer(VTimer),
    cancel_timer(CTimer).
