-module(hh_rabbitmq_webhooks).
-behaviour(gen_server).
-include_lib("amqp_client.hrl").
-export([start_link/0, init/1,handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([check_config/0, check_config/1]).
-record(state, { channel, config, queue, consumer_tag, http_requests_pool_name, cache_tab_name}).
-define(RefPosInETS, 4).
-define(ShedulerTimeout, 1000).
-define(ConfigPath, "/etc/rabbitmq/hh_rabbitmq_webhooks.config").

start_link() -> 
	rabbit_log:debug("Configuring HH RabbitMQ Webhooks... \n", []),
	case check_config(?ConfigPath) of
		{ok, Config} ->
			rabbit_log:debug("Configuring HH RabbitMQ Webhooks done \n", []),
			gen_server:start_link({global, ?MODULE}, ?MODULE, [Config], []);
		{error, Error} ->
			rabbit_log:debug("Invalid config ~p: ~p \n", [?ConfigPath, Error]),
			ignore
	end.

init([Config]) ->
	rabbit_log:debug("Initializing.. \n", []),
	
	{ok, Connection} = amqp_connection:start(direct),
	rabbit_log:debug("direct connection opened: ~p  ... \n", [Connection]),

	{ok, Channel} = amqp_connection:open_channel(Connection),
	rabbit_log:debug("channel opened ~p ... \n", [Channel]),

	%~ amqp_channel:call(Channel, #'exchange.delete'{exchange = proplists:get_value(exchange, Config)}),
	%~ rabbit_log:debug("exchange.delete ...  \n", []),
	
	%~ amqp_channel:call(Channel, #'exchange.declare'{exchange = proplists:get_value(exchange, Config), type = <<"direct">>,  durable=true}),
	%~ rabbit_log:debug("exchange.declare ...  \n", []),
	
	%~ amqp_channel:call(Channel, #'queue.delete'{queue = proplists:get_value(queue, Config)}),
	%~ rabbit_log:debug("queue.delete ... \n", []),
	
	%~ #'queue.declare_ok'{queue = Q} = amqp_channel:call(Channel, #'queue.declare'{queue = proplists:get_value(queue, Config), durable=true}), 
	%~ rabbit_log:debug("~p queue.declare ... \n", [Q]),
	
	%~ #'queue.bind_ok'{} = 
	%~ QueueBind = #'queue.bind'{ queue=Q,  exchange= proplists:get_value(exchange, Config), routing_key=proplists:get_value(routing_key, Config)},
	
	%~ amqp_channel:call(Channel, QueueBind),
	%~ rabbit_log:debug("queue bind ... \n", []),
	
	amqp_channel:call(Channel, #'basic.qos'{prefetch_count = proplists:get_value(cache_size, Config)}),
	rabbit_log:debug("QOS enabled with prefetch count ~p ... \n", [proplists:get_value(cache_size, Config)]),

	Q = proplists:get_value(queue, Config),
	#'basic.consume_ok'{ consumer_tag=Tag } = amqp_channel:subscribe(Channel, #'basic.consume'{ queue=Q, no_ack=false},  self()),
	rabbit_log:debug("subscribe consumer ...\n", []),

	%For test only:
	%timer:apply_after(100, gen_server, cast, [{global, ?MODULE}, put_test_msg]),
	%rabbit_log:debug("Put first test message ... \n", []),
	
	timer:apply_after(100, gen_server, cast, [{global, ?MODULE}, start_by_timeout]),
	rabbit_log:debug("Start sheduler ... \n", []),
	
	pg2:start(),
	PoolName=list_to_atom(atom_to_list(?MODULE) ++ "_http_requests_pool"),
	pg2:create(PoolName),
	
	Tab= ets:new(?MODULE, [ordered_set,  public, named_table]),
		
 	{ok, #state{ channel=Channel,  config=Config,  queue=Q, consumer_tag=Tag, http_requests_pool_name=PoolName, cache_tab_name=Tab}}.

handle_call(reload_config, _From, State=#state{ channel=_Channel, config=_Config }) ->
	rabbit_log:debug("Config reload request \n", []),
	case check_config(?ConfigPath) of
		{ok, NewConfig} ->
			rabbit_log:debug("Configuring HH RabbitMQ Webhooks done \n", []),
			{reply, "Config changed \n", State#state{config=NewConfig}};
		{error, Error} ->
			rabbit_log:debug("Invalid config ~p: ~p \n", [?ConfigPath, Error]),
			{reply, "Error while change config. See log \n", State}
	end;

handle_call(Msg, _From, State=#state{ channel=_Channel, config=_Config }) ->
	rabbit_log:debug(" Unkown call: ~p~n State: ~p~n", [Msg, State]),
	{noreply, State}.


%Only for use in testing
%~ handle_cast(put_test_msg, State = #state{ config=Config, channel = Channel}) ->
	%~ %rabbit_log:debug("Starting Put NEW test message OK  \n", []),
	%~ {_MegaSec, Sec, MicroSec} = now(),
	%~ ID = 1000000*Sec + MicroSec,
	
	%~ %{exchange, <<"searchable">>}, % add in test only and for bind
	
	%~ Properties = #'P_basic'{content_type = <<"octet/stream">>, headers= [{<<"id">>,signedint,ID},{<<"docType">>,longstr,<<"TEST_ENTITY">>}], delivery_mode = 1},
	%~ BasicPublish = #'basic.publish'{exchange =  proplists:get_value(exchange, Config),  routing_key =  proplists:get_value(routing_key, Config)},
	%~ Content = #amqp_msg{props = Properties},
	%~ amqp_channel:call(Channel, BasicPublish, Content),
	%~ timer:apply_after(100, gen_server, cast, [{global, ?MODULE}, put_test_msg]),
	%~ %rabbit_log:debug("Put NEW test message OK  \n", []),
	%~ {noreply, State};

%Started by timeout
handle_cast(start_by_timeout, State=#state{ channel=Channel, config=Config, http_requests_pool_name=PName, cache_tab_name=Tab}) ->
	rabbit_log:debug("Starting crontab in ~p \n", [now()]),

	PoolSize = length(pg2:get_local_members(PName)),
	rabbit_log:debug("Alive http connections: ~p\n", [PoolSize]),
	
	case PoolSize < proplists:get_value(max_alive_http_connections, Config) of
		true ->
			TagsList = case ets:match(Tab, {'$1','_','_',noref}, proplists:get_value(max_messages_in_post, Config)) of
				'$end_of_table' -> 
					[];
				{TgList, _} ->
					 lists:concat(TgList)
			end,
			rabbit_log:debug("Get free messages from cache ~w (cache size ~p)\n", [TagsList, ets:info(Tab,size)]),

			if 
				length(TagsList) > 0 ->
					Ref = make_ref(),
					update_refs(Tab, Ref, TagsList),
					rabbit_log:debug("Now messages ~w have ref ~p\n", [ ets:match(Tab, {'$1','_','_',Ref}), Ref]),

					%~ send_request(Channel, Ref, Config, Tab);
					Pid = spawn( fun() -> send_request(Channel, Ref, Config, Tab) end),
					pg2:join(PName, Pid);
				true ->
					do_nothing
			end;
			
		false ->
			do_nothing
	end,

	timer:apply_after(?ShedulerTimeout, gen_server, cast, [{global, ?MODULE}, start_by_timeout]),
	rabbit_log:debug("Stopping crontab in ~p \n", [now()]),
	{noreply, State};

handle_cast(Msg, State=#state{ channel=_Channel, config=_Config }) ->
	rabbit_log:debug(" Unkown cast: ~p~n State: ~p~n", [Msg, State]),
	{noreply, State}.


handle_info(#'basic.cancel_ok'{ consumer_tag=_Tag }, State) ->
	{noreply, State};

handle_info(#'basic.consume_ok'{ consumer_tag=_Tag }, State) ->
	{noreply, State};

%When message headers has valid format: [{Entity, signedint, ID}] send it or cache it
handle_info({
	#'basic.deliver'{ delivery_tag=DeliveryTag },  
	#amqp_msg{ props=#'P_basic'{headers=  [{<<"id">>,signedint,ID},{<<"docType">>,longstr,Entity}]=Headers  }}=AmqpMsg
	}, 
	State=#state{ channel=Channel, config=Config, http_requests_pool_name=PName, cache_tab_name=Tab})
	when is_integer(ID) andalso is_binary(Entity) ->

	rabbit_log:debug("Get valid message : ~p \nMessage headers: ~p  Tag ~p in ~p \n", [AmqpMsg, Headers, DeliveryTag, now()]),
	PostMsg = binary_to_list(Entity) ++ ":" ++ integer_to_list(ID) ++ " ",
	ets:insert(Tab, {DeliveryTag, PostMsg, now(), noref}),

	PoolSize = length(pg2:get_local_members(PName)),
	rabbit_log:debug("Alive http connections: ~p\n", [PoolSize]),
	
	case PoolSize < proplists:get_value(max_alive_http_connections, Config) of
		true ->
			Ref = make_ref(),
			ets:update_element(Tab, DeliveryTag, [{?RefPosInETS,Ref}]),

			TagsList = case ets:match(Tab, {'$1','_','_',noref}, proplists:get_value(max_messages_in_post, Config)) of
				'$end_of_table' -> 
					[];
				{TgList, _} ->
					 lists:concat(TgList)
			end,
			
			rabbit_log:debug("Get free messages from cache ~w (cache size ~p)\n", [TagsList, ets:info(Tab,size)]),
			update_refs(Tab, Ref, TagsList),
			rabbit_log:debug("Now messages ~w have ref ~p\n", [ ets:match(Tab, {'$1','_','_',Ref}), Ref]),

			%~ send_request(Channel, Ref, Config, Tab);
			Pid = spawn( fun() -> send_request(Channel, Ref, Config, Tab) end),
			pg2:join(PName, Pid);
			
		false ->
			rabbit_log:debug("Add message ~p with tag ~p to cache only in ~p (cache size ~p) \n", [PostMsg, DeliveryTag, now(), ets:info(Tab,size)])
	end,
	{noreply, State};

%When message headers has invalid format - delete it
handle_info({
	#'basic.deliver'{ delivery_tag=DeliveryTag },  
	#amqp_msg{ props=#'P_basic'{headers=Headers}} =AmqpMsg
	}, 
	State=#state{ channel=Channel})->

	rabbit_log:debug("Get invalid message: ~p \n Message headers: ~p \n Delete it \n", [AmqpMsg, Headers]),
	amqp_channel:call(Channel, #'basic.ack'{ delivery_tag=DeliveryTag }),
	{noreply, State};

handle_info(Msg, State) ->
	rabbit_log:debug(" Unkown message: ~p~n State: ~p~n", [Msg, State]),
	{noreply, State}.


terminate(_, #state{ channel=Channel, config=_Webhook, queue=_Q, consumer_tag=Tag }) -> 
	rabbit_log:debug("############ Terminating ~p ~p~n", [self(), Tag]),
	%TODO: unsubscribe
	%TODO: refuse all message in ets
	if
		Tag /= undefined -> amqp_channel:call(Channel, #'basic.cancel'{ consumer_tag = Tag })
	end,
	amqp_channel:call(Channel, #'channel.close'{}),
	ok.


code_change(_OldVsn, State, _Extra) -> 
	{ok, State}.


update_refs(_Tab, _Ref, [])->
	done;

update_refs(Tab, Ref, [HTag|T])->
	ets:update_element(Tab, HTag, [{?RefPosInETS, Ref}]),
	update_refs(Tab, Ref, T).


send_request(Channel, Ref, Config, Tab) ->
	%~ register(ref_to_atom(Ref), self()),
	rabbit_log:debug("Ready to send messages with ref:  ~p  \n", [Ref]),

	Url =  proplists:get_value(url, Config),
	Timeout =  proplists:get_value(http_connection_timeout_ms, Config),
	DeliveryTags = lists:concat(ets:match(Tab, {'$1','_','_',Ref})),
	Payload = lists:concat(lists:concat(ets:match(Tab, {'_', '$1', '_',Ref}))),
	rabbit_log:debug("URL: ~p  Method: ~p Message: ~p Timeout: ~p Tags ~w  in ~p\n", [Url, "POST", Payload, Timeout, DeliveryTags, now()]),
			
	try
		case lhttpc:request(Url, _Method="POST", _HttpHdrs =[], Payload, Timeout) of
			% Only ack if the server returns 200.
			{ok, {{Status, _}, Hdrs, Response}} when Status =:= 200->
				rabbit_log:debug("200:  Headers: ~p Response: ~p in ~p\n", [Hdrs, Response, now()]),
				ets:match_delete(Tab, {'$1','_','_',Ref}),
				lists:foreach(fun(Tag) -> amqp_channel:call(Channel, #'basic.ack'{delivery_tag=Tag}) end, DeliveryTags);
			Else ->
				rabbit_log:debug("Http client error response:~p  in ~p\n", [Else, now()]),
				lists:foreach(fun(Tag) -> ets:update_element(Tab, Tag, [{?RefPosInETS, noref}]) end, DeliveryTags)
		end
	catch Ex:E -> 
		rabbit_log:debug("Error requesting ~p: ~p ~p in ~p~n", [Url, Ex, E, now()]),
		lists:foreach(fun(Tag) -> ets:update_element(Tab, Tag, [{?RefPosInETS, noref}]) end, DeliveryTags)
	end.



check_config() ->
	check_config(?ConfigPath).

check_config(Path) ->
	try
		case hhrmq_lib_misc:consult(Path) of
			{ok, Config} ->
			
				rabbit_log:debug("Read config from ~p:  ~p  \n", [Path, Config]),
				ErrorAcc = check_param(nostart, proplists:get_value(nostart, Config), ""),
				ErrorAcc2 = check_param(queue, proplists:get_value(queue, Config), ErrorAcc),
				ErrorAcc3 = check_param(cache_size, proplists:get_value(cache_size, Config), ErrorAcc2),
				ErrorAcc4 = check_param(url, proplists:get_value(url, Config), ErrorAcc3),
				ErrorAcc5 = check_param(max_messages_in_post, proplists:get_value(max_messages_in_post, Config),ErrorAcc4),
				ErrorAcc6 = check_param(max_alive_http_connections, proplists:get_value(max_alive_http_connections, Config),ErrorAcc5),
				ErrorAcc7 = check_param(http_connection_timeout_ms, proplists:get_value(http_connection_timeout_ms, Config),ErrorAcc6),
				rabbit_log:debug("Config errors: ~s  \n", [ErrorAcc7]),
				
				case ErrorAcc7 of
					"" -> 
						{ok, Config};
					Other->
						{error, Other}
				end;

			{error, Error} ->
				{error, Error}
		end

	catch Ex:E -> 
		rabbit_log:debug("Error while check config ~p: ~p ~p. Bad config file or queue does not exist ~n", [Path, Ex, E]),
		{error, {Ex, E}}
	end.


check_param(nostart, "False", ErrorAcc) ->
	ErrorAcc;

check_param(nostart, _, ErrorAcc) ->
	ErrorAcc ++  "Param 'nostart' is not \"False\". Start canceled. \n";
	
check_param(queue, Name, ErrorAcc) when is_binary(Name)  ->
	R = rabbit_amqqueue:info_all(<<"/">>, [name]),
	R2 = lists:map(fun([{name,{resource,<<"/">>,queue, QName}}]) -> QName end, R),
	case lists:member(Name, R2) of
		true->
			ErrorAcc;
		false->
			ErrorAcc ++  "Queue not exist. Start canceled. \n"
	end;
	
check_param(queue, _Name, ErrorAcc)  ->
	ErrorAcc ++  "Param 'queue' has invalid format. Start canceled. \n";
	
check_param(cache_size, Size, ErrorAcc) when is_integer(Size) andalso Size > 0  ->
	ErrorAcc;

check_param(cache_size, _Size, ErrorAcc)  ->
	ErrorAcc ++  "Param 'cache_size' has invalid format or =< 0. Start canceled. \n";
	
check_param(url, URL, ErrorAcc) when is_list(URL)  ->
	case  http_uri:parse(URL) of
		{http,_,_Host,_Port,_Path,_Query} ->
			ErrorAcc;
		_Other ->
			ErrorAcc ++  "Param 'url' has invalid format. Start canceled. \n"
	end;

check_param(url, _URL, ErrorAcc)  ->
	ErrorAcc ++  "Param 'url' has invalid format. Start canceled. \n";	
	
check_param(max_messages_in_post, Messages, ErrorAcc) when is_integer(Messages) andalso Messages >  0  ->
	ErrorAcc;

check_param(max_messages_in_post, _Messages, ErrorAcc)  ->
	ErrorAcc ++  "Param 'max_messages_in_post' has invalid format or =< 0. Start canceled. \n";
	
check_param(max_alive_http_connections, Connections, ErrorAcc) when is_integer(Connections) andalso Connections >= 0 ->
	ErrorAcc;

check_param(max_alive_http_connections, _Connections, ErrorAcc)  ->
	ErrorAcc ++  "Param 'max_alive_http_connections' has invalid format or < 0. Start canceled. \n";
	
check_param(http_connection_timeout_ms, Timeout, ErrorAcc) when is_integer(Timeout) andalso Timeout >= 10  ->
	ErrorAcc;

check_param(http_connection_timeout_ms, _Timeout, ErrorAcc)  ->
	ErrorAcc ++  "Param 'http_connection_timeout_ms' has invalid format or < 10 ms. Start canceled. \n".	
	
