cp -fv ebin/*.ez /usr/lib/rabbitmq/lib/rabbitmq_server-2.1.0/plugins/
#cp -fv ebin/*.ez /usr/lib/erlang/lib/rabbitmq-server-2.1.0/plugins/

/etc/init.d/rabbitmq-server stop
#/etc/init.d/rabbitmq stop

rm -f /var/log/rabbitmq/*

/etc/init.d/rabbitmq-server start
#/etc/init.d/rabbitmq start
