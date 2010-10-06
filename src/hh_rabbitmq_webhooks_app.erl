-module(hh_rabbitmq_webhooks_app).
-export([start/0, stop/0, start/2, stop/1]).

start() ->
    hh_rabbitmq_webhooks_sup:start_link(), ok.

stop() ->
    ok.

start(normal, []) ->
    hh_rabbitmq_webhooks_sup:start_link().

stop(_State) ->
    ok.