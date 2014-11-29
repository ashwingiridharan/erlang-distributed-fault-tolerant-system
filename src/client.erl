
-module(client).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ====================================================================
%% API functions
%% ====================================================================
-export([startLink/1, start/1, process/3, executeRequest/15, executeItemizedRequests/2, resend_lost_requests/1]).



%% ====================================================================
%% Behavioural functions 
%% ====================================================================
-record(state, {result, bankname, head, tail, id, msg_tracker}).

%% init/1
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:init-1">gen_server:init/1</a>
-spec init(Args :: term()) -> Result when
	Result :: {ok, State}
			| {ok, State, Timeout}
			| {ok, State, hibernate}
			| {stop, Reason :: term()}
			| ignore,
	State :: term(),
	Timeout :: non_neg_integer() | infinity.
%% ====================================================================
startLink(Args) ->
	gen_server:start_link(client, [Args], []).

start(Args) ->
	socket_utils:start([{module,?MODULE}|Args]).

init([Args]) ->
	BankName = config_utils:getConfigVal(bankname, Args, undefined),
	HeadPort = config_utils:getConfigVal(head, Args, undefined),
	TailPort = config_utils:getConfigVal(tail, Args, undefined),
	Id = config_utils:getConfigVal(id, Args, undefined),
	spawn(?MODULE,resend_lost_requests,[self()]),
    {ok, #state{bankname=BankName, head=HeadPort, tail=TailPort, id=Id, msg_tracker=[]}}.


%% handle_call/3
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:handle_call-3">gen_server:handle_call/3</a>
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, State :: term()) -> Result when
	Result :: {reply, Reply, NewState}
			| {reply, Reply, NewState, Timeout}
			| {reply, Reply, NewState, hibernate}
			| {noreply, NewState}
			| {noreply, NewState, Timeout}
			| {noreply, NewState, hibernate}
			| {stop, Reason, Reply, NewState}
			| {stop, Reason, NewState},
	Reply :: term(),
	NewState :: term(),
	Timeout :: non_neg_integer() | infinity,
	Reason :: term().
%% ====================================================================
%% fetches head and tail for this client's bank
handle_call('getHeadTail', _From, State)->
	{reply, {State#state.head, State#state.tail}, State};

handle_call(Request, From, State) ->
    Reply = ok,
    {reply, Reply, State}.


%% handle_cast/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:handle_cast-2">gen_server:handle_cast/2</a>
-spec handle_cast(Request :: term(), State :: term()) -> Result when
	Result :: {noreply, NewState}
			| {noreply, NewState, Timeout}
			| {noreply, NewState, hibernate}
			| {stop, Reason :: term(), NewState},
	NewState :: term(),
	Timeout :: non_neg_integer() | infinity.
%% ====================================================================

handle_cast(Msg, State) ->
    {noreply, State}.


%% handle_info/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:handle_info-2">gen_server:handle_info/2</a>
-spec handle_info(Info :: timeout | term(), State :: term()) -> Result when
	Result :: {noreply, NewState}
			| {noreply, NewState, Timeout}
			| {noreply, NewState, hibernate}
			| {stop, Reason :: term(), NewState},
	NewState :: term(),
	Timeout :: non_neg_integer() | infinity.
%% ====================================================================

%% Perform ranomized or itemized transactions
handle_info({'perform_trans', CPortNo, ClientReqDelay, Config}, State) ->
	case config_utils:getConfigVal(client_req_method, Config, random) of
		random ->
			RandData =
				config_utils:getConfigVal(client_req_random, Config, nok),
			if RandData /= nok ->
				   	generateRandomRequests(RandData, {CPortNo, ClientReqDelay, Config, State});
			   true ->
				   ok
			end;
		_ ->
			GenData = config_utils:getConfigVal(client_req_itemized, Config, nok),
			if GenData /= nok ->
				   generateItemizedRequests({GenData, CPortNo, ClientReqDelay, Config, State});
			   true ->
				   ok
			end
	end,
	{noreply, State};

%% Append Messages to track it for loss
handle_info({'appendMsg', Msg}, State) ->
	MsgTracker = [Msg | State#state.msg_tracker],
	{noreply, State#state{msg_tracker=MsgTracker}};

%% Update head of the bank during initialization and failure handling
handle_info({'head', NewHead}, State) ->
	MyBank = State#state.bankname,
	MyId = State#state.id,
	logger:i_msg("Client ~p : Received Bank Head Update from Master. Details : ~p~n",[{MyBank, MyId},NewHead]),
	NState = State#state{head = NewHead},
	{noreply, NState};

%% Update tail of the bank during initialization and failure handling
handle_info({'tail', NewTail}, State) ->
	NState = State#state{tail = NewTail},
	MyBank = State#state.bankname,
	MyId = State#state.id,
	logger:i_msg("Client ~p : Received Bank Tail Update from Master. Details : ~p~n",[{MyBank, MyId},NewTail]),
	{noreply, NState};

%% Check for lost messages and resend it
handle_info('resend_lost_requests', State) ->
	CTS = getTimeStampInSec(),
	Fun =
		fun({ReqId, Req, SType, CPort, TS}, MsgTrackerIn) ->
				if CTS - TS > 60->
					   DPort =
						   case SType of
							   "head"->
								   State#state.head;
							   _ ->
								   State#state.tail
						   end,
					   logger:i_msg("Client: RESEND Resending lost request : ~p~n", [Req]),
					   socket_utils:send_async(DPort, {Req, CPort}),
					   lists:keydelete(ReqId, 1, MsgTrackerIn);
				   true ->
					   MsgTrackerIn
				end
		end,
	MsgTrackerOut = lists:foldl(Fun, State#state.msg_tracker, State#state.msg_tracker),
	{noreply, State#state{msg_tracker=MsgTrackerOut}};

%% Handle incoming messages from server. Delete the messages from message tracker on receival
handle_info(Info, State) ->
	MyBank = State#state.bankname,
	MyId = State#state.id,
	logger:i_msg("Client ~p : Received Message From Server. Details : ~p~n",[{MyBank, MyId},Info]),
	MsgTracker =
		case Info of
			{result,{ReqId,_,_,_}}->
				lists:keydelete(ReqId, 1, State#state.msg_tracker);
			_ ->
				logger:e_msg("Client ~p : Received UNEXPECTED Message From Server. Details : ~p~n",[{MyBank, MyId},Info]),
				State#state.msg_tracker
		end,
    {noreply, State#state{msg_tracker=MsgTracker}}.



%% terminate/2
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:terminate-2">gen_server:terminate/2</a>
-spec terminate(Reason, State :: term()) -> Any :: term() when
	Reason :: normal
			| shutdown
			| {shutdown, term()}
			| term().
%% ====================================================================
terminate(Reason, State) ->
    ok.


%% code_change/3
%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/man/gen_server.html#Module:code_change-3">gen_server:code_change/3</a>
-spec code_change(OldVsn, State :: term(), Extra :: term()) -> Result when
	Result :: {ok, NewState :: term()} | {error, Reason :: term()},
	OldVsn :: Vsn | {down, Vsn},
	Vsn :: term().
%% ====================================================================
code_change(OldVsn, State, Extra) ->
    {ok, State}.


%% ====================================================================
%% Generator Functions
%% ====================================================================

%% Generate randomized requests
generateRandomRequests(RandData, {CPortNo, ClientReqDelay, Config, State}) ->
	IsRetransmitRequests = config_utils:getConfigVal(client_retransmit_req_randomly, Config, false),
		
	BankName = State#state.bankname,
	MyId = State#state.id,
	MyIndex = BankName ++ "." ++ integer_to_list(MyId),
	%% Seed will not be used, as we will always use erlang:now() as the seed
	{_Seed, NumReq, GetBalProb, DepositProb, WithdrawProb, TransferProb}=
		case lists:keyfind(MyIndex, 1, RandData) of
			{_,{S,NR,GP,DP,WP,TP}} when NR >= 12 ->
				{S,NR,GP,DP,WP,TP};
			{_,{S,_,GP,DP,WP,TP}} ->
				{S,12,GP,DP,WP,TP};
			_ ->
				{now(), 12, 0.1, 0.2, 0.3, 0.4}
		end,
	GetBalFreq = round(NumReq * GetBalProb),
	DepositFreq = round(NumReq * DepositProb),
	WithdrawFreq = round(NumReq * WithdrawProb),
	TransferFreq = round(NumReq * TransferProb),
	
	TotalFreq = GetBalFreq + DepositFreq + WithdrawFreq + TransferFreq,
	GetBalRate = round(TotalFreq / GetBalFreq),
	DepositRate = round(TotalFreq / DepositFreq),
	WithdrawRate = round(TotalFreq / WithdrawFreq),
	TransferRate = round(TotalFreq / TransferFreq),
	spawn(?MODULE,executeRequest,[TotalFreq, 1, IsRetransmitRequests, GetBalFreq, DepositFreq, WithdrawFreq, TransferFreq, GetBalRate, DepositRate, WithdrawRate, TransferRate, State, CPortNo, ClientReqDelay, self()]).

%% Execution function for randomized requests
executeRequest(0, _, _, _, _, _, _, _, _, _, _, _, _, _,_) ->
	ok;
	
%% Execution function for randomized requests
executeRequest(TotalFreq, Iter, IsRetransmitRequest, GetBalFreq, DepositFreq, WithdrawFreq, TransferFreq, GetBalRate, DepositRate, WithdrawRate, TransferRate, State, CPortNo, ClientReqDelay, ClientPid)	->
	if Iter == 1->
		   sleep(10000);
	   true ->
		   ok
	end,
	
	AccNum = generateAccNum(State#state.bankname),
	{HeadPort,TailPort} = gen_server:call(ClientPid, 'getHeadTail'),
	BankName = State#state.bankname,
	MyId = State#state.id,
	random:seed(now()),
	
	{TF1, GBF} =
		if Iter rem GetBalRate == 0, GetBalFreq > 0 ->
			   ReqId = generateReqId(BankName, MyId),
			   R1 = {'getBalance', ReqId, AccNum},
			   socket_utils:send_async(TailPort, {R1,CPortNo}),
			   ClientPid ! {'appendMsg', {ReqId, R1, "tail", CPortNo, getTimeStampInSec()}},
			   sleep(ClientReqDelay),
			   case isRetransmitRequest(IsRetransmitRequest) of
				   true ->
					   logger:i_msg("Client : Retransmitting requests based on dice roll probability : ~p~n", [R1]),
					   socket_utils:send_async(TailPort, {R1,CPortNo}),
					   ClientPid ! {'appendMsg', {ReqId, R1, "tail",CPortNo, getTimeStampInSec()}},
					   sleep(ClientReqDelay);
				   _ ->
					   ok
			   end,
			   {TotalFreq-1, GetBalFreq-1};
		   true ->
			   {TotalFreq, GetBalFreq}
		end,
	{TF2, DF} =
		if Iter rem DepositRate == 0, DepositFreq > 0 ->
			   ReqId2 = generateReqId(BankName, MyId),
			   R2 = {'deposit', ReqId2, AccNum, random:uniform(9000)+1000},
			   socket_utils:send_async(HeadPort, {R2, CPortNo}),
			   ClientPid ! {'appendMsg', {ReqId2, R2, "head", CPortNo, getTimeStampInSec()}},
			   sleep(ClientReqDelay),
			   case isRetransmitRequest(IsRetransmitRequest) of
				   true ->
					   logger:i_msg("Client : Retransmitting requests based on dice roll probability : ~p~n", [R2]),
					   ClientPid ! {'appendMsg', {ReqId2, R2, "head",CPortNo, getTimeStampInSec()}},
					   socket_utils:send_async(HeadPort, {R2,CPortNo}),
					   sleep(ClientReqDelay);
				   _ ->
					   ok
			   end,
			   {TF1-1, DepositFreq-1};
		   true ->
			   {TF1, DepositFreq}
		end,
	{TF3, WF} =
		if Iter rem WithdrawRate == 0, WithdrawFreq > 0 ->
			   ReqId3 = generateReqId(BankName, MyId),
			   R3 = {'withdraw', ReqId3, AccNum, random:uniform(9000)+1000},
			   socket_utils:send_async(HeadPort, {R3, CPortNo}),
			   ClientPid ! {'appendMsg', {ReqId3, R3, "head", CPortNo, getTimeStampInSec()}},
			   sleep(ClientReqDelay),
			   case isRetransmitRequest(IsRetransmitRequest) of
				   true ->
					   logger:i_msg("Client : Retransmitting requests based on dice roll probability : ~p~n", [R3]),
					   socket_utils:send_async(HeadPort, {R3,CPortNo}),
					   ClientPid ! {'appendMsg', {ReqId3, R3, "head", CPortNo, getTimeStampInSec()}},
					   sleep(ClientReqDelay);
				   _ ->
					   ok
			   end,
			   {TF2-1, WithdrawFreq-1};
		   true ->
			   {TF2, WithdrawFreq}
		end,
	{TF4, TF} =
		if Iter rem TransferRate == 0, TransferFreq > 0 ->
			   ReqId4 = generateReqId(BankName, MyId),
			   DestBank = chooseRandomBank([], BankName),
			   R4 = {'transfer', ReqId4, AccNum, random:uniform(9000)+1000, DestBank, generateFixedAccNum(DestBank,5) },
			   socket_utils:send_async(HeadPort, {R4, CPortNo}),
			   ClientPid ! {'appendMsg', {ReqId4, R4, "head", CPortNo, getTimeStampInSec()}},
			   sleep(ClientReqDelay),
			   case isRetransmitRequest(IsRetransmitRequest) of
				   true ->
					   logger:i_msg("Client : Retransmitting requests based on dice roll probability : ~p~n", [R4]),
					   socket_utils:send_async(HeadPort, {R4,CPortNo}),
					   ClientPid ! {'appendMsg', {ReqId4, R4, "head", CPortNo, getTimeStampInSec()}},
					   sleep(ClientReqDelay);
				   _ ->
					   ok
			   end,
			   {TF3-1, TransferFreq-1};
		   true ->
			   {TF3, TransferFreq}
		end,
	executeRequest(TF4, Iter+1, IsRetransmitRequest, GBF, DF, WF, TF, GetBalRate, DepositRate, WithdrawRate, TransferRate, State, CPortNo, ClientReqDelay, ClientPid).

%% Decides if a request has to be retransmitted based on dice roll probability
isRetransmitRequest(IsRetransmitRequest) ->
	if IsRetransmitRequest ->
		   DiceToss = random:uniform(6),
		   if DiceToss == 1 ->
				  true;
			  true ->
				  false
		   end;
	   true ->
		   false
	end.
		  

%% Generate Itemized requests
generateItemizedRequests({GenData, CPortNo, ClientReqDelay, Config, State}) ->
	IsRetransmitRequests = config_utils:getConfigVal(client_retransmit_req_randomly, Config, false),
	BankName = State#state.bankname,
	MyId = State#state.id,
	MyItemsIndex = BankName ++ "." ++ integer_to_list(MyId),
	case lists:keyfind(MyItemsIndex, 1, GenData) of
		{_,MyExecList} ->
			spawn(?MODULE,executeItemizedRequests,[MyExecList, {CPortNo, ClientReqDelay, State, IsRetransmitRequests, self()}]);
		_ ->
			ok
	end.

%% Execution function for itemized requests
executeItemizedRequests(MyExecList, {CPortNo, ClientReqDelay, State, IsRetransmitRequests, ClientPid}) ->
	sleep(10000),
	random:seed(now()),
	ExecFun =
		fun(Req) ->
			{HeadPort,TailPort} = gen_server:call(ClientPid, 'getHeadTail'),
			{SPort,SType} = 
				if element(1, Req) == 'getBalance' ->
					   {TailPort,"tail"};
				   true ->
					   {HeadPort,"head"}
				end,
			ReqId = element(2, Req),
			socket_utils:send_async(SPort, {Req, CPortNo}),
			ClientPid ! {'appendMsg', {ReqId, Req, SType, CPortNo, getTimeStampInSec()}},
			sleep(ClientReqDelay),
			case isRetransmitRequest(IsRetransmitRequests) of
				true ->
					logger:i_msg("Client : Retransmitting requests based on dice roll probability ~p~n", [Req]),
					socket_utils:send_async(SPort, {Req, CPortNo}),
					ClientPid ! {'appendMsg', {ReqId, Req, SType, CPortNo, getTimeStampInSec()}},
					sleep(ClientReqDelay);
				_ ->
					ok
			end
		end,
	lists:foreach(ExecFun, MyExecList).

%% process that informs client to check for lost requests periodically
resend_lost_requests(ClientPid) ->
	timer:sleep(5000),
	ClientPid ! 'resend_lost_requests',
	resend_lost_requests(ClientPid).
	
%% ====================================================================
%% Util Functions
%% ====================================================================

process(Socket, Data, SPid) ->
%% 	logger:i_msg("Data Received ~p~n",[binary_to_term(Data)]).
	SPid ! binary_to_term(Data).
	
sleep(Ms) ->
	timer:sleep(Ms).

generateReqId(BankName, ClientId) ->
	{Meg, Sec, Mic} = now(),
	TS = (Meg*1000000 + Sec)*1000000 + Mic,
	BankName ++ "." ++ integer_to_list(ClientId) ++"."++ integer_to_list(TS).

generateAccNum(BankName) ->
	{Meg, Sec, Mic} = now(),
	TS = (Meg*1000000 + Sec)*1000000 + Mic,
	"acc"++BankName++integer_to_list(TS).

generateFixedAccNum(BankName, Range) ->
	List = lists:seq(1, Range),
	Index = random:uniform(length(List)),
	NumS = lists:nth(Index,List),
	"acc"++BankName++integer_to_list(NumS).

getTimeStampInSec() ->
	{Meg, Sec, _} = now(),
	Meg*1000000 + Sec.
%% round(FloatNum) ->
%% 	list_to_integer(float_to_list(FloatNum,[{decimals,0}])).

chooseRandomBank(BankList1, MyName) ->
	BankList = ["hdfc","tfcu","citi"],
	List = lists:delete(MyName, BankList),
	Index = random:uniform(length(List)),
	lists:nth(Index,List).
