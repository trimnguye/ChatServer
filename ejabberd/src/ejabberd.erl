%%%----------------------------------------------------------------------
%%% File    : ejabberd.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 16 Nov 2002 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: ejabberd.erl 223 2004-04-15 19:55:38Z aleksey $
%%%----------------------------------------------------------------------

-module(ejabberd).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/0, stop/0,
	 get_so_path/0]).

start() ->
    application:start(ejabberd).

stop() ->
    application:stop(ejabberd).


get_so_path() ->
    case os:getenv("EJABBERD_SO_PATH") of
	false ->
	    case code:priv_dir(ejabberd) of
		{error, _} ->
		    ".";
		Path ->
		    filename:join([Path, "lib"])
	    end;
	Path ->
	    Path
    end.
