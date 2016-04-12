-module(hippo_sup).

-behaviour(supervisor).

%% public API

-export([start_link/0]).

%% supervisor API

-export([init/1]).

%% public API

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% supervisor API

init([]) ->
    Date = #{id => hippo_date,
             start => {hippo_date, start_link, []}},
    {ok, {{one_for_one, 5, 300}, [Date]}}.
