-module(test_pool).

-export([start_link/0]).
-export([init/1]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("hippo.hrl").

start_link() ->
    hippo_pool:start_link({local, ?MODULE}, ?MODULE, []).

init(_) ->
    MS = ets:fun2ms(fun(#hippo_request{path=Path, sockname={_, 8000}}) ->
                            {test_statem, Path, []};
                       (#hippo_request{path=Path, sockname={_, 8001}}) ->
                            {test_chunk_statem, Path, []}
                    end),
    {ok, MS}.
