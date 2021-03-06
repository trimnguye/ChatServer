%%%----------------------------------------------------------------------
%%% File    : mod_time.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 18 Jan 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: mod_time.erl 186 2003-12-17 20:13:21Z aleksey $
%%%----------------------------------------------------------------------

-module(mod_time).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-behaviour(gen_mod).

-export([start/1,
	 stop/0,
	 process_local_iq/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").


start(Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?NS_TIME,
				  ?MODULE, process_local_iq, IQDisc).

stop() ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?NS_TIME).

process_local_iq(_From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    case Type of
	set ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
	get ->
	    UTC = jlib:timestamp_to_iso(calendar:universal_time()),
	    IQ#iq{type = result,
		  sub_el = [{xmlelement, "query",
			     [{"xmlns", ?NS_TIME}],
			     [{xmlelement, "utc", [],
			       [{xmlcdata, UTC}]}]}]}
    end.


