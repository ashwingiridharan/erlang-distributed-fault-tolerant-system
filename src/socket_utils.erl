
-module(socket_utils).

%% ====================================================================
%% API functions
%% ====================================================================
-export([start/1, accept/3, send/2, send_async/2, send_async_delay/3, send_async_process/3]).

start(Args) ->
	listen(Args).

%% ====================================================================
%% Internal functions
%% ====================================================================
listen(Args) ->
	{module, M} = lists:keyfind(module, 1, Args),
	LPort = 0, %% OS will assign a free port
	case catch gen_tcp:listen(LPort,[binary,{active, false},{packet,2}]) of
        {ok, ListenSock} ->
			{ok, Port} = inet:port(ListenSock),
			{ok, SPid} = M:startLink([{port,Port}|Args]),
            spawn(?MODULE,accept,[M, ListenSock, SPid]),
            Port;
        {error,Reason} ->
            {error,Reason}
    end.

accept(M, LS, SPid) ->
    case gen_tcp:accept(LS) of
        {ok,Socket} ->
            loop(M, Socket, SPid),
            accept(M, LS, SPid);
        Other ->
            logger:i_msg("accept returned ~w - goodbye!~n",[{M,Other}]),
            ok
    end.

loop(M, Socket, SPid) ->
    inet:setopts(Socket,[{active,once}]),
    receive
        {tcp,Socket,Data} ->
			spawn(M, process, [Socket, Data, SPid]),
            loop(M, Socket, SPid);
        {tcp_closed,Socket} ->
%%             logger:i_msg("Socket ~w closed [~w]~n",[Socket,self()]),
            ok;
		Error ->
			logger:i_msg("Socket Exception ~p~n",[Error])
    end.


send(PortNo,Message) ->
    {ok,Sock} = gen_tcp:connect("localhost",PortNo,[{active,false},
                                                    {packet,2}]),
    gen_tcp:send(Sock,term_to_binary(Message)),
    {ok,A} = gen_tcp:recv(Sock,0),
    gen_tcp:close(Sock),
    binary_to_term(list_to_binary(A)).

send_async(PortNo,Message) ->
    {ok,Sock} = gen_tcp:connect("localhost",PortNo,[{active,false},
                                                    {packet,2}]),
    gen_tcp:send(Sock,term_to_binary(Message)),
    gen_tcp:close(Sock).

send_async_delay(PortNo, Message, Delay) ->
	timer:sleep(Delay),
    {ok,Sock} = gen_tcp:connect("localhost",PortNo,[{active,false},
                                                    {packet,2}]),
    gen_tcp:send(Sock,term_to_binary(Message)),
    gen_tcp:close(Sock).

send_async_process(PortNo, Message, Delay) ->
	if Delay > 0 ->
		   spawn(?MODULE, send_async_delay, [PortNo, Message, Delay] );
	   true ->
		   send_async(PortNo,Message)
	end.