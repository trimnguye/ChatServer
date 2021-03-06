%%%----------------------------------------------------------------------
%%% File    : mod_echo.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 15 Jan 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: mod_echo.erl 185 2003-12-14 20:51:01Z aleksey $
%%%----------------------------------------------------------------------

-module(mod_echo).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-behaviour(gen_mod).

-export([start/1, init/1, stop/0]).

-include("ejabberd.hrl").
-include("jlib.hrl").



start(Opts) ->
    %Host = gen_mod:get_opt(host, Opts),
    Host = gen_mod:get_opt(host, Opts, "echo." ++ ?MYNAME),
    register(ejabberd_mod_echo, spawn(?MODULE, init, [Host])).

init(Host) ->
    ejabberd_router:register_route(Host),
    loop(Host).

loop(Host) ->
    receive
	{route, From, To, Packet} ->
	    ejabberd_router:route(To, From, Packet),
	    loop(Host);
	stop ->
	    ejabberd_router:unregister_route(Host),
	    ok;
	_ ->
	    loop(Host)
    end.

stop() ->
    ejabberd_mod_echo ! stop,
    ok.
