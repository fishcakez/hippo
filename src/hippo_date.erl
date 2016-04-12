-module(hippo_date).

%% public API

-export([rfc5322_date/1]).
-export([start_link/0]).

%% gen_server API

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-ifndef(DATE_INTERVAL).
-define(DATE_INTERVAL, 1000).
-endif.

%% public API

-spec rfc5322_date(dirty | sync) -> iodata().
rfc5322_date(dirty) ->
    ets:lookup_element(?MODULE, date, 2);
rfc5322_date(sync) ->
    httpd_util:rfc1123_date().

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server API

init([]) ->
    Prep = ets:new(hippo_date_prepare,
                   [named_table, protected, {read_concurrency, true}]),
    Now = iolist_to_binary(rfc5322_date(sync)),
    true = ets:insert_new(Prep, {date, Now}),
    ?MODULE = ets:rename(Prep, ?MODULE),
    {ok, first()}.

handle_call(Req, _, Ref) ->
    {stop, {bad_call, Req}, Ref}.

handle_cast(Req, Ref) ->
    {stop, {bad_cast, Req}, Ref}.

handle_info({timeout, Ref, Next}, Ref) ->
    Now = iolist_to_binary(rfc5322_date(sync)),
    true = ets:update_element(?MODULE, date, {2, Now}),
    {noreply, next(Next)};
handle_info(Msg, Ref) ->
    error_logger:error_msg("hippo_date received unexpected message: ~p~n",
                           [Msg]),
    {noreply, Ref}.

code_change(_, Ref, _) ->
    {ok, Ref}.

terminate(_, _) ->
    ok.

%% internal

first() ->
    next(erlang:monotonic_time(milli_seconds) + ?DATE_INTERVAL).

next(Next) ->
    erlang:start_timer(Next, self(), Next + ?DATE_INTERVAL, [{abs, true}]).
