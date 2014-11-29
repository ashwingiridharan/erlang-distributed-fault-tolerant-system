
-module(logger).

%% ====================================================================
%% API functions
%% ====================================================================
-export([start/2, i_msg/2, e_msg/2]).


start(Path, Name) ->
	R = error_logger:logfile({open,Path++"//log//"++Name++".log"}),
	error_logger:info_msg("Log file creation ~p~n",[R]).

%% ====================================================================
%% Internal functions
%% ====================================================================
i_msg(Msg, Args) ->
	error_logger:info_msg(Msg,Args).

e_msg(Msg, Args) ->
	error_logger:error_msg(Msg,Args).
