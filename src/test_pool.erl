-module(test_pool).

-export([start_link/0]).
-export([accept_socket/3]).
-export([init/1]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("hippo.hrl").

start_link() ->
    acceptor_pool:start_link({local, ?MODULE}, ?MODULE, []).

accept_socket(Pool, Sock, NumAcceptors) ->
    acceptor_pool:accept_socket(Pool, Sock, NumAcceptors).

init(_) ->
    MS = ets:fun2ms(fun(#hippo_request{path=Path, sockname={_, 8001}}) ->
                            {test_statem, Path};
                       (#hippo_request{path=Path, sockname={_, 8000}}) ->
                            {test_chunk_statem, Path}
                    end),
    {ok, Router} = hippo_router:compile(MS),
    Spec = #{id => hippo_statem,
             start => {hippo_statem, Router, []}},
    {ok, {#{}, [Spec]}}.
