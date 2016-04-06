-module(hippo_http).

-export([new/2]).
-export([parse/1]).
-export([parse/2]).
-export([response/4]).
-export([error_response/1]).
-export([chunk/2]).
-export([last_chunk/2]).
-export([status_error/1]).

-include("hippo.hrl").

-dialyzer({no_improper_lists, [parse/2, last_chunk/2]}).

-define(MAX_LENGTH_SIZE, 64).

-type req() :: await_request | {request, non_neg_integer()} | await_headers |
               headers | {continue, pos_integer() | chunked} |
               {body, pos_integer()} |
               await_chunk_line | chunk_line | {chunk_param, pos_integer()} |
               {chunk_body, pos_integer() | '\r\n' | '\n'} | trailers | failed |
               done.

-type resp() :: await_response | chunk | stream | failed | done.

-type method() :: get | post | put | head | delete | options | trace | copy |
                  lock | mkcol | move | purge | propfind | proppatch | unlock |
                  report | mkactivity | checkout | merge | m_search | search |
                  notify | subscribe | unsubscribe | patch.

-type version() :: '1.0' | '1.1'.

-type status() :: 100..102 | 200..208 | 226 | 300..308 | 400..419 | 421..424 |
                  426 | 428 | 429 | 431 | 451 | 500..508 | 510 | 511.

-type error() :: {request_line_too_long | empty_line_too_long |
                  unsupported_version | bad_request_line | unknown_method |
                  uri_too_long | invalid_uri | authority_uri |
                  headers_too_long | chunked_with_content_length |
                  invalid_header_line | duplicate_header | body_too_long |
                  invalid_content_length | invalid_header_line |
                  invalid_content_length | unknown_expectation|
                  unsupported_encoding | chunk_line_too_long |
                  invalid_chunk_line | trailers_too_long |
                  invalid_trailer_line | duplicate_trailer | done, iodata()} |
                 await_response | chunk | stream | done.

-type request() :: #hippo_request{}.

-export_type([method/0]).
-export_type([version/0]).
-export_type([status/0]).
-export_type([error/0]).
-export_type([request/0]).

-record(config, {crlf = binary:compile_pattern(<<"\r\n">>) :: binary:cp(),
                 crlf2 = binary:compile_pattern(<<"\r\n\r\n">>) :: binary:cp(),
                 crlf_semi = binary:compile_pattern([<<"\r\n">>, <<$;>>]) ::
                             binary:cp(),
                 sockname :: {inet:ip_address(), inet:port_num()},
                 peername :: {inet:ip_address(), inet:port_num()},
                 max_empty_line = application:get_env(hippo, max_empty_line,
                                                      32),
                 max_request_line = application:get_env(hippo, max_request_line,
                                                        8256),
                 max_uri = application:get_env(hippo, max_uri, 8192),
                 max_headers = application:get_env(hippo, max_headers, 65536),
                 max_body = application:get_env(hippo, max_body, 65536),
                 max_chunk_line = application:get_env(hippo, max_chunk_line,
                                                      128),
                 max_chunk = application:get_env(hippo, max_chunk, 65536),
                 max_trailers = application:get_env(hippo, max_trailers, 65536),
                 trailers = application:get_env(hippo, trailers, exclude),
                 http_1_0_connection = application:get_env(hippo,
                                                           http_1_0_connection,
                                                           keep_alive)}).

-record(parser, {config = #config{} :: #config{},
                 buffer :: binary() | done,
                 req = await_request :: req(),
                 resp = await_response :: resp(),
                 connection = undefined :: undefined | close | keep_alive |
                                           shutdown | upgrade | unknown |
                                           {force_close, undefined | close |
                                            keep_alive | shutdown | upgrade |
                                            unknown},
                 version = undefined :: undefined | version()}).

-record(body, {expect = undefined :: undefined | continue,
               transfer_encoding = undefined :: undefined | chunked,
               content_length = undefined :: undefined | non_neg_integer()}).


-opaque parser() :: #parser{}.

-export_type([parser/0]).

-spec new(SockName, PeerName) -> Parser when
      SockName :: {inet:ip_address(), inet:port_number()},
      PeerName :: {inet:ip_address(), inet:port_number()},
      Parser :: parser().
new(SockName, PeerName) ->
    #parser{buffer= <<>>, config=#config{sockname=SockName, peername=PeerName}}.

-spec parse(Parser) ->
    Request | Headers | Continue | Chunk | Trailers | Done | More | Error when
      Parser :: parser(),
      NParser :: parser(),
      Request :: {request, request(), NParser},
      Headers :: {headers, [{binary(), binary()}], NParser},
      Continue :: {continue, parser()},
      Chunk :: {chunk, iodata(), parser()},
      Trailers :: {trailers, [{binary(), binary()}], NParser},
      Done :: {done, NParser},
      More :: {more, non_neg_integer(), NParser},
      Error :: {error, error(), NParser}.
parse(#parser{buffer=Buffer, req=await_request} = Parser) ->
    request(Buffer, 0, 0, Parser);
parse(#parser{req={request, _}} = Parser) ->
    {more, 0, Parser};
parse(#parser{buffer=Buffer, req=await_headers} = Parser) ->
    parse_headers(Buffer, 0, Parser);
parse(#parser{req=headers} = Parser) ->
    {more, 0, Parser};
parse(#parser{req={continue, chunked}} = Parser) ->
    {continue, Parser#parser{req=await_chunk_line}};
parse(#parser{req={continue, Len}} = Parser) ->
    {continue, Parser#parser{req={body, Len}}};
parse(#parser{req={body, Len}, buffer= <<>>} = Parser) ->
    {more, Len, Parser};
parse(#parser{req={body, Len}, buffer=Buffer} = Parser)
  when byte_size(Buffer) < Len ->
    NParser = Parser#parser{buffer= <<>>, req={body, Len-byte_size(Buffer)}},
    {chunk, Buffer, NParser};
parse(#parser{req={body, Len}, buffer=Buffer} = Parser) ->
    <<Body:Len/binary, Rest/binary>> = Buffer,
    {chunk, Body, done(Rest, Parser)};
parse(#parser{buffer=Buffer, req=await_chunk_line} = Parser) ->
    parse_chunk_line(Buffer, 0, Parser);
parse(#parser{req=chunk_line} = Parser) ->
    {more, 0, Parser};
parse(#parser{req={chunk_param, _}} = Parser) ->
    {more, 0, Parser};
parse(#parser{req={chunk_body, _}, buffer= <<>>} = Parser) ->
    {more, 0, Parser};
parse(#parser{req=done, buffer=Buffer} = Parser) when is_binary(Buffer) ->
    {done, Parser};
parse(#parser{buffer=done} = Parser) ->
    {error, done, Parser}.

-spec parse(IOData, Parser) ->
    Request | Headers | Continue | Chunk | Trailers | Done | More | Error when
      IOData :: iodata(),
      Parser :: parser(),
      NParser :: parser(),
      Request :: {request, request(), NParser},
      Headers :: {headers, [{binary(), binary()}], NParser},
      Continue :: {continue, parser()},
      Chunk :: {chunk, iodata(), parser()},
      Trailers :: {trailers, [{binary(), binary()}], NParser},
      Done :: {done, NParser},
      More :: {more, non_neg_integer(), NParser},
      Error :: {error, error(), NParser}.
parse(<<>>, Parser) ->
    parse(Parser);
parse(Data, #parser{buffer=Buffer, req=await_request} = Parser) ->
    request(merge(Data, Buffer), 0, 0, Parser);
parse(Data, #parser{buffer=Buffer, req={request, Empty}} = Parser) ->
    % \r could be last byte in Buffer
    request(merge(Data, Buffer), max(byte_size(Buffer)-1, 0), Empty, Parser);
parse(Data, #parser{buffer=Buffer, req=await_headers} = Parser) ->
    parse_headers(merge(Data, Buffer), 0, Parser);
parse(Data, #parser{buffer=Buffer, req=headers} = Parser) ->
    % \r\n\r could be last 3 bytes in Buffer
    parse_headers(merge(Data, Buffer), max(byte_size(Buffer)-3, 0), Parser);
parse(Data, #parser{buffer=Buffer, req={continue, _}} = Parser) ->
    parse(Parser#parser{buffer=merge(Data, Buffer)});
parse(Data, #parser{buffer= <<>>, req={body, Len}} = Parser) ->
    case iolist_size(Data) of
        Size when Size < Len ->
            Rem = Len - Size,
            {chunk, Data, Parser#parser{buffer= <<>>, req={body, Rem}}};
        _ ->
            <<Body:Len, Rest/binary>> = iolist_to_binary(Data),
            {chunk, Body, done(Rest, Parser)}
    end;
parse(Data, #parser{buffer=Buffer, req={body, Len}} = Parser)
  when byte_size(Buffer) < Len ->
    NLen = Len - byte_size(Buffer),
    case iolist_size(Data) of
        Size when Size < NLen ->
            Body = [Buffer | Data],
            Rem = NLen - Size,
            {chunk, Body, Parser#parser{buffer= <<>>, req={body, Rem}}};
        _ ->
            <<RemBody:NLen/binary, Rest/binary>> = iolist_to_binary(Data),
            Body = [Buffer | RemBody],
            {chunk, Body, done(Rest, Parser)}
    end;
parse(Data, #parser{buffer=Buffer, req={body, Len}} = Parser) ->
    <<Body:Len/binary, Rest/binary>> = Buffer,
    {chunk, Body, done(merge(Data, Rest), Parser)};
parse(Data, #parser{buffer=Buffer, req=await_chunk_line} = Parser) ->
    parse_chunk_line(merge(Data, Buffer), 0, Parser);
parse(Data, #parser{buffer=Buffer, req=chunk_line} = Parser) ->
    parse_chunk_line(merge(Data, Buffer), byte_size(Buffer), Parser);
parse(Data, #parser{buffer=Buffer, req={chunk_param, SizeLen}} = Parser) ->
    Start = max(byte_size(Buffer)-1, 0),
    chunk_param(merge(Data, Buffer), SizeLen, Start, Parser);
parse(Data, #parser{buffer= <<>>, req={chunk_body, Len}} = Parser)
  when is_integer(Len) ->
    case iolist_size(Data) of
        Size when Size < Len ->
            {chunk, Data,
             Parser#parser{buffer= <<>>, req={chunk_body, Len-Size}}};
        Len ->
            {chunk, Data,
             Parser#parser{buffer= <<>>, req={chunk_body, '\r\n'}}};
        _ ->
            chunk_body(iolist_to_binary(Data), Len, Parser)
    end;
parse(Data, #parser{buffer= <<>>, req={chunk_body, NewLine}} = Parser) ->
    chunk_body(iolist_to_binary(Data), NewLine, Parser);
parse(Data, #parser{req=done, buffer=Buffer} = Parser) when is_binary(Buffer) ->
    {done, Parser#parser{buffer=merge(Data, Buffer)}};
parse(_, #parser{buffer=done} = Parser) ->
    {error, done, Parser}.

-spec response(Status, Headers, Body, Parser) ->
    {response, iodata(), Next, NParser} | {error, error(), Parser} when
      Status :: status(),
      Headers :: [{binary(), binary()}],
      Body :: iodata() | chunk,
      Parser :: parser(),
      Next :: {keep_alive, parser()} | close | shutdown,
      NParser :: parser().
response(Status, Headers, chunk,
         #parser{resp=await_response, version='1.1'} = Parser) ->
    {Next, NParser} = next(Parser),
    Data = [response(Status, Headers),
            <<"Transfer-Encoding: chunked\r\n">>,
            resp_connection(Next),
            $\r, $\n],
    {response, Data, Next, NParser#parser{resp=chunk}};
response(Status, Headers, chunk,
         #parser{resp=await_response, version='1.0'} = Parser) ->
    {Next, NParser} = next(Parser#parser{resp=stream, connection=shutdown}),
    Data = [response(Status, Headers),
            resp_connection(Next),
            $\r, $\n],
    {response, Data, Next, NParser};
response(Status, Headers, Body, #parser{resp=await_response} = Parser) ->
    {Next, NParser} = next(Parser),
    Data = [response(Status, Headers),
            resp_content_length(Body),
            resp_connection(Next),
            $\r, $\n |
            Body],
    {response, Data, Next, NParser#parser{resp=done}};
response(_, _, _, #parser{resp=stream} = Parser) ->
    {error, chunk, Parser};
response(_, _, _, #parser{resp=Resp} = Parser) ->
    {error, Resp, Parser}.

-spec error_response(Status) -> iodata() when
      Status :: status().
error_response(Status) ->
    [response(Status, [{<<"Connection">>, <<"close">>},
                       {<<"Content-Length">>, <<"0">>}]), $\r, $\n].

-spec chunk(iodata(), Parser) ->  Chunk | More | Error when
      Parser :: parser(),
      NParser :: parser(),
      Chunk :: {chunk, iodata(), NParser},
      More :: {more, non_neg_integer(), NParser},
      Error :: {error, error(), NParser}.
chunk(Data, #parser{resp=chunk} = Parser) ->
    case iolist_size(Data) of
        0 ->
            {more, 0, Parser};
        Len ->
            Chunk = [integer_to_binary(Len, 16), $\r, $\n, Data, $\r, $\n],
            {chunk, Chunk, Parser}
    end;
chunk(Data, #parser{resp=stream} = Parser) ->
    {chunk, Data, Parser};
chunk(_, #parser{resp=Resp} = Parser) ->
    {error, Resp, Parser}.

-spec last_chunk(iodata(), Parser) ->
    {last_chunk, iodata(), NParser} | {error, error(), NParser} when
      Parser :: parser(),
      NParser :: parser().
last_chunk(Data, #parser{resp=chunk} = Parser) ->
    NParser = Parser#parser{resp=done},
    case iolist_size(Data) of
        0 ->
            {last_chunk, <<"0\r\n\r\n">>, NParser};
        Len ->
            Chunk = [integer_to_binary(Len, 16), $\r, $\n, Data |
                     <<"\r\n0\r\n\r\n">>],
            {last_chunk, Chunk, NParser}
    end;
last_chunk(Data, #parser{resp=stream} = Parser) ->
    {last_chunk, Data, Parser#parser{resp=done}};
last_chunk(_, #parser{resp=Resp} = Parser) ->
    {error, Resp, Parser}.

-spec status_error(Error) -> Status when
      Error :: error(),
      Status :: status().
status_error({request_line_too_long, _}) ->
    414;
status_error({empty_line_too_long, _}) ->
    400;
status_error({unsupported_version, _}) ->
    505;
status_error({bad_request_line, _}) ->
    400;
status_error({unknown_method, _}) ->
    501;
status_error({uri_too_long, _}) ->
    414;
status_error({invalid_uri, _}) ->
    400;
status_error({authority_uri, _}) ->
    501;
status_error({headers_too_long, _}) ->
    431;
status_error({chunked_with_content_length, _}) ->
    400;
status_error({invalid_header_line, _}) ->
    400;
status_error({duplicate_header, _}) ->
    400;
status_error({body_too_long, _}) ->
    413;
status_error({invalid_content_length, _}) ->
    400;
status_error({unknown_expectation, _}) ->
    417;
status_error({unsupported_encoding, _}) ->
    501;
status_error({chunk_line_too_long, _}) ->
    400;
status_error({invalid_chunk_line, _}) ->
    400;
status_error({chunk_too_long, _}) ->
    413;
status_error({invalid_chunk_size, _}) ->
    400;
status_error({trailers_too_long, _}) ->
    431;
status_error({invalid_trailer_line, _}) ->
    400;
status_error({duplicate_trailer, _}) ->
    400;
status_error({done, _}) ->
    500;
status_error(await_response) ->
    500;
status_error(chunk) ->
    500;
status_error(done) ->
    500.

%% Internal

merge(Data, <<>>) when is_binary(Data) ->
    Data;
merge(Data, Buffer) when is_binary(Data) ->
    <<Buffer/binary, Data/binary>>;
merge(Data, Buffer) ->
    iolist_to_binary([Buffer | Data]).

request(Data, Start, Empty, #parser{config=Config} = Parser) ->
    #config{crlf=CRLF, max_request_line=MaxReqLine,
            max_empty_line=MaxEmpty} = Config,
    MatchLen = min(byte_size(Data), MaxReqLine) - Start,
    case binary:split(Data, CRLF, [{scope, {Start, MatchLen}}]) of
        [_] when byte_size(Data) > MaxReqLine ->
            {error, {request_line_too_long, Data}, fail(Parser)};
        [_] ->
            {more, 0, Parser#parser{buffer=Data, req={request, Empty}}};
        [<<>>, _] when Empty + 2 > MaxEmpty ->
            {error, {empty_line_too_long, Data}, fail(Parser)};
        [<<>>, Rest] ->
            <<_:2/binary, Rest/binary>> = Data,
            request(Rest, 0, Empty+2, Parser);
       [ReqLine, Rest] ->
            parse_request(ReqLine, Rest, Config, Parser)
    end.

parse_request(ReqLine, Rest, Config, Parser) ->
    case request_line(ReqLine, Config) of
        {ok, #hippo_request{version=Version} = Request} ->
            NParser = Parser#parser{buffer=Rest, version=Version,
                                    req=await_headers},
            {request, Request, NParser};
        {error, Reason} ->
            {error, {Reason, ReqLine}, fail(Parser)}
    end.

request_line(ReqLine, Config) ->
    case method(ReqLine) of
        {ok, Method, Next} ->
            request_line(Next, Method, Config);
        {error, _} = Error ->
            Error
    end.

request_line(RemLine, Method, Config) ->
    Len = byte_size(RemLine) - byte_size(<<" HTTP/1.0">>),
    case RemLine of
        <<RawURI:Len/binary, " HTTP/1.0">> ->
            request_line(RawURI, '1.0', Method, Config);
        <<RawURI:Len/binary, " HTTP/1.1">> ->
            request_line(RawURI, '1.1', Method, Config);
        <<_:Len/binary, " HTTP/", X, $., Y>>
          when X >= $0, X =< $9, Y >= $0, Y =< $9 ->
            {error, unsupported_version};
        _ ->
            {error, bad_request_line}
    end.

request_line(RawURI, Version, Method,
             #config{sockname=SockName, peername=PeerName} = Config) ->
    case uri(RawURI, Version, Method, Config) of
        {ok, Path, Query} when is_atom(Method), Method =/= connect ->
            Request = #hippo_request{version=Version, method=Method,
                                     path=Path, query=Query, uri=RawURI,
                                     sockname=SockName, peername=PeerName},
            {ok, Request};
        {ok, _, _} when element(1, Method) == unknown; Method == connect ->
            {error, unknown_method};
        {error, _} = Error ->
            Error
    end.

method(<<"GET ", Rest/binary>>) -> {ok, get, Rest};
method(<<"POST ", Rest/binary>>) -> {ok, post, Rest};
method(<<"PUT ", Rest/binary>>) -> {ok, put, Rest};
method(<<"HEAD ", Rest/binary>>) -> {ok, head, Rest};
method(<<"DELETE ", Rest/binary>>) -> {ok, delete, Rest};
method(<<"OPTIONS ", Rest/binary>>) -> {ok, options, Rest};
method(<<"TRACE ", Rest/binary>>) -> {ok, trace, Rest};
method(<<"COPY ", Rest/binary>>) -> {ok, copy, Rest};
method(<<"LOCK ", Rest/binary>>) -> {ok, lock, Rest};
method(<<"MKCOL ", Rest/binary>>) -> {ok, mkcol, Rest};
method(<<"MOVE ", Rest/binary>>) -> {ok, move, Rest};
method(<<"PURGE ", Rest/binary>>) -> {ok, purge, Rest};
method(<<"PROPFIND ", Rest/binary>>) -> {ok, propfind, Rest};
method(<<"PROPPATCH ", Rest/binary>>) -> {ok, proppatch, Rest};
method(<<"UNLOCK ", Rest/binary>>) -> {ok, unlock, Rest};
method(<<"REPORT ", Rest/binary>>) -> {ok, report, Rest};
method(<<"MKACTIVITY ", Rest/binary>>) -> {ok, mkactivity, Rest};
method(<<"CHECKOUT ", Rest/binary>>) -> {ok, checkout, Rest};
method(<<"MERGE ", Rest/binary>>) -> {ok, merge, Rest};
method(<<"M-SEARCH ", Rest/binary>>) -> {ok, m_search, Rest};
method(<<"SEARCH ", Rest/binary>>) -> {ok, search, Rest};
method(<<"NOTIFY ", Rest/binary>>) -> {ok, notify, Rest};
method(<<"SUBSCRIBE ", Rest/binary>>) -> {ok, subscribe, Rest};
method(<<"UNSUBSCRIBE ", Rest/binary>>) -> {ok, unsubscribe, Rest};
method(<<"PATCH ", Rest/binary>>) -> {ok, patch, Rest};
method(<<"CONNECT ", Rest/binary>>) -> {ok, connect, Rest};
method(<<Other/binary>>) ->
    case binary:split(Other, <<" ">>) of
        [_] ->
            {error, bad_request_line};
        [<<>>, _] ->
            {error, bad_request_line};
        [Method, Rest] ->
            {ok, {unknown, Method}, Rest}
    end.

uri(Long, _, _, #config{max_uri=MaxURI}) when byte_size(Long) > MaxURI ->
    {error, uri_too_long};
uri(<<>>, _, _, _) ->
    {error, bad_request_line};
uri(<<"*">>, _, _, _) ->
    {ok, '*', []};
uri(<<$/, Rest/binary>>, _, _, _) ->
    abs_path(Rest);
uri(<<H, T1, T2, P, "://", Rest/binary>>, _, _, _)
  when (H =:= $h orelse H =:= $H),
       (T1 =:= $t orelse T1 =:= $T),
       (T2 =:= $t orelse T2 =:= $T),
       (P =:= $p orelse P =:= $P) ->
    abs_uri(Rest);
uri(<<H, T1, T2, P, S, "://", Rest/binary>>, _, _, _)
  when (H =:= $h orelse H =:= $H),
       (T1 =:= $t orelse T1 =:= $T),
       (T2 =:= $t orelse T2 =:= $T),
       (P =:= $p orelse P =:= $P),
       (S =:= $s orelse S =:= $s) ->
    abs_uri(Rest);
uri(Other, '1.1', connect, _) ->
    authority(Other);
uri(_, _, _, _) ->
    {error, invalid_uri}.

abs_path(RawPath) ->
    abs_path(RawPath, <<>>, []).

abs_path(<<$/, Rest/binary>>, <<>>, Path) ->
    abs_path(Rest, <<>>, Path);
abs_path(<<$/, Rest/binary>>, Acc, Path) ->
    abs_path(Rest, <<>>, [Acc | Path]);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $0, A =< $9, B >= $0, B =< $9 ->
    abs_path(Rest, <<Acc/binary, (A-$0):4, (B-$0):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $0, A =< $9, B >= $A, B =< $F ->
    abs_path(Rest, <<Acc/binary, (A-$0):4, (B-$A+10):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $0, A =< $9, B >= $a, B =< $f ->
    abs_path(Rest, <<Acc/binary, (A-$0):4, (B-$a+10):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $A, A =< $F, B >= $0, B =< $9 ->
    abs_path(Rest, <<Acc/binary, (A-$A+10):4, (B-$0):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $F, A =< $F, B >= $A, B =< $Z ->
    abs_path(Rest, <<Acc/binary, (A-$A+10):4, (B-$A+10):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $A, A =< $F, B >= $a, B =< $f ->
    abs_path(Rest, <<Acc/binary, (A-$A+10):4, (B-$a+10):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $a, A =< $f, B >= $0, B =< $9 ->
    abs_path(Rest, <<Acc/binary, (A-$a+10):4, (B-$0):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $a, A =< $f, B >= $A, B =< $F ->
    abs_path(Rest, <<Acc/binary, (A-$a+10):4, (B-$A+10):4>>, Path);
abs_path(<<$%, A, B, Rest/binary>>, Acc, Path)
  when A >= $a, A =< $f, B >= $a, B =< $f ->
    abs_path(Rest, <<Acc/binary, (A-$a+10):4, (B-$a+10):4>>, Path);
abs_path(<<$+, Rest/binary>>, Acc, Path) ->
    abs_path(Rest, <<Acc/binary, $\s>>, Path);
abs_path(<<$?, RawQuery/binary>>, Acc, Path) ->
    query(RawQuery, abs_path(Acc, Path));
abs_path(<<$;, Rest/binary>>, Acc, Path) ->
    path_params(Rest, Acc, Path);
abs_path(<<$\s, _/binary>>, _, _) ->
    {error, bad_request_line};
abs_path(<<A, Rest/binary>>, Acc, Path) ->
    abs_path(Rest, <<Acc/binary, A>>, Path);
abs_path(<<>>, Acc, Path) ->
    {ok, abs_path(Acc, Path), []}.

abs_path(<<>>, Path) ->
    lists:reverse(Path);
abs_path(Acc, Path) ->
    lists:reverse(Path, [Acc]).

path_params(RawURI, <<>>, Path) ->
    path_params(RawURI, Path);
path_params(RawURI, Acc, Path) ->
    path_params(RawURI, [Acc | Path]).

path_params(<<>>, Path) ->
    lists:reverse(Path);
path_params(<<$/, Rest/binary>>, Path) ->
    abs_path(Rest, <<>>, Path);
path_params(<<$?, RawQuery/binary>>, Path) ->
    query(RawQuery, Path);
path_params(<<$\s, _/binary>>, _) ->
    {error, invalid_uri};
path_params(<<_, Rest/binary>>, Path) ->
    path_params(Rest, Path).

query(RawQuery, Path) ->
    case query(RawQuery, <<>>, key, []) of
        {ok, Query} ->
            {ok, Path, Query};
        {error, _} = Error ->
            Error
    end.

query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $0, A =< $9, B >= $0, B =< $9 ->
    query(Rest, <<Acc/binary, (A-$0):4, (B-$0):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $0, A =< $9, B >= $A, B =< $F ->
    query(Rest, <<Acc/binary, (A-$0):4, (B-$A+10):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $0, A =< $9, B >= $a, B =< $f ->
    query(Rest, <<Acc/binary, (A-$0):4, (B-$a+10):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $A, A =< $F, B >= $0, B =< $9 ->
    query(Rest, <<Acc/binary, (A-$A+10):4, (B-$0):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $F, A =< $F, B >= $A, B =< $Z ->
    query(Rest, <<Acc/binary, (A-$A+10):4, (B-$A+10):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $A, A =< $F, B >= $a, B =< $f ->
    query(Rest, <<Acc/binary, (A-$A+10):4, (B-$a+10):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $a, A =< $f, B >= $0, B =< $9 ->
    query(Rest, <<Acc/binary, (A-$a+10):4, (B-$0):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $a, A =< $f, B >= $A, B =< $F ->
    query(Rest, <<Acc/binary, (A-$a+10):4, (B-$A+10):4>>, State, Query);
query(<<$%, A, B, Rest/binary>>, Acc, State, Query)
  when A >= $a, A =< $f, B >= $a, B =< $f ->
    query(Rest, <<Acc/binary, (A-$a+10):4, (B-$a+10):4>>, State, Query);
query(<<$+, Rest/binary>>, Acc, State, Query) ->
    query(Rest, <<Acc/binary, $\s>>, State, Query);
query(<<$&, Rest/binary>>, <<>>, key, Query) ->
    query(Rest, <<>>, key, Query);
query(<<$&, Rest/binary>>, Value, Key, Query) ->
    query(Rest, <<>>, key, [{Key, Value} | Query]);
query(<<$=, Rest/binary>>, <<>>, key, Query) ->
    query(Rest, <<>>, key, Query);
query(<<$=, Rest/binary>>, Key, key, Query) ->
    query(Rest, <<>>, Key, Query);
query(<<$\s, _/binary>>, _, _, _) ->
    {error, bad_request_line};
query(<<A, Rest/binary>>, Acc, State, Query) ->
    query(Rest, <<Acc/binary, A>>, State, Query);
query(<<>>, <<>>, key, Query) ->
    {ok, lists:reverse(Query)};
query(<<>>, Key, key, Query) ->
    {ok, lists:reverse(Query, [Key])};
query(<<>>, Value, Key, Query) ->
    {ok, lists:reverse(Query, [{Key, Value}])}.

abs_uri(<<>>) ->
    {error, invalid_uri};
abs_uri(<<$/, Path/binary>>) ->
    abs_path(Path);
abs_uri(<<$?, RawQuery/binary>>) ->
    query(RawQuery, []);
abs_uri(<<$\s, _/binary>>) ->
    {error, bad_request_line};
abs_uri(<<_, Rest/binary>>) ->
    abs_uri(Rest).

authority(Auth) ->
    case binary:match(Auth, [<<"/">>, <<"?">>, <<$\s>>]) of
        nomatch ->
            authority_server(Auth);
        _ ->
            {error, invalid_uri}
    end.

authority_server(Auth) ->
    case binary:split(Auth, <<"@">>, [global]) of
        [_] ->
            authority_port(Auth);
        [_, Server] ->
            authority_port(Server);
        _ ->
            {error, invalid_uri}
    end.

authority_port(Server) ->
    case binary:split(Server, <<":">>) of
        [_] ->
            {error, authority_uri};
        [_, RawPort] when byte_size(RawPort) =< byte_size(<<"65535">>) ->
            parse_authority_port(RawPort);
        _ ->
            {error, invalid_uri}
    end.

parse_authority_port(RawPort) ->
    try binary_to_integer(RawPort) of
        Port when Port >= 1, Port =< 65535 ->
            {error, authority_uri};
        _ ->
            {error, invalid_uri}
    catch
        error:badarg ->
            {error, invalid_uri}
    end.

parse_headers(<<"\r\n", Rest/binary>>, 0, Parser) ->
    {headers, [], done(Rest, Parser)};
parse_headers(Data, Start, #parser{config=Config} = Parser) ->
    #config{crlf2=CRLF2, max_headers=MaxHeaders} = Config,
    Len = min(byte_size(Data), MaxHeaders) - Start,
    case binary:split(Data, CRLF2, [{scope, {Start, Len}}]) of
        [_] when byte_size(Data) > MaxHeaders ->
            {error, {headers_too_long, Data}, fail(Parser)};
        [_] ->
            {more, 0, Parser#parser{buffer=Data, req=headers}};
        [RawHeaders, Rest] ->
            parse_headers(RawHeaders, Parser#parser{buffer=Rest})
    end.

parse_headers(RawHeaders, Parser) ->
    case headers(RawHeaders, [], #body{}, Parser) of
        {ok, Headers, Body, NParser} ->
            handle_headers(Headers, Body, NParser);
        {error, Reason} ->
            {error, Reason, fail(Parser)}
    end.

handle_headers(_, #body{transfer_encoding=chunked, content_length=Len}, Parser)
  when Len =/= undefined ->
    NParser = fail(Parser),
    {error, {chunked_with_content_length, integer_to_binary(Len)}, NParser};
handle_headers(Headers, #body{transfer_encoding=chunked, expect=Expect},
               Parser) ->
    case Expect of
        continue ->
            {headers, Headers, Parser#parser{req={continue, chunked}}};
        _ ->
            {headers, Headers, Parser#parser{req=await_chunk_line}}
    end;
handle_headers(Headers, #body{content_length=Len, expect=Expect}, Parser)
  when is_integer(Len), Len > 0 ->
    case Expect of
        continue ->
            {headers, Headers, Parser#parser{req={continue, Len}}};
        _ ->
            {headers, Headers, Parser#parser{req={body, Len}}}
    end;
handle_headers(Headers, #body{content_length=Len},
               #parser{buffer=Buffer} = Parser)
  when Len =:= 0; Len == undefined ->
    {headers, Headers, done(Buffer, Parser)}.

headers(<<"Accept: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"accept">>, Headers, Body, Parser);
headers(<<"Accept-Charset: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"accept-charset">>, Headers, Body, Parser);
headers(<<"Accept-Encoding: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"accept-encoding">>, Headers, Body, Parser);
headers(<<"Accept-Datetime: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"accept-datetime">>, Headers, Body, Parser);
headers(<<"Accept-Language: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"accept-language">>, Headers, Body, Parser);
headers(<<"Accept-", Rest/binary>>, Headers, Body, Parser) ->
    header_key(Rest, <<"accept-">>, Headers, Body, Parser);
headers(<<"Authorization: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"authorization">>, Headers, Body, Parser);
headers(<<"Cache-Control: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"cache-control">>, Headers, Body, Parser);
headers(<<"Connection: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"connection">>, Headers, Body, Parser);
headers(<<"Cookie: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"cookie">>, Headers, Body, Parser);
headers(<<"Content-Length: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"content-length">>, Headers, Body, Parser);
headers(<<"Content-MD5: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"content-md5">>, Headers, Body, Parser);
headers(<<"Content-Type: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"content-type">>, Headers, Body, Parser);
headers(<<"Content-", Rest/binary>>, Headers, Body, Parser) ->
    header_key(Rest, <<"content-">>, Headers, Body, Parser);
headers(<<"Date: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"date">>, Headers, Body, Parser);
headers(<<"Expect: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"expect">>, Headers, Body, Parser);
headers(<<"Forwarded: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"forwarded">>, Headers, Body, Parser);
headers(<<"From: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"from">>, Headers, Body, Parser);
headers(<<"Host: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"host">>, Headers, Body, Parser);
headers(<<"If-Match: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"if-match">>, Headers, Body, Parser);
headers(<<"If-Modified-Since: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"if-modified-since">>, Headers, Body, Parser);
headers(<<"If-None-Match: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"if-none-match">>, Headers, Body, Parser);
headers(<<"If-Range: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"if-range">>, Headers, Body, Parser);
headers(<<"If-Unmodified-Since: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"if-unmodified-since">>, Headers, Body, Parser);
headers(<<"Max-Forwards: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"max-forwards">>, Headers, Body, Parser);
headers(<<"Origin: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"origin">>, Headers, Body, Parser);
headers(<<"Pragma: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"pragma">>, Headers, Body, Parser);
headers(<<"Proxy-Authorization: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"proxy-authorization">>, Headers, Body, Parser);
headers(<<"Range: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"range">>, Headers, Body, Parser);
headers(<<"Referer: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"referer">>, Headers, Body, Parser);
headers(<<"TE: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"te">>, Headers, Body, Parser);
headers(<<"User-Agent: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"user-Agent">>, Headers, Body, Parser);
headers(<<"Upgrade: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"upgrade">>, Headers, Body, Parser);
headers(<<"Via: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"via">>, Headers, Body, Parser);
headers(<<"Warning: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"warning">>, Headers, Body, Parser);
headers(<<"X-Requested-With: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-requested-with">>, Headers, Body, Parser);
headers(<<"DNT: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"dnt">>, Headers, Body, Parser);
headers(<<"X-Forwarded-For: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-forwarded-for">>, Headers, Body, Parser);
headers(<<"X-Forwarded-Host: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-forwarded-host">>, Headers, Body, Parser);
headers(<<"X-Forwarded-Proto: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-forwarded-proto">>, Headers, Body, Parser);
headers(<<"Front-End-Https: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"front-end-https">>, Headers, Body, Parser);
headers(<<"X-Http-Method-Override: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-http-method-override">>, Headers, Body, Parser);
headers(<<"X-Wap-Profile: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-wap-profile">>, Headers, Body, Parser);
headers(<<"Proxy-Connection: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"proxy-connection">>, Headers, Body, Parser);
headers(<<"X-CSRF-Token: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-csrf-token">>, Headers, Body, Parser);
headers(<<"X-CSRFToken: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-csrftoken">>, Headers, Body, Parser);
headers(<<"X-XSRF-TOKEN: ", Rest/binary>>, Headers, Body, Parser) ->
    header_value(Rest, <<"x-xsrf-token">>, Headers, Body, Parser);
headers(<<"Upgrade-Insecure-Requests: ", Rest/binary>>, Headers, Body,
        Parser) ->
    header_value(Rest, <<"upgrade-insecure-requests">>, Headers, Body, Parser);
headers(<<>>, Headers, Body, Parser) ->
    {ok, lists:reverse(Headers), Body, Parser};
headers(<<RawHeaders/binary>>, Headers, Body, Parser) ->
    header_key(RawHeaders, <<>>, Headers, Body, Parser).

header_key(<<Char, Rest/binary>>, Acc, Headers, Body, Parser)
  when Char >= $A, Char =< $Z ->
    header_key(Rest, <<Acc/binary, (Char-$A+$a)>>, Headers, Body, Parser);
header_key(<<$:, $\s, Rest/binary>>, Key, Headers, Body, Parser)
  when Key =/= <<>> ->
    header_value(Rest, Key, Headers, Body, Parser);
header_key(<<$:, $\t, Rest/binary>>, Key, Headers, Body, Parser)
  when Key =/= <<>> ->
    header_value(Rest, Key, Headers, Body, Parser);
header_key(<<$:, Rest/binary>>, Key, _, _, _) ->
    [RemLine | _] = binary:split(Rest, <<"\r\n">>),
    {error, {invalid_header_line, <<Key/binary, $:, RemLine/binary>>}};
header_key(<<"\r\n", _>>, Key, _, _, _) ->
    {error, {invalid_header_line, Key}};
header_key(<<Char, Rest/binary>>, Key, Headers, Body, Parser) ->
    header_key(Rest, <<Key/binary, Char>>, Headers, Body, Parser);
header_key(<<>>, Key, _, _, _) ->
    {error, {invalid_header_line, Key}}.

header_value(RawHeaders, Key, Headers, Body, Parser) ->
    header_lows(RawHeaders, <<>>, Key, Headers, Body, Parser).

header_lows(<<$\s, Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    header_lows(Rest, Value, Key, Headers, Body, Parser);
header_lows(<<$\t, Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    header_lows(Rest, Value, Key, Headers, Body, Parser);
header_lows(<<Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    header_value(Rest, Value, Key, Headers, Body, Parser).

header_value(<<"\r\n\s", Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    header_value(Rest, <<Value/binary, $\s>>, Key, Headers, Body, Parser);
header_value(<<"\r\n\t", Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    header_value(Rest, <<Value/binary, $\s>>, Key, Headers, Body, Parser);
header_value(<<"\r\n", Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    parse_header(Key, header_rows(Value), Rest, Headers, Body, Parser);
header_value(<<Char, Rest/binary>>, Value, Key, Headers, Body, Parser) ->
    header_value(Rest, <<Value/binary, Char>>, Key, Headers, Body, Parser);
header_value(<<>>, Value, Key, Headers, Body, Parser) ->
    parse_header(Key, header_rows(Value), <<>>, Headers, Body, Parser).

header_rows(Value) ->
    header_rows(Value, byte_size(Value)).

header_rows(Value, Len) ->
    Pos = Len - 1,
    case Value of
        <<_:Pos/binary, $\s, _/binary>> ->
            header_rows(Value, Pos);
        <<_:Pos/binary, $\t, _/binary>> ->
            header_rows(Value, Pos);
        <<NValue:Len/binary, _/binary>> ->
            NValue
    end.

parse_header(<<"connection">> = Key, Value, Rest, Headers, Body,
             #parser{connection={force_close, Connection},
                     version=Version} = Parser) ->
    NHeaders = [{Key, Value} | Headers],
    case connection(Value, Version) of
        Connection ->
            headers(Rest, NHeaders, Body, Parser);
        _ when Connection =/= undefined ->
            {error, {duplicate_header, Key}};
        NConnection ->
            NParser = Parser#parser{connection={force_close, NConnection}},
            headers(Rest, NHeaders, Body, NParser)
    end;
parse_header(<<"connection">> = Key, Value, Rest, Headers, Body,
             #parser{connection=Connection, version=Version} = Parser) ->
    NHeaders = [{Key, Value} | Headers],
    case connection(Value, Version) of
        Connection ->
            headers(Rest, NHeaders, Body, Parser);
        _ when Connection =/= undefined ->
            {error, {duplicate_header, Key}};
        NConnection ->
            headers(Rest, NHeaders, Body, Parser#parser{connection=NConnection})
    end;
parse_header(<<"content-length">> = Key, Value, Rest, Headers,
             #body{content_length=Len} = Body,
             #parser{config=#config{max_body=MaxBody}} = Parser) ->
    NHeaders = [{Key, Value} | Headers],
    case content_length(Value) of
        NLen when is_integer(NLen), NLen > MaxBody, Len == undefined ->
            {error, {body_too_long, Value}};
        NLen when is_integer(NLen), NLen > 0, Len == undefined ->
            headers(Rest, NHeaders, Body#body{content_length=NLen}, Parser);
        Len ->
            headers(Rest, NHeaders, Body, Parser);
        _ when is_integer(Len) ->
            {error, {duplicate_header, Key}};
        {invalid, Value} ->
            {error, {invalid_content_length, Value}}
    end;
parse_header(<<"expect">> = Key, Value, Rest, Headers,
             #body{expect=Expect} = Body, #parser{version='1.1'} = Parser) ->
    case expect(Value) of
        continue ->
            NHeaders = [{Key, Value} | Headers],
            headers(Rest, NHeaders, Body#body{expect=continue}, Parser);
        _ when Expect == continue ->
            {error, {duplicate_header, Key}};
        {unknown, Value} ->
            {error, {unknown_expectation, Value}}
    end;
parse_header(<<"transfer-encoding">> = Key, Value, Rest, Headers,
             #body{transfer_encoding=Transfer} = Body,
             #parser{version=Version} = Parser) ->
    case transfer_encoding(Value, Version) of
        chunked when Transfer == undefined ->
            NHeaders = [{Key, Value} | Headers],
            NBody = Body#body{transfer_encoding=chunked},
            headers(Rest, NHeaders, NBody, Parser);
        chunked when Transfer == chunked ->
            {error, {unsupported_encoding, <<"chunked, chunked">>}};
        {unsupported, Encoding} when Transfer == chunked ->
            {error, {unsupported_encoding, <<"chunked, ", Encoding/binary>>}};
        {unsupported, Encoding} ->
            {error, {unsupported_encoding, Encoding}}
    end;
parse_header(Key, Value, Rest, Headers, Body, Parser) ->
    headers(Rest, [{Key, Value} | Headers], Body, Parser).

connection(<<C, L, O, S, E>>, _)
  when (C =:= $c orelse C =:= $C),
       (L =:= $l orelse L =:= $L),
       (O =:= $o orelse O =:= $O),
       (S =:= $s orelse S =:= $S),
       (E =:= $e orelse E =:= $E) ->
    close;
connection(<<K, E1, E2, P, Dash, A, L, I, V, E3>>, _)
  when (K =:= $k orelse K =:= $K),
       (E1 =:= $e orelse E1 =:= $E),
       (E2 =:= $e orelse E2 =:= $E),
       (P =:= $p orelse P =:= $P),
       Dash =:= $-,
       (A =:= $a orelse A =:= $A),
       (L =:= $l orelse L =:= $L),
       (I =:= $i orelse I =:= $I),
       (V =:= $v orelse V =:= $V),
       (E3 =:= $e orelse E3 =:= $E) ->
    keep_alive;
connection(<<U, P, G, R, A, D, E>>, '1.1')
  when (U =:= $u orelse U =:= $U),
       (P =:= $p orelse P =:= $P),
       (G =:= $g orelse G =:= $G),
       (R =:= $r orelse R =:= $R),
       (A =:= $a orelse A =:= $A),
       (D =:= $d orelse D =:= $D),
       (E =:= $e orelse E =:= $E) ->
    upgrade;
connection(_, _) ->
    unknown.

content_length(Value) when byte_size(Value) =< ?MAX_LENGTH_SIZE ->
    try binary_to_integer(Value) of
        Int when Int >= 0 ->
            Int;
        _ ->
            {invalid, Value}
    catch
        error:badarg ->
            {invalid, Value}
    end;
content_length(Value) ->
    {invalid, Value}.

transfer_encoding(<<C, H, U, N, K, E, D>>, '1.1')
  when (C =:= $c orelse C =:= $C),
       (H =:= $h orelse H =:= $H),
       (U =:= $u orelse U =:= $U),
       (N =:= $n orelse N =:= $N),
       (K =:= $k orelse K =:= $K),
       (E =:= $e orelse E =:= $E),
       (D =:= $d orelse D =:= $D) ->
    chunked;
transfer_encoding(Encoding, _) ->
    {unsupported, Encoding}.

expect(<<"100-", C, O, N1, T, I, N2, U, E>>)
  when (C =:= $c orelse C =:= $C),
       (O =:= $o orelse O =:= $O),
       (N1 =:= $n orelse N1 =:= $N),
       (T =:= $t orelse T =:= $T),
       (I =:= $i orelse I =:= $I),
       (N2 =:= $n orelse N2 =:= $N),
       (U =:= $u orelse U =:= $U),
       (E =:= $e orelse E =:= $E) ->
    continue;
expect(Value) ->
    {unknown, Value}.

parse_chunk_line(Data, Start, #parser{config=Config} = Parser) ->
    #config{crlf_semi=CRLFSemi, max_chunk_line=MaxChunkLine} = Config,
    MatchLen = min(byte_size(Data), MaxChunkLine) - Start,
    case binary:match(Data, CRLFSemi, [{scope, {Start, MatchLen}}]) of
        nomatch when byte_size(Data) > MaxChunkLine ->
            {error, {chunk_line_too_long, Data}, fail(Parser)};
        nomatch ->
            {more, 0, Parser#parser{buffer=Data, req=chunk_line}};
        {0, _} ->
            {error, {invalid_chunk_line, Data}, fail(Parser)};
        {SizeLen, 1} ->
            chunk_param(Data, SizeLen, SizeLen+1, Parser);
        {SizeLen, 2} ->
            parse_chunk_line(Data, SizeLen, 2, Parser)
    end.

chunk_param(Data, SizeLen, Start, #parser{config=Config} = Parser) ->
    #config{crlf=CRLF, max_chunk_line=MaxChunkLine} = Config,
    MatchLen = min(byte_size(Data), MaxChunkLine) - Start,
    case binary:match(Data, CRLF, [{scope, {Start, MatchLen}}]) of
        nomatch when byte_size(Data) > MaxChunkLine ->
            {error, {chunk_line_too_long, Data}, fail(Parser)};
        nomatch ->
            {more, 0, Parser#parser{buffer=Data, req={chunk_param, SizeLen}}};
        {SkipLen, 2} ->
            parse_chunk_line(Data, SizeLen, SkipLen+2-SizeLen, Parser)
    end.

parse_chunk_line(Data, SizeLen, SkipLen, #parser{config=Config} = Parser)
  when SizeLen =< ?MAX_LENGTH_SIZE->
    #config{max_chunk=MaxChunk} = Config,
    <<RawSize:SizeLen/binary, _/binary>> = Data,
    try binary_to_integer(RawSize) of
        Len when Len > MaxChunk ->
            {error, {chunk_too_long, RawSize}, fail(Parser)};
        Len when Len > 0 ->
            NSkipLen = SizeLen + SkipLen,
            <<_:NSkipLen/binary, Rest/binary>> = Data,
            chunk_body(Rest, Len, Parser);
        0 ->
            NSkipLen = SizeLen + SkipLen - 2,
            <<_:NSkipLen/binary, Rest/binary>> = Data,
            parse_trailers(Rest, 0, Parser);
        _ ->
            {error, {invalid_chunk_size, RawSize}, fail(Parser)}
    catch
        error:badarg ->
            {error, {invalid_chunk_size, RawSize}, fail(Parser)}
    end;
parse_chunk_line(Data, SizeLen, _, Parser) ->
    <<RawSize:SizeLen/binary, _/binary>> = Data,
    {error, {invalid_chunk_size, RawSize}, fail(Parser)}.

chunk_body(Data, Len, Parser)
  when is_integer(Len), byte_size(Data) < Len ->
    {chunk, Data,
     Parser#parser{buffer= <<>>, req={chunk_body, Len-byte_size(Data)}}};
chunk_body(Data, Len, Parser) when is_integer(Len) ->
    case Data of
        <<Body:Len/binary, $\r, $\n>> ->
            {chunk, Body,
             Parser#parser{buffer= <<>>, req=await_chunk_line}};
        <<Body:Len/binary, $\r, $\n, Rest/binary>> ->
            {chunk, Body,
             Parser#parser{buffer=Rest, req=await_chunk_line}};
        <<Body:Len/binary, $\r>> ->
            {chunk, Body,
             Parser#parser{buffer= <<>>, req={chunk_body, '\n'}}};
        <<Body:Len/binary>> ->
            {chunk, Body,
             Parser#parser{buffer= <<>>, req={chunk_body, '\r\n'}}}
    end;
chunk_body(<<"\r\n">>, '\r\n', Parser) ->
    {more, 0, Parser#parser{buffer= <<>>, req=await_chunk_line}};
chunk_body(<<"\r\n", Rest/binary>>, '\r\n', Parser) ->
    parse_chunk_line(Rest, 0, Parser);
chunk_body(<<"\r">>, '\r\n', Parser) ->
    {more, 0, Parser#parser{buffer= <<>>, req={chunk_body, '\n'}}};
chunk_body(<<"\n">>, '\n', Parser) ->
    {more, 0, Parser#parser{buffer= <<>>, req=await_chunk_line}};
chunk_body(<<"\n", Rest/binary>>, '\n', Parser) ->
    parse_chunk_line(Rest, 0, Parser);
chunk_body(<<>>, NewLine, Parser) when NewLine == '\r\n'; NewLine == '\n' ->
    {more, 0, Parser#parser{buffer= <<>>, req={chunk_body, NewLine}}}.

parse_trailers(Data, Start, #parser{config=Config} = Parser) ->
    #config{crlf2=CRLF2, max_trailers=MaxTrailers} = Config,
    Len = min(byte_size(Data), MaxTrailers) - Start,
    case binary:split(Data, CRLF2, [{scope, {Start, Len}}]) of
        [_] when byte_size(Data) > MaxTrailers ->
            {error, {trailers_too_long, Data}, fail(Parser)};
        [_] ->
            {more, 0, Parser#parser{buffer=Data, req=trailers}};
        [RawTrailers, Rest] ->
            parse_trailers(RawTrailers, done(Rest, Parser))
    end.

parse_trailers(RawTrailers, #parser{config=Config} = Parser) ->
    #config{trailers=IncTrailers} = Config,
    case headers(RawTrailers, [], done, Parser) of
        {ok, [_|_] = Trailers, done, NParser} when IncTrailers == include ->
            {trailers, Trailers, NParser};
        {ok, _, done, NParser} ->
            {done, NParser};
        {error, {invalid_header_line, Line}} ->
            {error, {invalid_trailer_line, Line}, fail(Parser)};
        {error, {duplicate_header, Key}} ->
            {error, {duplicate_trailer, Key}, fail(Parser)};
        {error, Reason} ->
            {error, Reason, fail(Parser)}
    end.

done(<<>>, #parser{resp=await_response} = Parser) ->
    Parser#parser{req=done, buffer= <<>>};
done(Buffer, #parser{resp=await_response} = Parser) ->
    Parser#parser{req=done, buffer=Buffer};
done(<<>>, #parser{} = Parser) ->
    Parser#parser{req=done, buffer=done}.

fail(Parser) ->
    Parser#parser{req=failed, buffer=done}.

resp_content_length(Body) ->
    case iolist_size(Body) of
        0 ->
            [];
        Len ->
            [<<"Content-Length: ">>, integer_to_binary(Len), $\r, $\n]
    end.

next(#parser{req=Req, connection=shutdown} = Parser) when Req =/= done ->
    {shutdown, Parser#parser{connection={force_close, shutdown}}};
next(#parser{req=Req, connection=Conn} = Parser)
  when Req =/= done, is_atom(Conn) ->
    {close, Parser#parser{connection={force_close, Conn}}};
next(#parser{connection=close} = Parser) ->
    {close, Parser#parser{buffer=done}};
next(#parser{connection=shutdown} = Parser) ->
    {shutdown, Parser#parser{buffer=done}};
next(#parser{version='1.1', config=Config, buffer=Buffer} = Parser) ->
    NextParser = #parser{config=Config, buffer=maybe_copy(Buffer)},
    {{keep_alive, NextParser}, Parser#parser{buffer=done}};
next(#parser{version='1.0', config=Config, connection=Conn,
             buffer=Buffer} = Parser) ->
    case Config of
        #config{http_1_0_connection=keep_alive} when Conn == keep_alive ->
            NextParser = #parser{config=Config, buffer=maybe_copy(Buffer)},
            {{keep_alive, NextParser}, Parser#parser{buffer=done}};
        _ ->
            {close, Parser#parser{buffer=done}}
    end.

maybe_copy(Buffer) ->
    case binary:referenced_byte_size(Buffer) of
        Size when byte_size(Buffer) < Size ->
            binary:copy(Buffer);
        _ ->
            Buffer
    end.

resp_connection({keep_alive, _}) ->
    <<"Connection: keep-alive\r\n">>;
resp_connection(Close) when Close == close; Close == shutdown ->
    <<"Connection: close\r\n">>.

response(Status, Headers) ->
    [<<"HTTP/1.1 ">>, status(Status), $\r, $\n | resp_headers(Headers)].

resp_headers(Headers) ->
    resp_headers(Headers, []).

resp_headers([{Key, Value} | Headers], Acc) ->
    NKey = camel_header(Key),
    resp_headers(Headers, [Acc, NKey, $:, $\s, Value, $\r, $\n]);
resp_headers([], Acc) ->
    Acc.

camel_header(<<"access-control-allow-origin">>) ->
    <<"Access-Control-Allow-Origin">>;
camel_header(<<"accept-patch">>) ->
    <<"Accept-Patch">>;
camel_header(<<"accept-ranges">>) ->
    <<"Accept-Ranges">>;
camel_header(<<"accept", Rest/binary>>) ->
    camel_header(Rest, <<"Accept">>);
camel_header(<<"age">>) ->
    <<"Age">>;
camel_header(<<"allow">>) ->
    <<"Allow">>;
camel_header(<<"cache-control">>) ->
    <<"Cache-Control">>;
camel_header(<<"connection">>) ->
    <<"Connection">>;
camel_header(<<"content-disposition">>) ->
    <<"Content-Disposition">>;
camel_header(<<"content-encoding">>) ->
    <<"Content-Encoding">>;
camel_header(<<"content-language">>) ->
    <<"Content-Language">>;
camel_header(<<"content-length">>) ->
    <<"Content-Length">>;
camel_header(<<"content-location">>) ->
    <<"Content-Location">>;
camel_header(<<"content-md5">>) ->
    <<"Content-MD5">>;
camel_header(<<"content-range">>) ->
    <<"Content-Range">>;
camel_header(<<"content-type">>) ->
    <<"Content-Type">>;
camel_header(<<"content-security-policy">>) ->
    <<"Content-Security-Policy">>;
camel_header(<<"content", Rest/binary>>) ->
    camel_header(Rest, <<"Content">>);
camel_header(<<"date">>) ->
    <<"Date">>;
camel_header(<<"etag">>) ->
    <<"ETag">>;
camel_header(<<"expired">>) ->
    <<"Expired">>;
camel_header(<<"last-modified">>) ->
    <<"Last-Modified">>;
camel_header(<<"link">>) ->
    <<"Link">>;
camel_header(<<"location">>) ->
    <<"Location">>;
camel_header(<<"p3p">>) ->
    <<"P3P">>;
camel_header(<<"pragma">>) ->
    <<"Pragma">>;
camel_header(<<"proxy-authenticate">>) ->
    <<"Proxy-Authenticate">>;
camel_header(<<"public-key-pins">>) ->
    <<"Public-Key-Pins">>;
camel_header(<<"refresh">>) ->
    <<"Refresh">>;
camel_header(<<"retry-after">>) ->
    <<"Retry-After">>;
camel_header(<<"server">>) ->
    <<"Server">>;
camel_header(<<"set-cookie">>) ->
    <<"Set-Cookie">>;
camel_header(<<"status">>) ->
    <<"Status">>;
camel_header(<<"strict-transport-security">>) ->
    <<"Strict-Transport-Security">>;
camel_header(<<"trailer">>) ->
    <<"Trailer">>;
camel_header(<<"transfer-encoding">>) ->
    <<"Transfer-Encoding">>;
camel_header(<<"tsv">>) ->
    <<"TSV">>;
camel_header(<<"upgrade">>) ->
    <<"Upgrade">>;
camel_header(<<"vary">>) ->
    <<"Vary">>;
camel_header(<<"warning">>) ->
    <<"Warning">>;
camel_header(<<"www-authenticate">>) ->
    <<"WWW-Authenticate">>;
camel_header(<<"x-frame-options">>) ->
    <<"X-Frame-Options">>;
camel_header(<<"x-xss-protection">>) ->
    <<"X-XSS-Protection">>;
camel_header(<<"x-content-type-options">>) ->
    <<"X-Content-Type-Options">>;
camel_header(<<"x-powered-by">>) ->
    <<"X-Powered-By">>;
camel_header(<<"x-ua-compatible">>) ->
    <<"X-UA-Compatible">>;
camel_header(<<"x-content-duration">>) ->
    <<"X-Content-Duration">>;
camel_header(<<Char, Rest/binary>>) when Char >= $a, Char =< $z ->
    camel_header(Rest, <<(Char+$A-$a)>>);
camel_header(Key) ->
    camel_header(Key, <<>>).

camel_header(<<$-, Char, Rest/binary>>, Acc)
  when Char >= $a, Char =< $z ->
    camel_header(Rest, <<Acc/binary, (Char+$A-$a)>>);
camel_header(<<Char, Rest/binary>>, Acc) ->
    camel_header(Rest, <<Acc/binary, Char>>);
camel_header(<<>>, Acc) ->
    Acc.

status(100) ->
    <<"100 Continue">>;
status(101) ->
    <<"101 Switching Protocols">>;
status(102) ->
    <<"102 Processing">>;
status(200) ->
    <<"200 OK">>;
status(201) ->
    <<"201 Created">>;
status(202) ->
    <<"202 Accepted">>;
status(203) ->
    <<"203 Non-Authoritative Information">>;
status(204) ->
    <<"204 No Content">>;
status(205) ->
    <<"205 Reset Content">>;
status(206) ->
    <<"206 Partial Content">>;
status(207) ->
    <<"207 Multi-Status">>;
status(208) ->
    <<"208 Already Reported">>;
status(226) ->
    <<"226 IM Used">>;
status(300) ->
    <<"300 Multiple Choices">>;
status(301) ->
    <<"301 Moved Permanently">>;
status(302) ->
    <<"302 Found">>;
status(303) ->
    <<"303 See Other">>;
status(304) ->
    <<"304 Not Modified">>;
status(305) ->
    <<"305 Use Proxy">>;
status(306) ->
    <<"306 Switch Proxy">>;
status(307) ->
    <<"307 Temporary Redirect">>;
status(308) ->
    <<"308 Permanent Redirect">>;
status(400) ->
    <<"400 Bad Request">>;
status(401) ->
    <<"401 Unauthorized">>;
status(402) ->
    <<"402 Payment Required">>;
status(403) ->
    <<"403 Forbidden">>;
status(404) ->
    <<"404 Not Found">>;
status(405) ->
    <<"405 Method Not Allowed">>;
status(406) ->
    <<"406 Not Acceptable">>;
status(407) ->
    <<"407 Proxy Authentication Required">>;
status(408) ->
    <<"408 Request Timeout">>;
status(409) ->
    <<"409 Conflict">>;
status(410) ->
    <<"410 Gone">>;
status(411) ->
    <<"411 Length Required">>;
status(412) ->
    <<"412 Precondition Failed">>;
status(413) ->
    <<"413 Payload Too Large">>;
status(414) ->
    <<"414 URI Too Long">>;
status(415) ->
    <<"415 Unsupported Media Type">>;
status(416) ->
    <<"416 Range Not Satisfiable">>;
status(417) ->
    <<"417 Expectation Failed">>;
status(418) ->
    <<"418 I'm a teapot">>;
status(421) ->
    <<"421 Misdirected Request">>;
status(422) ->
    <<"422 Unprocessable Entity">>;
status(423) ->
    <<"423 Locked">>;
status(424) ->
    <<"424 Failed Dependency">>;
status(426) ->
    <<"426 Upgrade Required">>;
status(428) ->
    <<"428 Precondition Required">>;
status(429) ->
    <<"429 Too Many Requests">>;
status(431) ->
    <<"431 Request Header Fields Too Large">>;
status(451) ->
    <<"451 Unavailable For Legal Reasons">>;
status(500) ->
    <<"500 Internal Server Error">>;
status(501) ->
    <<"501 Not Implemented">>;
status(502) ->
    <<"502 Bad Gateway">>;
status(503) ->
    <<"503 Service Unavailable">>;
status(504) ->
    <<"504 Gateway Timeout">>;
status(505) ->
    <<"505 HTTP Version Not Supported">>;
status(506) ->
    <<"506 Variant Also Negotiates">>;
status(507) ->
    <<"507 Insufficient Storage">>;
status(508) ->
    <<"508 Loop Dectected">>;
status(510) ->
    <<"510 Not Extended">>;
status(511) ->
    <<"511 Network Authentication Required">>.
