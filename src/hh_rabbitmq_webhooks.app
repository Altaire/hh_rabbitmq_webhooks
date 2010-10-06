{application, hh_rabbitmq_webhooks, [
  {description, "HH Rabbit Webhooks"},
  {vsn, "1.0"},
  {modules, [
    hh_rabbitmq_webhooks_app,
    hh_rabbitmq_webhooks_sup
  ]},
  {registered, []},
  {mod, {hh_rabbitmq_webhooks_app, []}},
  {env, []},
  {applications, [kernel, stdlib, rabbit, amqp_client, lhttpc]}
]}.
