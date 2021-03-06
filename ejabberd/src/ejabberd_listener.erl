%%%----------------------------------------------------------------------
%%% File    : ejabberd_listener.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 16 Nov 2002 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: ejabberd_listener.erl 288 2004-12-03 22:54:02Z aleksey $
%%%----------------------------------------------------------------------

-module(ejabberd_listener).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start_link/0, init/1, start/3,
	 init/3,
	 init_ssl/4,
	 start_listener/3,
	 stop_listener/1,
	 add_listener/3,
	 delete_listener/1
	]).

-include("ejabberd.hrl").

start_link() ->
    supervisor:start_link({local, ejabberd_listeners}, ?MODULE, []).


init(_) ->
    case ejabberd_config:get_local_option(listen) of
	undefined ->
	    ignore;
	Ls ->
	    {ok, {{one_for_one, 10, 1},
		  lists:map(
		    fun({Port, Module, Opts}) ->
			    {Port,
			     {?MODULE, start, [Port, Module, Opts]},
			     transient,
			     brutal_kill,
			     worker,
			     [?MODULE]}
		    end, Ls)}}
    end.


start(Port, Module, Opts) ->
    case lists:keysearch(ssl, 1, Opts) of
	{value, {ssl, SSLOpts}} ->
	    {ok, proc_lib:spawn_link(?MODULE, init_ssl,
				     [Port, Module, Opts, SSLOpts])};
	_ ->
	    case lists:member(ssl, Opts) of
		true ->
		    {ok, proc_lib:spawn_link(?MODULE, init_ssl,
					     [Port, Module, Opts, []])};
		false ->
		    {ok, proc_lib:spawn_link(?MODULE, init,
					     [Port, Module, Opts])}
	    end
    end.

init(Port, Module, Opts) ->
    SockOpts = lists:filter(fun({ip, _}) -> true;
			       (inet6) -> true;
			       (inet) -> true;
			       (_) -> false
			    end, Opts),

    Res = gen_tcp:listen(Port, [binary,
				{packet, 0}, 
				{active, false},
				{reuseaddr, true},
				{nodelay, true},
				{keepalive, true} |
				SockOpts]),
    case Res of
	{ok, ListenSocket} ->
	    accept(ListenSocket, Module, Opts);
	{error, Reason} ->
	    ?ERROR_MSG("Failed to open socket for ~p: ~p",
		       [{Port, Module, Opts}, Reason]),
	    error
    end.

accept(ListenSocket, Module, Opts) ->
    case gen_tcp:accept(ListenSocket) of
	{ok, Socket} ->
	    case {inet:sockname(Socket), inet:peername(Socket)} of
		{{ok, Addr}, {ok, PAddr}} ->
		    ?INFO_MSG("(~w) Accepted connection ~w -> ~w",
			      [Socket, PAddr, Addr]);
		_ ->
		    ok
	    end,
	    {ok, Pid} = Module:start({gen_tcp, Socket}, Opts),
	    case gen_tcp:controlling_process(Socket, Pid) of
		ok ->
		    ok;
		{error, _Reason} ->
		    gen_tcp:close(Socket)
	    end,
	    accept(ListenSocket, Module, Opts);
	{error, Reason} ->
	    ?INFO_MSG("(~w) Failed TCP accept: ~w",
		      [ListenSocket, Reason]),
	    accept(ListenSocket, Module, Opts)
    end.


init_ssl(Port, Module, Opts, SSLOpts) ->
    SockOpts = lists:filter(fun({ip, _}) -> true;
			       (inet6) -> true;
			       (inet) -> true;
			       ({verify, _}) -> true;
			       ({depth, _}) -> true;
			       ({certfile, _}) -> true;
			       ({keyfile, _}) -> true;
			       ({password, _}) -> true;
			       ({cacertfile, _}) -> true;
			       ({ciphers, _}) -> true;
			       (_) -> false
			    end, Opts),
    Res = ssl:listen(Port, [binary,
			    {packet, 0}, 
			    {active, false},
			    {nodelay, true} |
			    SockOpts ++ SSLOpts]),
    case Res of
	{ok, ListenSocket} ->
	    accept_ssl(ListenSocket, Module, Opts);
	{error, Reason} ->
	    ?ERROR_MSG("Failed to open socket for ~p: ~p",
		       [{Port, Module, Opts}, Reason]),
	    error
    end.

accept_ssl(ListenSocket, Module, Opts) ->
    case ssl:accept(ListenSocket, 200) of
	{ok, Socket} ->
	    case {ssl:sockname(Socket), ssl:peername(Socket)} of
		{{ok, Addr}, {ok, PAddr}} ->
		    ?INFO_MSG("(~w) Accepted SSL connection ~w -> ~w",
			      [Socket, PAddr, Addr]);
		_ ->
		    ok
	    end,
	    {ok, Pid} = Module:start({ssl, Socket}, Opts),
	    catch ssl:controlling_process(Socket, Pid),
	    accept_ssl(ListenSocket, Module, Opts);
	{error, timeout} ->
	    accept_ssl(ListenSocket, Module, Opts);
	{error, Reason} ->
	    ?INFO_MSG("(~w) Failed SSL handshake: ~w",
		      [ListenSocket, Reason]),
	    accept_ssl(ListenSocket, Module, Opts)
    end.


start_listener(Port, Module, Opts) ->
    ChildSpec = {Port,
		 {?MODULE, start, [Port, Module, Opts]},
		 transient,
		 brutal_kill,
		 worker,
		 [?MODULE]},
    supervisor:start_child(ejabberd_listeners, ChildSpec).

stop_listener(Port) ->
    supervisor:terminate_child(ejabberd_listeners, Port),
    supervisor:delete_child(ejabberd_listeners, Port).

add_listener(Port, Module, Opts) ->
    Ports = case ejabberd_config:get_local_option(listen) of
		undefined ->
		    [];
		Ls ->
		    Ls
	    end,
    Ports1 = lists:keydelete(Port, 1, Ports),
    Ports2 = [{Port, Module, Opts} | Ports1],
    ejabberd_config:add_local_option(listen, Ports2),
    start_listener(Port, Module, Opts).

delete_listener(Port) ->
    Ports = case ejabberd_config:get_local_option(listen) of
		undefined ->
		    [];
		Ls ->
		    Ls
	    end,
    Ports1 = lists:keydelete(Port, 1, Ports),
    ejabberd_config:add_local_option(listen, Ports1),
    stop_listener(Port).

