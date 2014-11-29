
-module(server_chain_manager).

%% ====================================================================
%% API functions
%% ====================================================================
-export([createServerChain/1]).



%% ====================================================================
%% Internal functions
%% ====================================================================

% N- Total servers, PredPort
%% creates the tail server
createServerChain({1,BankName,MasterPort,ServerCrashTypeList,SimulateAckDelay,SimulateMsgLoss}, PredPort) ->
	CrashType = lists:nth(length(ServerCrashTypeList), ServerCrashTypeList),
	case server:start([{bankname, BankName},{masterport, MasterPort},{crashtype, CrashType},{ackDelay, SimulateAckDelay},{simulate_msg_loss,SimulateMsgLoss}]) of
		MyPort when is_integer(MyPort)->
			socket_utils:send_async(MyPort, {'setPredecessor', PredPort}),
			socket_utils:send_async(MyPort, {'setSuccessor', undefined}),
			socket_utils:send_async(MasterPort, {'registerPredSucc', BankName, MyPort, PredPort, undefined}),
			{result, MyPort, MyPort, []};
		Error ->
			Error
	end;

%% creates nth server in the chain
createServerChain({N,BankName, MasterPort,ServerCrashTypeList,SimulateAckDelay,SimulateMsgLoss}, PredPort) ->
	CrashType = lists:nth(length(ServerCrashTypeList)-N+1, ServerCrashTypeList),
	case server:start([{bankname, BankName},{masterport, MasterPort},{crashtype, CrashType},{ackDelay, SimulateAckDelay},{simulate_msg_loss,SimulateMsgLoss}]) of
		MyPort when is_integer(MyPort)->
			case createServerChain({N-1,BankName, MasterPort,ServerCrashTypeList,SimulateAckDelay,SimulateMsgLoss}, MyPort) of
				{result, SuccPort, TailPort, MidPortChain} ->
					socket_utils:send_async(MyPort, {'setPredecessor', PredPort}),
					socket_utils:send_async(MyPort, {'setSuccessor', SuccPort}),
					socket_utils:send_async(MasterPort, {'registerPredSucc', BankName, MyPort, PredPort, SuccPort}),
					NMidPortChain = 
						case PredPort of
							undefined ->
								MidPortChain;
							_ ->
								[MyPort|MidPortChain]
						end,
					{result, MyPort, TailPort, NMidPortChain};
				SError ->
					SError
			end;
		Error ->
			Error
	end.

%% initiates server chain creation
createServerChain({N,BankName, MasterPort,ServerCrashTypeList,SimulateAckDelay,SimulateMsgLoss}) ->
	createServerChain({N,BankName, MasterPort,ServerCrashTypeList,SimulateAckDelay,SimulateMsgLoss}, undefined).

