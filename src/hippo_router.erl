-module(hippo_router).

-include("hippo.hrl").

-export([compile/1]).
-export([run/2]).

-record(spec, {request_cms :: ets:comp_match_spec()}).

-opaque spec() :: #spec{}.

-export_type([spec/0]).

-spec compile(MatchSpec) -> {ok, Spec} | {error, bad_match_spec} when
      MatchSpec :: ets:match_spec(),
      Spec :: spec().
compile(MatchSpec) ->
    try ets:match_spec_compile(MatchSpec) of
        CMS ->
            {ok, #spec{request_cms=CMS}}
    catch
        error:badarg ->
            {error, bad_match_spec}
    end.

-spec run(Request, Spec) -> {ok, Handler} | {error, Reason} when
      Request :: hippo_http:request(),
      Spec :: spec(),
      Handler :: {Module :: module(), Args :: any(), Opts :: list()},
      Reason :: not_found | {bad_handler, Other :: any}.
run(Request, #spec{request_cms=CMS}) ->
   case ets:match_spec_run([Request], CMS) of
        [{Mod, Args}] ->
            {init, Mod, Args};
        [] ->
            {error, not_found};
        [Other] ->
            {error, {bad_handler, Other}}
    end.
