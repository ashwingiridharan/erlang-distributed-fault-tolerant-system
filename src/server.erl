%% Server Process

-module(server).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ====================================================================
%% API functions
%% ====================================================================
-export([startLink/1, process/3, start/1, pingMaster/3]).

-include("macro_utils.hrl").

%% ====================================================================
%% Behavioural functions 
%% ====================================================================
-record(state, {balanceMap, processedTransMap, succPort, predPort, masterPort, myPort, 
				myName, msgSentCtr=0, msgRecvCtr=0, failMsgRecvCtr=0, crashType=?UNBOUNDED, 
				pingerPid, sentRequests, ackDelay=0, simulate_msg_loss=false, otherBankHTPorts = []}).


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

start(Args) ->
	socket_utils:start([{module,?MODULE}|Args]).

startLink(Args) ->
	gen_server:start_link(server, [Args], []).

init([Args]) ->
	{port, MyPort} = lists:keyfind(port, 1, Args),
	{bankname, MyName} = lists:keyfind(bankname, 1, Args),
	{masterport, MasterPort} = lists:keyfind(masterport, 1, Args),
	{crashtype, CrashType} = lists:keyfind(crashtype, 1, Args),
	{ackDelay, SimulateAckDelay} = lists:keyfind(ackDelay, 1, Args),
	{simulate_msg_loss, SimulateMsgLoss} = lists:keyfind(simulate_msg_loss, 1, Args),
	%% Spawn ping process
	PingerPid = spawn_link(?MODULE, pingMaster, [MasterPort, MyName, MyPort]),
    {ok, #state{balanceMap=[], processedTransMap=[], myPort = MyPort, myName = MyName, masterPort = MasterPort, 
				crashType=CrashType, pingerPid=PingerPid, sentRequests=[],
				ackDelay = SimulateAckDelay, simulate_msg_loss=SimulateMsgLoss}}.


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
	logger:i_msg("Received Unknown Msg by server ~p~n",[Msg]),
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

%% Update other bank head from master
handle_info({'setOtherBankHead', BankName, Head}, State)->
	logger:i_msg("Server : ~p Received setHead for the bank ~p. Head : ~p~n", [{State#state.myName,State#state.myPort}, BankName, Head]),
	NewHTPorts = 
		case lists:keyfind(BankName, 1, State#state.otherBankHTPorts) of
			false ->
				[{BankName, Head, ?UNDEFINED} | State#state.otherBankHTPorts];
			{BankName, _, Tail} ->
				lists:keyreplace(BankName, 1, State#state.otherBankHTPorts, {BankName, Head, Tail})
		end,
	{noreply, State#state{otherBankHTPorts =NewHTPorts}};

%% Update other bank tail from master
handle_info({'setOtherBankTail', BankName, Tail}, State)->
	logger:i_msg("Server : ~p Received setTail for the bank ~p. Tail : ~p~n", [{State#state.myName,State#state.myPort}, BankName, Tail]),
	NewHTPorts = 
		case lists:keyfind(BankName, 1, State#state.otherBankHTPorts) of
			false ->
				[{BankName, ?UNDEFINED, Tail} | State#state.otherBankHTPorts];
			{BankName, Head, _} ->
				lists:keyreplace(BankName, 1, State#state.otherBankHTPorts, {BankName, Head, Tail})
		end,
	{noreply, State#state{otherBankHTPorts =NewHTPorts}};
			

%% Setting successor for the server
handle_info({'setSuccessor', SuccPort}, State) ->
	logger:i_msg("Server ~p : Setting successor as ~p~n",[{State#state.myName, State#state.myPort}, SuccPort]),
	{noreply, State#state{succPort = SuccPort}};

%% Setting predecessor for the server
handle_info({'setPredecessor', PredPort}, State) ->
	logger:i_msg("Server ~p : Setting predecessor as ~p~n",[{State#state.myName, State#state.myPort}, PredPort]),
	{noreply, State#state{predPort = PredPort}};

%% Handle sync event from predecessor
handle_info({'sync', Result, ClientPort, AccountNum, PTransObj, PredPort}, State) ->
	logger:i_msg("Server ~p : Received sync event from server ~p , BalanceObj : ~p , TransObj : ~p~n",[{State#state.myName, State#state.myPort}, PredPort, Result, PTransObj]),
	NState =
		if State#state.predPort == PredPort ->
			   NS = updateBalanceAndTransactionMaps(AccountNum, Result, PTransObj, State),
			   NS1 = sync(Result, ClientPort, AccountNum, PTransObj, NS),
			   NS1;
		   true ->
			   logger:e_msg("Chain Corrupted - Receiving sync from unexpected server. Details : ~p~n", [{'sync', Result, ClientPort, AccountNum, PTransObj, PredPort}]),
			   State
	end,
	checkForTermination(NState, {?SEND,?RECEIVE});

%% Handle sync transfer event from predecessor
handle_info({'syncTransfer', Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, PredPort}, State)->
	logger:i_msg("Server ~p : Received sync transfer event from server ~p , BalanceObj : ~p , TransObj : ~p~n",[{State#state.myName, State#state.myPort}, PredPort, Result, PTransObj]),
	NState =
		if State#state.predPort == PredPort ->
			   NS = updateBalanceAndTransactionMaps(AccountNum, Result, PTransObj, State),
			   NS1 = sync_transfer(Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, NS),
			   NS1;
		   true ->
			   logger:e_msg("Chain Corrupted - Receiving sync transfer from unexpected server. Details : ~p~n", 
							[{'syncTransfer', Result, ClientPort, AccountNum,SrcBank, DestBank, DestAccountNum, Amount, PTransObj, PredPort}]),
			   State
	end,
	{noreply, NState};

%% Handle sync deposit from predecessor
handle_info({'syncDeposit', Result, ClientPort, SrcBank, SrcMsg, DestAccountNum, PTransObj, PredPort}, State) ->
	logger:i_msg("Server ~p : Received sync deposit event from server ~p , BalanceObj : ~p , TransObj : ~p~n",[{State#state.myName, State#state.myPort}, PredPort, Result, PTransObj]),
	NState =
		if State#state.predPort == PredPort ->
			   NS = updateBalanceAndTransactionMaps(DestAccountNum, Result, PTransObj, State),
			   NS1 = sync_deposit(Result, ClientPort, SrcBank, SrcMsg, DestAccountNum, PTransObj, NS),
			   NS1;
		   true ->
			   logger:e_msg("Chain Corrupted - Receiving sync deposit from unexpected server. Details : ~p~n", 
							[{'syncDeposit', Result, ClientPort, SrcBank, SrcMsg, DestAccountNum, PTransObj}]),
			   State
	end,
	{noreply, NState};
		

%% Receive transfer request from previous bank
handle_info({'depositTransfer', Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, PrevBankPort}, State) ->
	logger:i_msg("Server ~p : Received deposit transfer request from other bank. Details : ~p~n", 
				 [{State#state.myName, State#state.myPort},
				  {'depositTransfer', Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj, PrevBankPort}]),
	ReturnState =
		case checkForTermination(State, ?TRANS_DEPOSIT) of
			{stop,Reason,RState} ->
				case State#state.crashType of
					{?HEAD_TAIL_CRASH, _} ->
						socket_utils:send_async(PrevBankPort, 'simulatekill');
					_ ->
						ok
				end,
				{stop,Reason,RState};
			{noreply, RState} ->
				SrcTailAckMsg = {'sentRequestsTransAck', Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj},
				{DResult, DPTransObj, NState} = deposit(element(1, Result), DestAccountNum, Amount, ?TRANSFERDEPOSIT, RState),
				NState1 = sync_deposit(DResult, ClientPort, SrcBank, SrcTailAckMsg, DestAccountNum, DPTransObj, NState),
				{noreply, NState1}
		end,
	ReturnState;

handle_info('simulatekill', State) ->
	logger:e_msg("Server ~p : Terminating... Tail Crashing to simulate Head Tail Crash Scenario ~n", [{State#state.myName, State#state.myPort}]),
	{stop, normal, State};

%% Handle ack for sent requests
handle_info({'sentRequestsAck',Result, ClientPort, AccountNum, PTransObj}, State) ->
	SentRequests = lists:delete({Result, ClientPort, AccountNum, PTransObj}, State#state.sentRequests),
	if State#state.predPort /= ?UNDEFINED ->
		   socket_utils:send_async(State#state.predPort, {'sentRequestsAck',Result, ClientPort, AccountNum, PTransObj});
	   true ->
		   ok
	end,
%% 	logger:i_msg("Server ~p : SentRequests while receiving ack from successor ~p~n", [{State#state.myName, State#state.myPort}, SentRequests]),
	{noreply, State#state{sentRequests = SentRequests}};

%% Handle transfer ack from dest bank
handle_info({'sentRequestsTransAck',Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}, State) ->
	SentRequests = lists:delete({Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}, State#state.sentRequests),
	if State#state.predPort /= ?UNDEFINED ->
		   socket_utils:send_async(State#state.predPort, {'sentRequestsTransAck',Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj});
	   true ->
		   ok
	end,
%% 	logger:i_msg("Server ~p : Sent Requests while receiving trans ack from successor / dest bank ~p. Ack received : ~p~n", [{State#state.myName, State#state.myPort}, SentRequests, {Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}]),
	{noreply, State#state{sentRequests = SentRequests}};

handle_info({'sentRequestsDepositAck', Result, ClientPort, DestAccountNum, PTransObj}, State) ->
	SentRequests = lists:delete({Result, ClientPort, DestAccountNum, PTransObj}, State#state.sentRequests),
	if State#state.predPort /= ?UNDEFINED ->
		   socket_utils:send_async(State#state.predPort, {'sentRequestsDepositAck', Result, ClientPort, DestAccountNum, PTransObj});
	   true ->
		   ok
	end,
%% 	logger:i_msg("Server ~p : sentRequestsDepositAck while receiving ack from successor ~p~n", [{State#state.myName, State#state.myPort}, SentRequests]),
	{noreply, State#state{sentRequests = SentRequests}};

%% S+ sends its sent requests index to master on master's request
handle_info({'handlePredCrash',MyNewPred}, State)->
	logger:i_msg("Server ~p : MIDCRASHHANDLING Received handlePredCrash from master for my new pred: ~p~n", [{State#state.myName, State#state.myPort}, MyNewPred]),
	SentRequestsLen = length(State#state.sentRequests),
	socket_utils:send_async(State#state.masterPort, {'respHandlePredCrash', SentRequestsLen, MyNewPred, State#state.myPort}),
	checkForTermination(State, ?RECEIVE_FAIL);

%% S- sends the suffix list of sent requests to S+, as requested by master
handle_info({'handleSuccCrash', SentRequestsLen, NewSucc}, State) ->
	if length(State#state.sentRequests) > SentRequestsLen ->
		   SentRequestsSuffix = lists:nthtail(SentRequestsLen, State#state.sentRequests),
		   logger:i_msg("Server ~p : MIDCRASHHANDLING Sending SentrequestsSuffixList to my new successor ~p : ~p~n", [{State#state.myName, State#state.myPort},NewSucc, SentRequestsSuffix]),
		   socket_utils:send_async(NewSucc, {'processNoAckRequests', SentRequestsSuffix});
	   true ->
		   logger:i_msg("Server ~p : MIDCRASHHANDLING No SentrequestsSuffixList to be sent to my new successor ~p~n", [{State#state.myName, State#state.myPort},NewSucc])
	end,
	checkForTermination(State, ?RECEIVE_FAIL);

%% S+ on receiving the sent requests suffix list, uppdates the map and propagates the list contents to its successor
handle_info({'processNoAckRequests', SentRequestsSuffix}, State) ->
	logger:i_msg("Server ~p : MIDCRASHHANDLING Received SentrequestsSuffixList from my new predecessor : ~p~n", [{State#state.myName, State#state.myPort},SentRequestsSuffix]),
	UpdateFun =
		fun({Result, ClientPort, AccountNum, PTransObj}, AccStateIn) ->
				AccStateOut = updateBalanceAndTransactionMaps(AccountNum, Result, PTransObj, AccStateIn),
				AccStateOut1 = sync(Result, ClientPort, AccountNum, PTransObj, AccStateOut),
				AccStateOut1
		end,
	OutState = lists:foldl(UpdateFun, State, SentRequestsSuffix),
	{noreply, OutState};

%% When a server becomes tail after its successor's failure
handle_info('takeNewTailAction', State) ->
	logger:i_msg("Server ~p : Taking new tail action. Current SentRequests ~p~n", [{State#state.myName, State#state.myPort}, State#state.sentRequests]),
	SentReqDelegateFun =
		fun({Result, ClientPort, AccountNum, PTransObj}, AccIn) ->
				%% Resend responses to client, even if it is duplicate. Availability matters ;)
				socket_utils:send_async(ClientPort, {result, Result}),
				%% Send all the sentRequests to predecessor
				if State#state.predPort /= ?UNDEFINED ->
					   socket_utils:send_async(State#state.predPort, {'sentRequestsAck',Result, ClientPort, AccountNum, PTransObj}),
					   AccOut = lists:delete({Result, ClientPort, AccountNum, PTransObj}, AccIn),
					   AccOut;
				   true ->
					   AccIn
				end;
		   %% Do not process sent transfers request
		   (_, AccIn) ->
				AccIn
		end,
	SentRequestsOut = lists:foldl(SentReqDelegateFun, State#state.sentRequests, State#state.sentRequests),
	{noreply, State#state{sentRequests = SentRequestsOut}};

%% Retransmit transfers on my bank's old tail failure or new tail extension
handle_info('takeTailTransferResendAction', State) ->
	logger:i_msg("Server ~p : Retransmitting transfers on my bank's old tail failure or new tail extension. Current SentRequests ~p~n", 
				 [{State#state.myName, State#state.myPort}, State#state.sentRequests]),
	takeTailTransferResendAction(State),
	{noreply, State};

%% Retransmit transfers on my on my dest bank's head failure
handle_info({'takeTailTransferResendAction', DestBank}, State) ->
	logger:i_msg("Server ~p : Retransmitting transfers on my dest bank's head failure ~p. Current SentRequests ~p~n", 
				 [{State#state.myName, State#state.myPort}, DestBank, State#state.sentRequests]),
	takeTailTransferResendAction(DestBank, State),
	{noreply, State};

%% When a tail becomes mid server after a new tail becomes its successor
handle_info({'takeOldTailAction', {BankName, CurrTail, NewTail, Master}}, State) ->
	logger:i_msg("Server ~p : EXTENDCHAIN Sending BalanceMap and TransMap to New Tail ~p~n", [{State#state.myName, State#state.myPort}, NewTail]),
	BalanceMap = State#state.balanceMap,
	ProcessedTransMap = State#state.processedTransMap,
	socket_utils:send_async(NewTail, {'setBalanceAndTransMap', BalanceMap,  ProcessedTransMap, {BankName, CurrTail, NewTail, Master}}),
	checkForTermination(State, ?RECEIVE_EXT);

%% When new tail receives the BalanceMap and ProcessedTransMap
handle_info({'setBalanceAndTransMap', BalanceMap,  ProcessedTransMap, {BankName, CurrTail, NewTail, Master}}, State) ->
	logger:i_msg("Server ~p : EXTENDCHAIN Receiving BalanceMap and TransMap from Old Tail ~p. Maps ~p~n", [{State#state.myName, State#state.myPort}, CurrTail, {BalanceMap,  ProcessedTransMap}]),
	socket_utils:send_async(Master, {'ackSetBalanceAndTransMap',{BankName, CurrTail, NewTail, Master}}),
	NState = State#state{balanceMap = BalanceMap, processedTransMap=ProcessedTransMap},
	checkForTermination(NState, ?RECEIVE);
	
	

%% Receive getBalance from client
handle_info({{'getBalance', ReqId,  AccountNum}, ClientPort}, State) ->
	logger:i_msg("Server ~p : Received getBalance from client ~p. Details : ~p~n",[{State#state.myName, State#state.myPort}, ClientPort, {'getBalance', ReqId,  AccountNum} ]),
	{Result, NState} = getBalance(ReqId, AccountNum, State),
	socket_utils:send_async(ClientPort, {result,Result}),
	checkForTermination(NState, ?RECEIVE);
	

%% Receive deposit from client
handle_info({{'deposit', ReqId, AccountNum, Amount}, ClientPort}, State) ->
	logger:i_msg("Server ~p : Received deposit from client ~p. Details : ~p~n",[{State#state.myName, State#state.myPort}, ClientPort, {'deposit', ReqId, AccountNum, Amount} ]),
	{Result, PTransObj, NState} = deposit(ReqId, AccountNum, Amount, ?DEPOSIT, State),
	NState1 = sync(Result, ClientPort, AccountNum, PTransObj, NState),
	checkForTermination(NState1, ?RECEIVE);

%% Receive withdraw from client
handle_info({{'withdraw', ReqId, AccountNum, Amount}, ClientPort}, State) ->
	logger:i_msg("Server ~p : Received withdraw from client ~p. Details : ~p~n",[{State#state.myName, State#state.myPort}, ClientPort, {'withdraw', ReqId, AccountNum, Amount}]),
	{Result, PTransObj, NState} = withdraw(ReqId, AccountNum, Amount, ?WITHDRAW, State),
	NState1 = sync(Result, ClientPort, AccountNum, PTransObj, NState),
	checkForTermination(NState1, ?RECEIVE);

%% Receive transfer from client
handle_info({{'transfer', ReqId, AccountNum, Amount, DestBank, DestAccountNum}, ClientPort}, State) ->
	logger:i_msg("Server ~p : Received transfer from client ~p. Details : ~p~n",[{State#state.myName, State#state.myPort}, ClientPort, {'transfer', ReqId, AccountNum, Amount, DestBank, DestAccountNum}]),
	{Result, PTransObj, NState} = withdraw(ReqId, AccountNum, Amount, ?TRANSFERWITHDRAW, State),
	SrcBank = State#state.myName,
	NState1 = sync_transfer(Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, NState),
	checkForTermination(NState1, ?TRANS_WITHDRAW);
	

handle_info(Info, State) ->
    {noreply, State}.


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
	exit(State#state.pingerPid,kill),
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
%% Banking APIs
%% ====================================================================

%% Get balance API
getBalance(ReqId, AccountNum, State) ->
	{Balance, NState}=
		case lists:keyfind(AccountNum, 1, State#state.balanceMap) of
			false ->
				{0, State#state{balanceMap = [{AccountNum, 0} | State#state.balanceMap]}};
			{AccountNum, Bal} ->
				{Bal, State}
		end,
	{{ReqId, ?PROCESSED, AccountNum, Balance}, NState}.

%% Deposit API
deposit(ReqId, AccountNum, Amount, Type, State) ->
	Balance =
		case lists:keyfind(AccountNum, 1, State#state.balanceMap) of
				false ->
					0;
				{AccountNum, Bal} ->
					Bal
		end,
	{Result, ProcessedTrans, NState} =
		case lists:keyfind(ReqId, 1, State#state.processedTransMap) of
			false ->
				BalanceObj = {AccountNum, Balance + Amount},
				TransObj = {ReqId, AccountNum, {Amount, Balance + Amount, ?PROCESSED}, Type},
				BalanceMap = 
					case lists:keyfind(AccountNum, 1, State#state.balanceMap) of
						false ->
							[BalanceObj | State#state.balanceMap];
						_ ->
							lists:keyreplace(AccountNum, 1, State#state.balanceMap, BalanceObj)
					end,
				TransMap = [TransObj | State#state.processedTransMap],
				NS = State#state{balanceMap = BalanceMap, processedTransMap = TransMap},
				{{ReqId, ?PROCESSED, AccountNum, Balance + Amount}, TransObj, NS};
			TransObj ->
				case TransObj of
					{ReqId, AccountNum, {Amount, RepliedBalance, RepliedType}, Type} ->
						{{ReqId, RepliedType, AccountNum, RepliedBalance}, {}, State};
					_ ->
						{{ReqId, ?INCONSISTENT, AccountNum, Balance}, {}, State}
				end
		end,
	{Result, ProcessedTrans, NState}.
					
%% Withdraw API
withdraw(ReqId, AccountNum, Amount, Type, State) ->
	Balance =
		case lists:keyfind(AccountNum, 1, State#state.balanceMap) of
				false ->
					0;
				{AccountNum, Bal} ->
					Bal
		end,
	{Result, ProcessedTrans, NState} =
		case lists:keyfind(ReqId, 1, State#state.processedTransMap) of
			false ->
				if Balance >= Amount ->
					   BalanceObj = {AccountNum, Balance - Amount},
					   TransObj = {ReqId, AccountNum, {Amount, Balance - Amount, ?PROCESSED}, Type},
					   BalanceMap = 
						   case lists:keyfind(AccountNum, 1, State#state.balanceMap) of
							   false ->
								   [BalanceObj | State#state.balanceMap];
							   _ ->
								   lists:keyreplace(AccountNum, 1, State#state.balanceMap, BalanceObj)
						   end,
					   TransMap = [TransObj | State#state.processedTransMap],
					   NS = State#state{balanceMap = BalanceMap, processedTransMap = TransMap},
					   {{ReqId, ?PROCESSED, AccountNum, Balance - Amount}, TransObj, NS};
				   true ->
					   TransObj = {ReqId, AccountNum, {Amount, Balance, ?INSUFFICIENT}, Type},
					   TransMap = [TransObj | State#state.processedTransMap],
					   NS = State#state{processedTransMap = TransMap},
					   {{ReqId, ?INSUFFICIENT, AccountNum, Balance}, TransObj, NS}
				end;
			TransObj ->
				case TransObj of
					{ReqId, AccountNum, {Amount, RepliedBalance, RepliedType}, Type} ->
						{{ReqId, RepliedType, AccountNum, RepliedBalance}, {}, State};
					_ ->
						{{ReqId, ?INCONSISTENT, AccountNum, Balance}, {}, State}
				end
		end,
	{Result, ProcessedTrans, NState}.
				


%% ====================================================================
%% Communication Functions
%% ====================================================================

%% Propagates update to next server ( if available); else send response back to client	
sync(Result, ClientPort, AccountNum, PTransObj, State) ->
	if State#state.succPort /= ?UNDEFINED ->
		   socket_utils:send_async(State#state.succPort, {'sync', Result, ClientPort, AccountNum, PTransObj, State#state.myPort}),
		   SentRequests = 
			   case lists:member({Result, ClientPort, AccountNum, PTransObj}, State#state.sentRequests) of
				   false ->
					   lists:append(State#state.sentRequests, [{Result, ClientPort, AccountNum, PTransObj}]);
				   _ ->
					   State#state.sentRequests
			   end,
%% 		   logger:i_msg("Server ~p : SentRequests while forwarding to successor ~p~n", [{State#state.myName, State#state.myPort}, SentRequests]),
		   State#state{sentRequests = SentRequests};
	   true ->
		   %% Send results to client by dice rool probability to simulate message loss
		   case simulateMsgLoss(State#state.simulate_msg_loss) of
			   true ->
				   logger:i_msg("Server : RESEND Message ~p dropped to simulate message loss~n",[{result, Result}]);
			   false ->
				   socket_utils:send_async(ClientPort, {result, Result})
		   end,
		   %% Sending ack to predecessor, to inform this request is processed
		   if State#state.predPort /= ?UNDEFINED ->
				  socket_utils:send_async_process(State#state.predPort, {'sentRequestsAck',Result, ClientPort, AccountNum, PTransObj}, State#state.ackDelay);
			  true ->
				  ok
		   end,
		   State
	end.

%% Propagates updates to next server or to next bank if tail
sync_transfer(Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, State) ->
	ShallAppendMsg =
		if State#state.succPort /= ?UNDEFINED ->
			   socket_utils:send_async(State#state.succPort, {'syncTransfer', Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, State#state.myPort}),
			   true;
		   true ->
			   ResultType = element(2, Result),
			   if ResultType == ?PROCESSED, PTransObj /= {} ->
					  %% Send the transfer to other bank's head
					  case lists:keyfind(DestBank, 1, State#state.otherBankHTPorts) of
						  {DestBank, DHPort, _} when DHPort /= ?UNDEFINED->
							  socket_utils:send_async(DHPort, {'depositTransfer', Result, ClientPort, AccountNum, SrcBank, DestBank, DestAccountNum, Amount, PTransObj, State#state.myPort}),
							  true;
						  _ ->
							  logger:e_msg("Server ~p : No Dest Bank Head server found for ~p. Will retry sending transfer req..", [{State#state.myName, State#state.myPort}, DestBank]),
							  false
					  end;
				  true ->
					  %% If insufficient balance or inconsistent with history, then send result to client
					  socket_utils:send_async(ClientPort, {result, Result}),
					  if State#state.predPort /= ?UNDEFINED ->
							 socket_utils:send_async(State#state.predPort, {'sentRequestsTransAck',Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj});
						 true ->
							 ok
					  end,
					  false
			   end
		end,
	%% Append the transfer request to sentRequests
	SentTransfers = 
		case lists:member({Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}, State#state.sentRequests) of
			false ->
				if ShallAppendMsg ->
					   lists:append(State#state.sentRequests, [{Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}]);
				   true ->
					   State#state.sentRequests
				end;
			_ ->
				State#state.sentRequests
		end,
%% 	logger:i_msg("Server ~p : SentTransfers while forwarding to successor/ dest bank head ~p~n", [{State#state.myName, State#state.myPort}, SentTransfers]),
	State#state{sentRequests = SentTransfers}.
	
sync_deposit(Result, ClientPort, SrcBank, SrcAckMsg, DestAccountNum, PTransObj, State) ->
	SentDeposits =
		if State#state.succPort /= ?UNDEFINED ->
			   socket_utils:send_async(State#state.succPort, {'syncDeposit', Result, ClientPort, SrcBank, SrcAckMsg, DestAccountNum, PTransObj, State#state.myPort}),
			   case lists:member({Result, ClientPort, DestAccountNum, PTransObj}, State#state.sentRequests) of
				   false ->
					   lists:append(State#state.sentRequests, [{Result, ClientPort, DestAccountNum, PTransObj}]);
				   _ ->
					   State#state.sentRequests
			   end;
		   true ->
			   %% Send result to client
			   SrcResult = element(2,SrcAckMsg),
			   socket_utils:send_async(ClientPort,{result, SrcResult}),
			   %% Send ack to src bank tail
			   case lists:keyfind(SrcBank, 1, State#state.otherBankHTPorts) of
				   {SrcBank, _, STailPort} ->
					   %% Format of SrcMsg = {'sentRequestsTransAck',....}
					   socket_utils:send_async_process(STailPort, SrcAckMsg, State#state.ackDelay);
				   _ ->
					   ok
			   end,
			   %% Send ack to my predecessor
			   if State#state.predPort /= ?UNDEFINED->
					  socket_utils:send_async(State#state.predPort, {'sentRequestsDepositAck', Result, ClientPort, DestAccountNum, PTransObj});
				  true ->
					  ok
			   end,
			   State#state.sentRequests
		end,
%% 	logger:i_msg("Server ~p : SentDeposits while forwarding to successor ~p~n", [{State#state.myName, State#state.myPort}, SentDeposits]),
	State#state{sentRequests = SentDeposits}.
		   
%% Update the balance and transaction object received from predecessor
updateBalanceAndTransactionMaps(AccountNum, Result, PTransObj, State) ->
	State1 =
		case Result of
			{_,TransType , AccountNum, Balance} when TransType == ?PROCESSED, PTransObj /= {} ->
				BalanceObj = {AccountNum, Balance},
				BalanceMap = 
					case lists:keyfind(AccountNum, 1, State#state.balanceMap) of
						false ->
							[BalanceObj | State#state.balanceMap];
						_ ->
							lists:keyreplace(AccountNum, 1, State#state.balanceMap, BalanceObj)
					end,
%% 				logger:i_msg("Balance Map ~p~n", [BalanceMap]),
				State#state{balanceMap = BalanceMap};
			_ ->
				State
		end,
	if PTransObj /= {} ->
		   ReqId = element(1, PTransObj),
		   TransMap = 
			   case lists:keyfind(ReqId, 1, State1#state.processedTransMap) of
				   false ->
					   [PTransObj | State1#state.processedTransMap];
				   _ ->
					   State1#state.processedTransMap
			   end,
		   State1#state{processedTransMap = TransMap};
	   true ->
		   State1
	end.

%% Retransmit transfers on my bank's old tail failure or new tail extension
takeTailTransferResendAction(State) ->
	Fun =
		fun({Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}) ->
				%% Need not get the out state from sync_transfer, as duplicate entries will not be added
				sync_transfer(Result, ClientPort, AccountNum, State#state.myName, DestBank, DestAccountNum, Amount, PTransObj, State);
		   (_) ->
				ok
		end,
	lists:foreach(Fun, State#state.sentRequests).

%% Retransmit transfers on my on my dest bank's head failure
takeTailTransferResendAction(DestinationBank, State) ->
	Fun =
		fun({Result, ClientPort, AccountNum, DestBank, DestAccountNum, Amount, PTransObj}) ->
				if DestinationBank == DestBank ->
					   %% Need not get the out state from sync_transfer, as duplicate entries will not be added
					   sync_transfer(Result, ClientPort, AccountNum, State#state.myName, DestBank, DestAccountNum, Amount, PTransObj, State);
				   true ->
					   ok
				end;
		   (_) ->
				ok
		end,
	lists:foreach(Fun, State#state.sentRequests).

%% periodically ping the master
pingMaster(MasterPort, MyName, MyPort) ->
	socket_utils:send_async(MasterPort, {'ping', MyName, MyPort}),
	sleep(1000),
	pingMaster(MasterPort, MyName, MyPort).

%% Decides if a request has to be retransmitted based on dice roll probability
simulateMsgLoss(SimulateMsgLoss) ->
	if SimulateMsgLoss ->
		   DiceToss = random:uniform(6),
		   if DiceToss == 1 ->
				  true;
			  true ->
				  false
		   end;
	   true ->
		   false
	end.

%% ====================================================================
%% Socket Functions
%% ====================================================================

process(Socket, Data, SPid) ->
	SPid ! binary_to_term(Data).


%% Util Functions

sleep(Ms) ->
	timer:sleep(Ms).

%% check whether to terminate or not based on the crash counter
checkForTermination(State, Event) ->
	case State#state.crashType of
		{?RECEIVE, N} when Event == ?RECEIVE ; Event == {?SEND,?RECEIVE}->
			if State#state.msgRecvCtr rem 10 == 0 ->
				   logger:e_msg("Server ~p : Counter State : ~p~n ",[{State#state.myName, State#state.myPort},State#state.msgRecvCtr]);
			   true ->
				   ok
			end,
			if State#state.msgRecvCtr+1 == N ->
				   logger:e_msg("Server ~p : Terminating... Recvd msg limit exceeded ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{msgRecvCtr = State#state.msgRecvCtr+1}}
			end;
		{?SEND, N} when Event == ?SEND ; Event == {?SEND,?RECEIVE}->
			if State#state.msgSentCtr rem 10 == 0 ->
				   logger:e_msg("Server ~p : Counter State : ~p~n ",[{State#state.myName, State#state.myPort},State#state.msgSentCtr]);
			   true ->
				   ok
			end,
			if State#state.msgSentCtr+1 == N ->
				   logger:e_msg("Server ~p : Terminating... Sent msg limit exceeded ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{msgSentCtr = State#state.msgSentCtr+1}}
			end;
		{?RECEIVE_FAIL, N} when Event == ?RECEIVE_FAIL ->
			if State#state.failMsgRecvCtr+1 == N ->
				  logger:e_msg("Server ~p : Terminating... Failure receive msg limit exceeded ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{failMsgRecvCtr = State#state.failMsgRecvCtr+1}} 
			end;
		{?RECEIVE_EXT, N} when Event == ?RECEIVE_EXT ->
			%% Make use of failMsgRecvCtr counter
			if State#state.failMsgRecvCtr+1 == N ->
				  logger:e_msg("Server ~p : Terminating... Ext receive msg limit exceeded ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{failMsgRecvCtr = State#state.failMsgRecvCtr+1}} 
			end;
		{?TRANS_WITHDRAW, N} when Event == ?TRANS_WITHDRAW ->
			%% Make use of failMsgRecvCtr counter
			if State#state.failMsgRecvCtr+1 == N ->
				  logger:e_msg("Server ~p : Terminating... Transfer withdraw limit exceeded ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{failMsgRecvCtr = State#state.failMsgRecvCtr+1}} 
			end;
		{?TRANS_DEPOSIT, N} when Event == ?TRANS_DEPOSIT ->
			%% Make use of failMsgRecvCtr counter
			if State#state.failMsgRecvCtr rem 5 == 0 ->
				   logger:e_msg("Server ~p : Trans Deposit Counter State : ~p~n ",[{State#state.myName, State#state.myPort},State#state.failMsgRecvCtr]);
			   true ->
				   ok
			end,
			if State#state.failMsgRecvCtr+1 == N ->
				  logger:e_msg("Server ~p : Terminating... Transfer deposit limit exceeded ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{failMsgRecvCtr = State#state.failMsgRecvCtr+1}} 
			end;
		{?HEAD_TAIL_CRASH, N} when Event == ?TRANS_DEPOSIT ->
			%% Make use of failMsgRecvCtr counter
			if State#state.failMsgRecvCtr rem 5 == 0 ->
				   logger:e_msg("Server ~p : Head Tail Crash Counter State : ~p~n ",[{State#state.myName, State#state.myPort},State#state.failMsgRecvCtr]);
			   true ->
				   ok
			end,
			if State#state.failMsgRecvCtr+1 == N ->
				  logger:e_msg("Server ~p : Terminating... Head terminating in head tail crash scenario ~n", [{State#state.myName, State#state.myPort}]),
				   {stop, normal, State};
			   true ->
				   {noreply, State#state{failMsgRecvCtr = State#state.failMsgRecvCtr+1}} 
			end;
		_ ->
			{noreply, State}
	end.
				