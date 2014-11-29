
-module(config_utils).

%% ====================================================================
%% API functions
%% ====================================================================
-export([loadConfig/1, loadConfig/2, getConfigVal/3]).



%% ====================================================================
%% Internal functions
%% ====================================================================

loadConfig(Path) ->
	file:set_cwd(Path),
	{ok, CurrDir} = file:get_cwd(),
	{ok, Config} = file:consult(CurrDir ++ "//config//chain_app.cfg"),
	Config.

loadConfig(Path, Name) ->
	file:set_cwd(Path),
	{ok, CurrDir} = file:get_cwd(),
	{ok, Config} = file:consult(CurrDir ++ "//config//" ++ Name ++ ".cfg"),
	Config.

getConfigVal(Key, Config, Default) ->
	case lists:keyfind(Key, 1, Config) of
		{_, Val} ->
			Val;
		false ->
			Default
	end.

test1() ->
	[{"citi.1",{now, 12, 0.1, 0.5, 0.4}},
	 {"citi.2",{now, 12, 0.1, 0.5, 0.4}},
	 {"citi.3",{now, 12, 0.1, 0.5, 0.4}},
	 {"tfcu.1",{now, 12, 0.1, 0.5, 0.4}},
	 {"tfcu.2",{now, 12, 0.1, 0.5, 0.4}},
	 {"tfcu.3",{now, 12, 0.1, 0.5, 0.4}},
	 {"hdfc.1",{now, 12, 0.1, 0.5, 0.4}},
	 {"hdfc.2",{now, 12, 0.1, 0.5, 0.4}},
	 {"hdfc.3",{now, 12, 0.1, 0.5, 0.4}}
	].

test() ->
	[
	 {"citi.1",[{'getBalance', "citi.1.1", "accciti1"},
				{'deposit', "citi.1.2", "accciti1", 1000},
				{'withdraw', "citi.1.3", "accciti1", 5000},
				{'withdraw', "citi.1.4", "accciti1", 500},
				{'getBalance', "citi.1.5", "accciti1"}
			   ]},
	 {"citi.2",[{'getBalance', "citi.2.1", "accciti2"},
				{'deposit', "citi.2.2", "accciti2", 10000},
				{'withdraw', "citi.2.3", "accciti2", 5000},
				{'withdraw', "citi.2.3", "accciti2", 5000},
				{'getBalance', "citi.2.1", "accciti2"}
			   ]},
	 {"citi.3", [{'getBalance', "citi.3.1", "accciti3"},
				 {'deposit', "citi.3.1", "accciti3", 1400},
				 {'withdraw', "citi.3.2", "accciti3", 400},
				 {'withdraw', "citi.3.2", "accciti3", 1100},
				 {'getBalance', "citi.3.3", "accciti3"}
				]},
	 {"tfcu.1",[{'getBalance', "tfcu.1.1", "acctfcu1"},
				{'deposit', "tfcu.1.2", "acctfcu1", 3000},
				{'withdraw', "tfcu.1.3", "acctfcu1", 5000},
				{'withdraw', "tfcu.1.4", "acctfcu1", 1000},
				{'getBalance', "tfcu.1.5", "acctfcu1"}
			   ]},
	 {"tfcu.2",[{'getBalance', "tfcu.2.1", "acctfcu2"},
				{'deposit', "tfcu.2.2", "acctfcu2", 8000},
				{'withdraw', "tfcu.2.3", "acctfcu2", 8000},
				{'withdraw', "tfcu.2.3", "acctfcu2", 8000},
				{'getBalance', "tfcu.2.1", "acctfcu2"}
			   ]},
	 {"tfcu.3",[{'getBalance', "tfcu.3.1", "acctfcu3"},
				{'deposit', "tfcu.3.1", "acctfcu3", 400},
				{'withdraw', "tfcu.3.2", "acctfcu3", 20},
				{'withdraw', "tfcu.3.2", "acctfcu3", 381},
				{'getBalance', "tfcu.3.3", "acctfcu3"}
			   ]},
	 {"hdfc.1",[{'getBalance', "hdfc.1.1", "acchdfc1"},
				{'deposit', "hdfc.1.2", "acchdfc1", 1},
				{'withdraw', "hdfc.1.3", "acchdfc1", 1},
				{'withdraw', "hdfc.1.4", "acchdfc1", 1},
				{'getBalance', "hdfc.1.5", "acchdfc1"}
			   ]},
	 {"hdfc.2",[{'getBalance', "hdfc.2.1", "acchdfc2"},
				{'deposit', "hdfc.2.2", "acchdfc2", 50000},
				{'withdraw', "hdfc.2.3", "acchdfc2", 4000},
				{'withdraw', "hdfc.2.3", "acchdfc2", 40000},
				{'getBalance', "hdfc.2.1", "acchdfc2"}
			   ]},
	 {"hdfc.3",[{'getBalance', "hdfc.3.1", "acchdfc3"},
				{'deposit', "hdfc.3.1", "acchdfc3", 7000},
				{'withdraw', "hdfc.3.2", "acchdfc3", 7777},
				{'withdraw', "hdfc.3.2", "acchdfc3", 6999},
				{'getBalance', "hdfc.3.3", "acchdfc3"}
			   ]}
	].
						