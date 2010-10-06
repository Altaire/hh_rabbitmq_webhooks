-module(hh_rabbitmq_webhooks_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> 
	supervisor:start_link({local, ?MODULE}, ?MODULE, _Arg=[]).

init([]) ->
    {ok, {{one_for_one, 10, 1},
          [{hh_rabbitmq_webhooks,
            {hh_rabbitmq_webhooks, start_link, []},
            permanent,
            10000,
            worker,
            [hh_rabbitmq_webhooks]}
          ]}}.









