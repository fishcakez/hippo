-record(hippo_request, {method :: hippo_http:method(),
                        path :: [binary()] | '*',
                        query :: [{binary(), binary()}],
                        version :: hippo_http:version(),
                        uri :: binary(),
                        sockname :: acceptor_pool:name(),
                        peername :: acceptor_pool:name()}).
