-record(hippo_request, {method :: hippo_http:method(),
                        path :: [binary()] | '*',
                        query :: [{binary(), binary()}],
                        version :: hippo_http:version(),
                        uri :: binary(),
                        sockname :: {inet:ip_address(), inet:port_num()},
                        peername :: {inet:ip_address(), inet:port_num()}}).
 
