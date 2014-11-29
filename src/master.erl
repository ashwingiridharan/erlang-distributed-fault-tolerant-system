
-module(master).
-behaviour(gen_server).
-export([start/1, startLink/1, process/3, checkForFailedServers/1, checkForChainLength/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ====================================================================
%% API functions
%% ====================================================================
-include("macro_utils.hrl").


%% ====================================================================
%% Behavioural functions 
%% ====================================================================
-record(state, {bankServersPingMap =[], bankHeadTailMap=[], bankClientsMap=[], bankPredSuccMap=[], myPort, ext_tail_failure=false}).


startLink(Args) ->
	gen_server:start_link(master, [Args], []).

start(Args) ->
	socket_utils:start([{module,?MODULE}|Args]).

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
init([Args]) ->
	{port, MyPort} = lists:keyfind(port, 1, Args),
	{ext_tail_failure, ExtTailFailure} = lists:keyfind(ext_tail_failure, 1, Args),
	spawn(?MODULE, checkForFailedServers, [self()]),
	spawn(?MODULE, checkForChainLength, [self(), 15000]),
    {ok, #state{myPort=MyPort, ext_tail_failure=ExtTailFailure}}.
	


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
%% server registers itself with master
handle_info({'registerServer', BankName, ServerPort, ServerType}, State) ->
	BankHeadTailMap = updateBankHeadTailMap(State, BankName, ServerPort, ServerType),
	BankServersPingMap = updateBankServersPingMap(State, BankName, ServerPort),
	NState = State#state{bankHeadTailMap=BankHeadTailMap, bankServersPingMap=BankServersPingMap},
	logger:i_msg("Master : Registration from server ~p New State : ~p~n", [{BankName, ServerPort, ServerType}, {BankHeadTailMap,BankServersPingMap}]),
	{noreply, NState};

%% client registers itself with master
handle_info({'registerClient', BankName, ClientPort}, State) ->	
	BankClientsMap = updateBankClientsMap(State, BankName, ClientPort),
	{noreply, State#state{bankClientsMap=BankClientsMap}};

%% servers registers its pred and succ with master
handle_info({'registerPredSucc', BankName, ServerPort, PredPort, SuccPort}, State) ->
	BankPredSuccMap = updateBankPredSuccMap(State, BankName, ServerPort, PredPort, SuccPort),
	logger:i_msg("Master : Pred Succ Registration from server ~p New State : ~p~n", [{BankName, ServerPort, PredPort, SuccPort}, BankPredSuccMap]),
	{noreply, State#state{bankPredSuccMap=BankPredSuccMap}};

%% receives perioding keep-alive messages from servers
handle_info({'ping', BankName, ServerPort}, State) ->
	BankServersPingMap = updateBankServersPingMap(State, BankName, ServerPort),
%% 	logger:i_msg("Master : Received ping from bank server ~p. Ping Map : ~p~n", [{BankName, ServerPort}, BankServersPingMap]),
	logger:i_msg("Master : Received ping from bank server ~p~n", [{BankName, ServerPort}]),
	{noreply, State#state{bankServersPingMap=BankServersPingMap}};

%% check for existence of failed servers and trigger server failure action
handle_info('checkForFailedServers',State) ->
	BankServersPingMap = State#state.bankServersPingMap,
	NowSec = getTimeStampInSec(),
	BankIterFun =
		fun({{BankName, ServerPort},TS}, AccStateIn) ->
				if NowSec - TS >= 5 ->
					   AccStateOut = takeServerFailureAction(BankName, ServerPort, AccStateIn),
					   AccStateOut;
				   true ->
					   AccStateIn
				end
		end,
	NewState = lists:foldl(BankIterFun, State, BankServersPingMap),
	{noreply, NewState};

%% check if server chain length is beyond threshold and trigger extend chain action
handle_info('checkForChainLength', State) ->
	BankIterFun =
		fun({BankName,_}) ->
				ChainCount = getBankChainLength(BankName, State#state.bankServersPingMap),
				if ChainCount =< ?CHAIN_THRESHOLD ->
					   extendServerChain(State, BankName);
				   true ->
					   ok
				end
		end,
	lists:foreach(BankIterFun, State#state.bankHeadTailMap),
	{noreply, State};

%% S+ informs master to send sentRequests index to S-, when S crashes 
handle_info({'respHandlePredCrash', SentRequestsLen, NewPred, NewSucc}, State) ->
	socket_utils:send_async(NewPred, {'handleSuccCrash', SentRequestsLen, NewSucc}),
	{noreply, State};

%% Final phase for chain extension. Master reconfigures chain with new tail and informs the client  
handle_info({'ackSetBalanceAndTransMap',{BankName, CurrTail, NewTail, _Master}}, State) ->
	logger:i_msg("Master : EXTENDCHAIN Chain extension successful. Reconfiguring Server Chain and Updating master maps for ~p ~n", [BankName]),
	%% Inform CurrTail about its new successor and ask it to sync the sent requests
	socket_utils:send_async(CurrTail,  {'setSuccessor', NewTail}),
	
	%% Update Master's Maps
	NewBankPingMap = updateBankServersPingMap(State, BankName, NewTail),
	NewBankHTMap = updateBankHeadTailMap(State, BankName, NewTail, ?TAIL),
	{{BankName,CurrTail}, CurrTailPred, _} = lists:keyfind({BankName,CurrTail}, 1, State#state.bankPredSuccMap),
	NewPredSuccMap = updateBankPredSuccMap(State, BankName, CurrTail, CurrTailPred, NewTail),
	NewPredSuccMap1 = updateBankPredSuccMap(State#state{bankPredSuccMap=NewPredSuccMap}, BankName, NewTail, CurrTail, ?UNDEFINED),
	
	logger:i_msg("Master : EXTENDCHAIN Chain extension successful. Updated Master Maps BHTM : ~p, BPSM : ~p ~n", [NewBankHTMap, NewPredSuccMap]),

	%% Bank's client should be informed about the new tail, once the old tail forwards all the updates to new tail
	case lists:keyfind(BankName, 1, State#state.bankClientsMap) of
		false ->
			ok;
		{BankName, ClientPortList} ->
			ClientNotifyFun =
				fun(ClientPort) ->
						socket_utils:send_async(ClientPort, {'tail', NewTail})
				end,
			lists:foreach(ClientNotifyFun, ClientPortList)
	end,
	
	FinState = State#state{bankServersPingMap=NewBankPingMap, bankHeadTailMap=NewBankHTMap, bankPredSuccMap=NewPredSuccMap1},
	
	logger:i_msg("Master : EXTENDCHAIN Chain extended for ~p with addition of ~p at tail. State : ~p~n", [BankName, NewTail, FinState]),
	
	{noreply, FinState};

handle_info('broadcastBankHeadTailInfo', State) ->
	broadcastBankHeadTailInfo(State#state.bankHeadTailMap, State#state.bankServersPingMap, 5000),
	{noreply, State};

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
%% Internal functions
%% ====================================================================

%% updates bank's head tail map
updateBankHeadTailMap(State, BankName, ServerPort, ServerType) ->
	case lists:keyfind(BankName, 1, State#state.bankHeadTailMap) of
		false ->
			case ServerType of
				?HEAD ->
					[{BankName,{ServerPort, ?UNDEFINED}} | State#state.bankHeadTailMap];
				?TAIL ->
					[{BankName,{?UNDEFINED, ServerPort}} | State#state.bankHeadTailMap];
				_ ->
					State#state.bankHeadTailMap
			end;
		{BankName, {OldHeadPort, OldTailPort}} ->
			case ServerType of
				?HEAD ->
					lists:keyreplace(BankName, 1, State#state.bankHeadTailMap, {BankName,{ServerPort, OldTailPort}});
				?TAIL ->
					lists:keyreplace(BankName, 1, State#state.bankHeadTailMap, {BankName,{OldHeadPort, ServerPort}});
				_ ->
					State#state.bankHeadTailMap
			end
	end.

%% updates bank server's pred succ map
updateBankPredSuccMap(State, BankName, ServerPort, PredPort, SuccPort) ->
	case lists:keyfind({BankName, ServerPort}, 1, State#state.bankPredSuccMap) of
		false ->
			[{{BankName, ServerPort},PredPort, SuccPort} | State#state.bankPredSuccMap];
		_ ->
			lists:keyreplace({BankName, ServerPort}, 1, State#state.bankPredSuccMap, {{BankName, ServerPort},PredPort, SuccPort})
	end.

%% updates bank server's ping map
updateBankServersPingMap(State, BankName, ServerPort) ->
	case lists:keyfind({BankName,ServerPort}, 1, State#state.bankServersPingMap) of
		false ->
			[{{BankName,ServerPort}, getTimeStampInSec()} | State#state.bankServersPingMap];
		{{BankName,ServerPort}, _} ->
			lists:keyreplace({BankName,ServerPort}, 1, State#state.bankServersPingMap, {{BankName,ServerPort}, getTimeStampInSec()})
	end.

%% update client list for a given bank
updateBankClientsMap(State, BankName, ClientPort) ->
	case lists:keyfind(BankName, 1, State#state.bankClientsMap) of
		false ->
			[{BankName,[ClientPort]} | State#state.bankClientsMap];
		{BankName, ClientList} ->
			case lists:member(ClientPort, ClientList) of
				false ->
					lists:keyreplace(BankName, 1, State#state.bankClientsMap, {BankName, [ClientPort|ClientList]});
				_ ->
					State#state.bankClientsMap
			end
	end.

%% take server failure action for head crash, tail crash, mid server crash
takeServerFailureAction(BankName, FailedServerPort, AccStateIn) ->
	case lists:keyfind(BankName, 1, AccStateIn#state.bankHeadTailMap) of
		false ->
			AccStateIn;
		{BankName,{FailedServerPort,TailPort}} ->
			
			logger:e_msg("Master: Bank's Head ~p crash detected. State BEFORE recovery BHTM : ~p , BPM : ~p, BPSM ~p~n", 
						 [{BankName,FailedServerPort}, AccStateIn#state.bankHeadTailMap, AccStateIn#state.bankServersPingMap,
						  AccStateIn#state.bankPredSuccMap]),
			
			%% Remove from pingmap
			BankServerPingMap = lists:keydelete({BankName,FailedServerPort}, 1, AccStateIn#state.bankServersPingMap),
			
			%% Get failed server's successor and predecessor. This successor will be new head. 
			{{BankName,FailedServerPort},_,NewHeadPort} = lists:keyfind({BankName,FailedServerPort}, 1, AccStateIn#state.bankPredSuccMap),
			
			%% Delete failed server's entry in bankPredSuccMap
			BankPredSuccMap = lists:keydelete({BankName,FailedServerPort}, 1, AccStateIn#state.bankPredSuccMap),
			
			%% Change New Head's entry. New Head's previous predecessor is current failed server
			{{BankName,NewHeadPort},FailedServerPort,NHeadSucc} = lists:keyfind({BankName,NewHeadPort}, 1, BankPredSuccMap),
			BankPredSuccMap1 = lists:keyreplace({BankName,NewHeadPort}, 1, BankPredSuccMap, {{BankName,NewHeadPort},?UNDEFINED,NHeadSucc}),
			
			%% Inform the new head about the change in its predecessor
			socket_utils:send_async(NewHeadPort, {'setPredecessor', ?UNDEFINED}),
			
			%% Update the bank's head tail map
			BankHeadTailMap = lists:keyreplace(BankName, 1, AccStateIn#state.bankHeadTailMap, {BankName,{NewHeadPort,TailPort}}),
			case lists:keyfind(BankName, 1, AccStateIn#state.bankClientsMap) of
				false ->
					ok;
				{BankName, ClientPortList} ->
					ClientNotifyFun =
						fun(ClientPort) ->
								socket_utils:send_async(ClientPort, {'head', NewHeadPort})
						end,
					lists:foreach(ClientNotifyFun, ClientPortList)
			end,
			
			%% Inform other bank servers about new head
			broadcastBankHeadTailInfo(BankHeadTailMap, BankServerPingMap, 0),
			
			spawn(fun() -> timer:sleep(5000), letAllBankTailsResendTransfersToDestNewHead(BankHeadTailMap, BankName) end),
			
			OutState = AccStateIn#state{bankHeadTailMap=BankHeadTailMap, bankPredSuccMap=BankPredSuccMap1, bankServersPingMap=BankServerPingMap},
			logger:e_msg("Master: Bank's Head ~p crash detected. State AFTER recovery BHTM : ~p , BPM : ~p, BPSM ~p~n", 
						 [{BankName,FailedServerPort}, OutState#state.bankHeadTailMap, OutState#state.bankServersPingMap,
						  OutState#state.bankPredSuccMap]),
			OutState;
			
		
		{BankName,{HeadPort,FailedServerPort}} ->
			
			logger:e_msg("Master: Bank's Tail ~p crash detected. State BEFORE recovery BHTM : ~p , BPM : ~p, BPSM ~p~n", 
						 [{BankName,FailedServerPort}, AccStateIn#state.bankHeadTailMap, AccStateIn#state.bankServersPingMap,
						  AccStateIn#state.bankPredSuccMap]),
			
			%% Remove from pingmap
			BankServerPingMap = lists:keydelete({BankName,FailedServerPort}, 1, AccStateIn#state.bankServersPingMap),
			
			%% Get failed tail's successor and predecessor. This predecessor will be new tail. 
			{{BankName,FailedServerPort},NewTailPort,_} = lists:keyfind({BankName,FailedServerPort}, 1, AccStateIn#state.bankPredSuccMap),
			
			%% Delete failed tail's entry in bankPredSuccMap
			BankPredSuccMap = lists:keydelete({BankName,FailedServerPort}, 1, AccStateIn#state.bankPredSuccMap),
			
			%% Change New tail's entry. New tail's previous successor is current failed server
			{{BankName,NewTailPort},NTailPred,FailedServerPort} = lists:keyfind({BankName,NewTailPort}, 1, BankPredSuccMap),
			BankPredSuccMap1 = lists:keyreplace({BankName,NewTailPort}, 1, BankPredSuccMap, {{BankName,NewTailPort}, NTailPred, ?UNDEFINED}),
			
			%% Inform the new tail about the change in its successor
			socket_utils:send_async(NewTailPort, {'setSuccessor', ?UNDEFINED}),
			
			%% Update the bank's head tail map
			BankHeadTailMap = lists:keyreplace(BankName, 1, AccStateIn#state.bankHeadTailMap, {BankName,{HeadPort,NewTailPort}}),
			
			%% Inform the bank's client about the new tail
			case lists:keyfind(BankName, 1, AccStateIn#state.bankClientsMap) of
				false ->
					ok;
				{BankName, ClientPortList} ->
					ClientNotifyFun =
						fun(ClientPort) ->
								socket_utils:send_async(ClientPort, {'tail', NewTailPort})
						end,
					lists:foreach(ClientNotifyFun, ClientPortList)
			end,
			
			%% Inform the new tail to take new tail actions - Pop and delegate sent requests
			socket_utils:send_async(NewTailPort, 'takeNewTailAction'),
			
			%% Inform other bank servers about new head
			broadcastBankHeadTailInfo(BankHeadTailMap, BankServerPingMap, 0),
			
			%% Ask the new tail to resend its transfer requests
			spawn(fun() -> timer:sleep(5000), socket_utils:send_async(NewTailPort, 'takeTailTransferResendAction') end),
			
			OutState = AccStateIn#state{bankHeadTailMap=BankHeadTailMap, bankPredSuccMap=BankPredSuccMap1, bankServersPingMap=BankServerPingMap},
			logger:e_msg("Master: Bank's Tail ~p crash detected. State AFTER recovery BHTM : ~p , BPM : ~p, BPSM ~p~n", 
						 [{BankName,FailedServerPort}, OutState#state.bankHeadTailMap, OutState#state.bankServersPingMap,
						  OutState#state.bankPredSuccMap]),
			OutState;
		_ ->
			logger:e_msg("Master: Bank's Mid Server ~p crash detected. State BEFORE recovery BHTM : ~p , BPM : ~p, BPSM ~p~n", 
						 [{BankName,FailedServerPort}, AccStateIn#state.bankHeadTailMap, AccStateIn#state.bankServersPingMap,
						  AccStateIn#state.bankPredSuccMap]),
			
			%% Remove from pingmap
			BankServerPingMap = lists:keydelete({BankName,FailedServerPort}, 1, AccStateIn#state.bankServersPingMap),
			
			%% Get failed server's successor and predecessor. Delete after it
			{{BankName,FailedServerPort}, FailedSerPred, FailedServerSucc} = lists:keyfind({BankName,FailedServerPort}, 1, AccStateIn#state.bankPredSuccMap),
			BankPredSuccMap = lists:keydelete({BankName,FailedServerPort}, 1, AccStateIn#state.bankPredSuccMap),
			
			%% Update Pred Succ Map for failed server's predecessor and successor
			{{BankName,FailedSerPred}, FPP, FailedServerPort} = lists:keyfind({BankName,FailedSerPred}, 1, BankPredSuccMap),
			{{BankName,FailedServerSucc}, FailedServerPort, FSS} = lists:keyfind({BankName,FailedServerSucc}, 1, BankPredSuccMap),
			BankPredSuccMap1 = lists:keyreplace({BankName,FailedSerPred}, 1, BankPredSuccMap, {{BankName,FailedSerPred},FPP,FailedServerSucc}),
			BankPredSuccMap2 = lists:keyreplace({BankName,FailedServerSucc}, 1, BankPredSuccMap1, {{BankName,FailedServerSucc},FailedSerPred,FSS}),
	
			%% Inform FailedSerPred and FailedServerSucc about new neighbours
			socket_utils:send_async(FailedSerPred,  {'setSuccessor', FailedServerSucc}),
			socket_utils:send_async(FailedServerSucc,  {'setPredecessor', FailedSerPred}),
			
			%% Handle sent requests inconsistency
			socket_utils:send_async(FailedServerSucc, {'handlePredCrash',FailedSerPred}),
			
			OutState = AccStateIn#state{bankPredSuccMap=BankPredSuccMap2, bankServersPingMap=BankServerPingMap},
			logger:e_msg("Master: Bank's Mid Server ~p crash detected. Partial State AFTER recovery BHTM : ~p , BPM : ~p, BPSM ~p~n", 
						 [{BankName,FailedServerPort}, OutState#state.bankHeadTailMap, OutState#state.bankServersPingMap,
						  OutState#state.bankPredSuccMap]),
			OutState
	end.


getTimeStampInSec() ->
	{Meg, Sec, _} = now(),
	Meg*1000000 + Sec.

process(Socket, Data, SPid) ->
	SPid ! binary_to_term(Data).

%%check for failed servers
checkForFailedServers(MasterPid) ->
	timer:sleep(5000),
	MasterPid ! 'checkForFailedServers',
	checkForFailedServers(MasterPid).

%%check for chain length consistency
checkForChainLength(MasterPid, Delay) ->
	timer:sleep(Delay),
	MasterPid ! 'checkForChainLength',
	checkForChainLength(MasterPid, 5000).

%% Extend server chain when chain length reduces beyond threshold
extendServerChain(State, BankName) ->
	logger:i_msg("Master : Extending chain for the bank ~p~n",[BankName]),
	{BankName, {_, CurrTail}} = lists:keyfind(BankName, 1, State#state.bankHeadTailMap),
	CrashType = 
		case State#state.ext_tail_failure of
			true ->
				{?RECEIVE, 1};
			_ ->
				?UNBOUNDED
		end,
	case server:start([{bankname, BankName},{masterport, State#state.myPort},{crashtype, CrashType},{ackDelay, 0},{simulate_msg_loss,false}]) of
		NewTail when is_integer(NewTail)->
			
			%% Inform the new tail about their new Pred Succ
			%% Old tail info will be updated only after the update propagation ack receival
			socket_utils:send_async(NewTail,  {'setPredecessor', CurrTail}),
			socket_utils:send_async(NewTail,  {'setSuccessor', ?UNDEFINED}),
			
			%% Inform currtail about its lost tail status and forward all the sentRequests to new tail
			socket_utils:send_async(CurrTail,  {'takeOldTailAction', {BankName, CurrTail, NewTail, State#state.myPort}}),
			
			%% Inform other bank servers about new head
			broadcastBankHeadTailInfo(State#state.bankHeadTailMap, State#state.bankServersPingMap, 0),
			
			%% Inform currtail about its lost status and forward all the sentTransfer requests to new tail
			spawn(fun() -> timer:sleep(5000), socket_utils:send_async(CurrTail, 'takeTailTransferResendAction') end),
			
			%% Further flows between Servers and Masters
			%% Master to CurrTail -> takeOldTailAction
			%% CurrTail to NewTail -> setBalanceAndTransMap
			%% NewTail to Master -> ackSetBalanceAndTransMap = Update Master maps, set successor and inform clients
			
			State;
		_ ->
			logger:e_msg("Master : Chain extension failed for bank ~p~n", [BankName]),
			State
	end.

%% returns chain length of a given bank
getBankChainLength(BankName, BankPingMap) ->
	CountFun =
		fun({{BName,_},_}, CountIn) ->
				if BankName == BName ->
					   CountIn + 1;
				   true ->
					   CountIn
				end
		end,
	CountOut = lists:foldl(CountFun, 0, BankPingMap),
	CountOut.
			
broadcastBankHeadTailInfo(BankHeadTailMap, BankServersPingMap, Delay) ->
	if Delay > 0->
		   timer:sleep(Delay);
	   true ->
		   ok
	end,
	Fun=
		fun({BankName, {Head, Tail}}) ->
				Fun1 =
					fun({{Bank, ServerPort},_}) ->
							if Bank /= BankName ->
								   socket_utils:send_async(ServerPort, {'setOtherBankHead', BankName, Head}),
								   socket_utils:send_async(ServerPort, {'setOtherBankTail', BankName, Tail});
							   true ->
								   ok
							end
					end,
				lists:foreach(Fun1, BankServersPingMap)
		end,
	lists:foreach(Fun, BankHeadTailMap).

letAllBankTailsResendTransfersToDestNewHead(BankHeadTailMap, FailedHeadBankName) ->
	Fun=
		fun({BankName, {_, Tail}}) ->
				if BankName /= FailedHeadBankName ->
					   socket_utils:send_async(Tail, {'takeTailTransferResendAction', FailedHeadBankName});
				   true ->
					   ok
				end
		end,
	lists:foreach(Fun, BankHeadTailMap).
	
