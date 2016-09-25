-module(hippo_http).

-export([new/2]).
-export([parse/1]).
-export([parse/2]).
-export([response/4]).
-export([error_response/2]).
-export([chunk/2]).
-export([last_chunk/2]).
-export([status_error/1]).

-include("hippo.hrl").

-dialyzer({no_improper_lists, [parse/2, last_chunk/2]}).

-define(MAX_LENGTH_SIZE, 64).

-type req() :: {request, non_neg_integer()} | await_headers | headers |
               {continue, pos_integer() | chunked} | {body, pos_integer()} |
               await_chunk_line | chunk_line | {chunk_param, pos_integer()} |
               {chunk_body, pos_integer() | '\r\n' | '\n'} | trailers | failed |
               done.

-type resp() :: await_response | chunk | stream | failed | done.

-type method() :: get | post | put | head | delete | options | trace | copy |
                  lock | mkcol | move | purge | propfind | proppatch | unlock |
                  report | mkactivity | checkout | merge | m_search | search |
                  notify | subscribe | unsubscribe | patch.

-type version() :: '0.9' | '1.0' | '1.1'.

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
                 sockname :: acceptor_pool:name(),
                 peername :: acceptor_pool:name(),
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
                                                           keep_alive),
                 date = application:get_env(hippo, date, dirty)}).

-record(parser, {config = #config{} :: #config{},
                 buffer :: binary() | done,
                 req = {request, 0} :: req(),
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
parse(#parser{buffer=Buffer, req={request, 0}} = Parser) ->
    request(Buffer, 0, Parser);
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
parse(Data, #parser{buffer=Buffer, req={request, Empty}} = Parser) ->
    request(merge(Data, Buffer), Empty, Parser);
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
            <<Body:Len/binary, Rest/binary>> = iolist_to_binary(Data),
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
    Data = [response(Status, Headers, NParser),
            <<"Transfer-Encoding: chunked\r\n">>,
            resp_connection(Next),
            $\r, $\n],
    {response, Data, Next, NParser#parser{resp=chunk}};
response(Status, Headers, chunk,
         #parser{resp=await_response, version='1.0'} = Parser) ->
    {Next, NParser} = next(Parser#parser{resp=stream, connection=shutdown}),
    Data = [response(Status, Headers, NParser),
            resp_connection(Next),
            $\r, $\n],
    {response, Data, Next, NParser};
response(Status, Headers, Body, #parser{resp=await_response} = Parser) ->
    {Next, NParser} = next(Parser),
    Data = [response(Status, Headers, NParser),
            resp_content_length(Body),
            resp_connection(Next),
            $\r, $\n |
            Body],
    {response, Data, Next, NParser#parser{resp=done}};
response(_, _, _, #parser{resp=stream} = Parser) ->
    {error, chunk, Parser};
response(_, _, _, #parser{resp=Resp} = Parser) ->
    {error, Resp, Parser}.

-spec error_response(Status, Parser) -> iodata() when
      Status :: status(),
      Parser :: parser().
error_response(Status, Parser) ->
    Headers = [{<<"Connection">>, <<"close">>},
               {<<"Content-Length">>, <<"0">>}],
    [response(Status, Headers, Parser), $\r, $\n].

-spec chunk(iodata(), Parser) ->  Chunk | Error when
      Parser :: parser(),
      NParser :: parser(),
      Chunk :: {chunk, iodata(), NParser},
      Error :: {error, error(), NParser}.
chunk(Data, #parser{resp=chunk} = Parser) ->
    case iolist_size(Data) of
        0 ->
            {chunk, <<>>, Parser};
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

request(Data, Empty, #parser{config=Config} = Parser) ->
    #config{max_request_line=MaxReqLine, max_empty_line=MaxEmpty} = Config,
    case erlang:decode_packet(http_bin, Data, [{line_length, MaxReqLine}]) of
        {more, _} ->
            {more, 0, Parser#parser{buffer=Data, req={request, Empty}}};
        {ok, {http_request, _, _, {Major, Minor} = Vsn}, _}
          when Vsn =/= {1, 1}, Vsn =/= {1, 0} ->
            Vsn2 = <<"HTTP/", (Major+$0), $., (Minor+$0)>>,
            req_error(unsupported_version, Vsn2, Parser);
        {ok, {http_request, Method, {abs_path, Path}, Vsn}, Rest} ->
            parse_request(Method, Path, Path, Vsn, Rest, Parser);
        {ok, {http_request, Method, {absoluteURI, _, _, _, Path} = Abs, Vsn},
         Rest} ->
            parse_request(Method, Path, abs_uri(Abs), Vsn, Rest, Parser);
        {ok, {http_request, 'OPTIONS', '*', {1, _} = Vsn}, Rest} ->
            Request = #hippo_request{method=options, path='*', query=[],
                                     uri= <<"*">>, version=version(Vsn)},
            {request, Request, Parser#parser{req=await_headers, buffer=Rest}};
        {ok, {http_request, _, '*', _}, _} ->
            req_error(invalid_uri, <<$*>>, Parser);
        {ok, {http_request, <<"CONNECT">>, {scheme, _, _}, {1,1}}, Rest} ->
            ReqLen = byte_size(Data) - byte_size(Rest),
            <<ReqLine:ReqLen/binary, _>> = Data,
            req_error(not_implemented, ReqLine, Parser);
        {ok, {http_request, _, {scheme, Host, Port}, _}, _} ->
            req_error(invalid_uri, <<Host/binary, $:, Port/binary>>, Parser);
        {ok, {http_error, <<"\r\n">>}, Rest} when Empty < MaxEmpty ->
            request(Rest, Empty+2, Parser);
        {ok, {http_error, <<"\r\n">>}, _} when Empty >= MaxEmpty ->
            request(empty_line_too_long, <<"\r\n">>, Parser);
        {ok, {http_error, ReqLine}, _} ->
            req_error(bad_request_line, ReqLine, Parser);
        {ok, {http_response, _, _, _}, Rest} ->
             ReqLen = byte_size(Data) - byte_size(Rest),
            <<ReqLine:ReqLen/binary, _>> = Data,
            req_error(bad_request_line, ReqLine, Parser);
        {error, _} ->
            req_error(bad_request_line, Data, Parser)
    end.

req_error(Reason, Value, Parser) ->
    {error, {Reason, Value}, fail(Parser)}.

parse_request(Method, Path, URI, Vsn, Rest, #parser{config=Config} = Parser) ->
    Vsn2 = version(Vsn),
    Method2 = method(Method),
    case abs_path(Path) of
        {ok, Path2, Query} when Method2 =/= unknown ->
            #config{sockname=SockName, peername=PeerName} = Config,
            Request = #hippo_request{method=Method2, path=Path2, query=Query,
                                     uri=URI, version=Vsn2, sockname=SockName,
                                     peername=PeerName},
            NParser = Parser#parser{req=await_headers, version=Vsn2,
                                    buffer=Rest},
            {request, Request, NParser};
        {ok, _, _} when Method2 == unknown ->
            {error, {unknown_method, Method}, fail(Parser)};
        {error, Reason} ->
            {error, {Reason, Path}, fail(Parser)}
    end.

abs_uri({absoluteURI, http, Host, undefined, Path}) ->
    <<"http://", Host/binary, Path/binary>>;
abs_uri({absoluteURI, http, Host, Port, Path}) ->
    <<"http://", Host/binary, $:, (integer_to_binary(Port))/binary,
      Path/binary>>;
abs_uri({absoluteURI, https, Host, undefined, Path}) ->
    <<"https://", Host/binary, Path/binary>>;
abs_uri({absoluteURI, https, Host, Port, Path}) ->
    <<"https://", Host/binary, $:, (integer_to_binary(Port))/binary,
      Path/binary>>.

version({1, 0}) -> '1.0';
version({1, 1}) -> '1.1'.

method('GET') -> get;
method('POST') -> post;
method('PUT') -> put;
method('HEAD') -> head;
method('DELETE') -> delete;
method('OPTIONS') -> options;
method('TRACE') -> trace;
method(<<"COPY">>) -> copy;
method(<<"LOCK">>) -> lock;
method(<<"MKCOL">>) -> mkcol;
method(<<"MOVE">>) -> move;
method(<<"PURGE">>) -> purge;
method(<<"PROPFIND">>) -> propfind;
method(<<"PROPPATCH">>) -> proppatch;
method(<<"UNLOCK">>) -> unlock;
method(<<"REPORT">>) -> report;
method(<<"MKACTIVITY">>) -> mkactivity;
method(<<"CHECKOUT">>) -> checkout;
method(<<"MERGE">>) -> merge;
method(<<"M-SEARCH">>) -> m_search;
method(<<"SEARCH">>) -> search;
method(<<"NOTIFY">>) -> notify;
method(<<"SUBSCRIBE">>) -> subscribe;
method(<<"UNSUBSCRIBE">>) -> unsubscribe;
method(<<"PATCH">>) -> patch;
method(<<"CONNECT">>) -> connect;
method(Other) when is_binary(Other) -> unknown.

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

parse_headers(<<"\r\n", Rest/binary>>, 0, Parser) ->
    {headers, [], done(Rest, Parser)};
parse_headers(Data, Start, #parser{config=Config} = Parser) ->
    #config{crlf2=CRLF2, max_headers=MaxHeaders} = Config,
    Len = min(byte_size(Data), MaxHeaders) - Start,
    case binary:match(Data, CRLF2, [{scope, {Start, Len}}]) of
        nomatch when byte_size(Data) > MaxHeaders ->
            {error, {headers_too_long, Data}, fail(Parser)};
        nomatch ->
            {more, 0, Parser#parser{buffer=Data, req=headers}};
        {Pos, 4} ->
            HeadLen = Pos + 4,
            <<RawHeaders:HeadLen/binary, Rest/binary>> = Data,
            headers(RawHeaders, [], #body{}, Parser#parser{buffer=Rest})
    end.

headers(Buffer, Headers, Body, Parser) ->
    case erlang:decode_packet(httph_bin, Buffer, []) of
        {ok, {http_header, _, 'Connection', _, Value}, Rest} ->
            connection(header_value(Value), Rest, Headers, Body, Parser);
        {ok, {http_header, _, 'Content-Length', _, Value}, Rest} ->
            content_length(header_value(Value), Rest, Headers, Body, Parser);
        {ok, {http_header, _, 'Transfer-Encoding', _, Value}, Rest} ->
            transfer_encoding(header_value(Value), Rest, Headers, Body, Parser);
        {ok, {http_header, _, <<"Expect">>, _, Value}, Rest} ->
            expect(header_value(Value), Rest, Headers, Body, Parser);
        {ok, {http_header, _, Key, _, Value}, Rest} ->
            Header = {header_key(Key), header_value(Value)},
            headers(Rest, [Header | Headers], Body, Parser);
        {ok, http_eoh, <<>>} ->
            handle_headers(lists:reverse(Headers), Body, Parser);
        {ok, {http_error, Line}, _} ->
            {error, {bad_header_line, Line}, fail(Parser)}
    end.

header_key('Accept') -> <<"accept">>;
header_key('Accept-Charset') -> <<"accept-charset">>;
header_key(<<"Accept-Datetime">>) -> <<"accept-datetime">>;
header_key('Accept-Encoding') -> <<"accept-encoding">>;
header_key('Accept-Language') -> <<"accept-language">>;
header_key(<<"Accept-", Rest/binary>>) -> header_key(Rest, <<"accept-">>);
header_key('Authorization') -> <<"authorization">>;
header_key('Cache-Control') -> <<"cache-control">>;
header_key('Cookie') -> <<"cookie">>;
header_key('Content-Length') -> <<"Content-Length">>;
header_key('Content-Md5') -> <<"Content-Md5">>;
header_key('Content-Type') -> <<"Content-Type">>;
header_key(<<"Content-", Rest/binary>>) -> header_key(Rest, <<"content-">>);
header_key('Date') -> <<"date">>;
header_key(<<"Forwarded">>) -> <<"forwarded">>;
header_key('From') -> <<"from">>;
header_key('Host') -> <<"host">>;
header_key('If-Modified-Since') -> <<"if-modified-since">>;
header_key('If-Match') -> <<"if-match">>;
header_key('If-None-Match') -> <<"if-none-match">>;
header_key('If-Range') -> <<"if-range">>;
header_key('If-Unmodified-Since') -> <<"if-unmodified-since">>;
header_key('Max-Forwards') -> <<"max-forwards">>;
header_key(<<"Origin">>) -> <<"origin">>;
header_key('Pragma') -> <<"pragma">>;
header_key('Proxy-Authorization') -> <<"proxy-authorization">>;
header_key('Range') -> <<"range">>;
header_key('Referer') -> <<"referer">>;
header_key('TE') -> <<"te">>;
header_key('User-Agent') -> <<"user-agent">>;
header_key('Upgrade') -> <<"upgrade">>;
header_key('Via') -> <<"via">>;
header_key(<<"Warning">>) -> <<"warning">>;
header_key(<<"X-Requested-With">>) -> <<"x-requested-with">>;
header_key(<<"X-Forwarded-For">>) -> <<"x-forwarded-for">>;
header_key(<<"X-Forwarded-Host">>) -> <<"x-forwarded-host">>;
header_key(<<"X-Forwarded-Proto">>) -> <<"x-forwarded-proto">>;
header_key(<<"Front-End-Https">>) -> <<"front-end-https">>;
header_key(<<"X-Http-Method-Override">>) -> <<"x-http-method-override">>;
header_key(<<"X-Wap-Profile">>) -> <<"x-wap-profile">>;
header_key(<<"Proxy-Connection">>) -> <<"proxy-connection">>;
header_key(<<"X-Csrf-Token">>) -> <<"x-csrf-token">>;
header_key(<<"X-Csrftoken">>) -> <<"x-csrftoken">>;
header_key(<<"X-Xsrf-Token">>) -> <<"x-xsrf-token">>;
header_key(<<"Upgrade-Insecure-Requests">>) -> <<"upgrade-insecure-requests">>;
header_key(Key) when is_atom(Key) ->
    <<Upper, Rest/binary>> = atom_to_binary(Key, latin1),
    header_key(Rest, <<(Upper-$A+$a)>>);
header_key(<<Upper, Rest/binary>>) when Upper >= $A, Upper =< $Z ->
    header_key(Rest, <<(Upper-$A+$a)>>);
header_key(Key) when is_binary(Key) ->
    header_key(Key, <<>>).

header_key(<<$-, Upper, Rest/binary>>, Acc) when Upper >= $A, Upper =< $Z ->
    header_key(Rest, <<Acc/binary, $-, (Upper-$A+$a)>>);
header_key(<<Char, Rest/binary>>, Acc) ->
    header_key(Rest, <<Acc/binary, Char>>);
header_key(<<>>, Acc) ->
    Acc.

header_value(Value) ->
    header_value(Value, byte_size(Value)).

header_value(_, 0) ->
    <<>>;
header_value(Value, Len) ->
    Pos = Len - 1,
    case Value of
        <<_:Pos/binary, $\s, _/binary>> ->
            header_value(Value, Pos);
        <<_:Pos/binary, $\t, _/binary>> ->
            header_value(Value, Pos);
        <<_:Len/binary>> ->
            Value;
        <<NValue:Len/binary, _/binary>> ->
            NValue
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

connection(Value, Rest, Headers, Body,
           #parser{connection={force_close, Connection},
                   version=Version} = Parser) ->
    NHeaders = [{<<"connection">>, Value} | Headers],
    case connection(Value, Version) of
        Connection ->
            headers(Rest, NHeaders, Body, Parser);
        _ when Connection =/= undefined ->
            {error, {duplicate_header, <<"connection">>}};
        NConnection ->
            NParser = Parser#parser{connection={force_close, NConnection}},
            headers(Rest, NHeaders, Body, NParser)
    end;
connection(Value, Rest, Headers, Body,
           #parser{connection=Connection, version=Version} = Parser) ->
    NHeaders = [{<<"connection">>, Value} | Headers],
    case connection(Value, Version) of
        Connection ->
            headers(Rest, NHeaders, Body, Parser);
        _ when Connection =/= undefined ->
            {error, {duplicate_header, <<"connection">>}};
        NConnection ->
            headers(Rest, NHeaders, Body, Parser#parser{connection=NConnection})
    end.

content_length(Value, Rest, Headers, #body{content_length=Len} = Body,
               #parser{config=#config{max_body=MaxBody}} = Parser) ->
    NHeaders = [{<<"content-length">>, Value} | Headers],
    case content_length(Value) of
        NLen when is_integer(NLen), NLen > MaxBody, Len == undefined ->
            {error, {body_too_long, Value}};
        NLen when is_integer(NLen), NLen > 0, Len == undefined ->
            headers(Rest, NHeaders, Body#body{content_length=NLen}, Parser);
        Len ->
            headers(Rest, NHeaders, Body, Parser);
        _ when is_integer(Len) ->
            {error, {duplicate_header, <<"content-length">>}};
        {invalid, Value} ->
            {error, {invalid_content_length, Value}}
    end.

expect(Value, Rest, Headers, #body{expect=Expect} = Body,
       #parser{version='1.1'} = Parser) ->
    case expect(Value) of
        continue ->
            NHeaders = [{<<"expect">>, Value} | Headers],
            headers(Rest, NHeaders, Body#body{expect=continue}, Parser);
        _ when Expect == continue ->
            {error, {duplicate_header, <<"expect">>}};
        {unknown, Value} ->
            {error, {unknown_expectation, Value}}
    end;
expect(Value, Rest, Headers, Body, #parser{version='1.0'} = Parser) ->
    headers(Rest, [{<<"expect">>, Value} | Headers], Body, Parser).


transfer_encoding(Value, Rest, Headers,
                  #body{transfer_encoding=Transfer} = Body,
                  #parser{version=Version} = Parser) ->
    case transfer_encoding(Value, Version) of
        chunked when Transfer == undefined ->
            NHeaders = [{<<"transfer-encoding">>, Value} | Headers],
            NBody = Body#body{transfer_encoding=chunked},
            headers(Rest, NHeaders, NBody, Parser);
        chunked when Transfer == chunked ->
            {error, {unsupported_encoding, <<"chunked, chunked">>}};
        {unsupported, Encoding} when Transfer == chunked ->
            {error, {unsupported_encoding, <<"chunked, ", Encoding/binary>>}};
        {unsupported, Encoding} ->
            {error, {unsupported_encoding, Encoding}}
    end.

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
    [<<"Content-Length: ">>, integer_to_binary(iolist_size(Body)), $\r, $\n].

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

response(Status, Headers, Parser) ->
    ReqLine = [<<"HTTP/1.1 ">>, status(Status), $\r, $\n],
    resp_headers(Headers, ReqLine, Parser).

resp_headers(Headers, Acc, #parser{config=#config{date=exclude}}) ->
    resp_headers(Headers, Acc);
resp_headers(Headers, Acc, #parser{config=#config{date=Date}}) ->
    NAcc = [Acc, <<"Date:" >>, hippo_date:rfc5322_date(Date), $\r, $\n],
    resp_headers(Headers, NAcc).

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
