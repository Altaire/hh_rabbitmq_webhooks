all: compile
	cp -rf src/*.app ebin/hh_rabbitmq_webhooks/ebin/
	cd ebin/ ;	zip -r hh_rabbitmq_webhooks.ez hh_rabbitmq_webhooks/
	cp -rf deps/lhttpc/lhttpc.ez ebin/

compile:
	mkdir -p ebin/hh_rabbitmq_webhooks/ebin/
	@echo "******Start compiling *.erl files *******"
	erl -make
	@echo "******Stop compiling *.erl files *******"
	
clean:
	rm -rf ebin/hh_rabbitmq_webhooks/
	rm -f ebin/*.beam
	rm -f ebin/*.app
	rm -f ebin/*.ez
