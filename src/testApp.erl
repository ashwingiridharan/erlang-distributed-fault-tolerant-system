
-module(testApp).

%% ====================================================================
%% API functions
%% ====================================================================
-export([testChain/2, testChain/1, exit/0]).
-include("macro_utils.hrl").

testChain(EnvPath, ConfigFile) ->
	testChain1(EnvPath, ConfigFile).

testChain(ConfigFile) ->
	EnvPath = "C://Users//PearlWin//indigospace3//ChainReplTransfer",
	testChain1(EnvPath, ConfigFile).

testChain1(EnvPath, ConfigFile) ->
	
	Config = config_utils:loadConfig(EnvPath, ConfigFile),
	ClientReqDelay = config_utils:getConfigVal(client_req_delay, Config, 2000),
	BankDetails = config_utils:getConfigVal(bank_details, Config, []),
	SimulateAckDelay = config_utils:getConfigVal(simulate_ack_delay, Config, 0),
	SimulateMsgLoss = config_utils:getConfigVal(simulate_msg_loss, Config, false),
	ExtTailFailure = config_utils:getConfigVal(ext_tail_failure, Config, false),
	
	
	logger:start(EnvPath, ConfigFile),
	
	logger:i_msg("Simulate Msg loss ~p ~n",[SimulateMsgLoss]),
	case master:start([{ext_tail_failure, ExtTailFailure}]) of
		MPortNo when is_integer(MPortNo) ->
			CreateBanksAndClients =
				fun({BankName, ServerChainCount, ClientCount, ServerCrashTypeList}) ->
						case server_chain_manager:createServerChain({ServerChainCount, BankName, MPortNo, ServerCrashTypeList,SimulateAckDelay,SimulateMsgLoss}) of
							{result, HeadPort, TailPort, MidPortChain} ->
								logger:i_msg("ServerManager : The initial server chain for bank ~p : ~p~n", [BankName, {HeadPort, MidPortChain,TailPort}]),
								%% Servers registration to master
								socket_utils:send_async(MPortNo, {'registerServer', BankName, HeadPort, ?HEAD}),
								socket_utils:send_async(MPortNo, {'registerServer', BankName, TailPort, ?TAIL}),
								MidServReg =
									fun(MidPort) ->
											socket_utils:send_async(MPortNo, {'registerServer', BankName, MidPort, ?MID})
									end,
								lists:foreach(MidServReg, MidPortChain),
								
								CreateClients =
									fun(Id) ->
											case client:start([{bankname,BankName},{head, HeadPort},{tail, TailPort},{id,Id}]) of
												CPortNo when is_integer(CPortNo)->
													socket_utils:send_async(MPortNo, {'registerClient', BankName, CPortNo}),
													socket_utils:send_async(CPortNo, {'perform_trans', CPortNo, ClientReqDelay, Config});
												_ ->
													{error, client_startup_failed}
											end
									end,
								lists:foreach(CreateClients, lists:seq(1, ClientCount));
							_ ->
								{error, server_chain_creation_failed}
						end
				end,
			lists:foreach(CreateBanksAndClients, BankDetails),
			socket_utils:send_async(MPortNo, 'broadcastBankHeadTailInfo');
		_ ->
			{error, master_creation_failed}
	end.
			
	
									
sleep(Ms) ->
	timer:sleep(Ms).

testJson() ->
	MyTup = {{"name",["djdjdj","fjshfhjshfjh"]}, {"xyzghgh", "fgfg"}},
	Encoded = term_to_binary(MyTup),
	binary_to_term(Encoded).


exit() ->
	erlang:exit(self(), kill).
