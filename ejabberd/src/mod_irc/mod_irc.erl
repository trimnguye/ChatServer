%%%----------------------------------------------------------------------
%%% File    : mod_irc.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : IRC transport
%%% Created : 15 Feb 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: mod_irc.erl 307 2005-04-17 18:08:34Z tmallard $
%%%----------------------------------------------------------------------

-module(mod_irc).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-behaviour(gen_mod).

-export([start/1, init/2, stop/0,
	 closed_connection/3,
	 get_user_and_encoding/3]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(DEFAULT_IRC_ENCODING, "koi8-r").

-record(irc_connection, {jid_server_host, pid}).
-record(irc_custom, {us_host, data}).

start(Opts) ->
    iconv:start(),
    mnesia:create_table(irc_custom,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, irc_custom)}]),
    Hosts = gen_mod:get_hosts(Opts, "irc."),
    Host = hd(Hosts),
    update_table(Host),
    Access = gen_mod:get_opt(access, Opts, all),
    register(ejabberd_mod_irc, spawn(?MODULE, init, [Hosts, Access])).

init(Hosts, Access) ->
    catch ets:new(irc_connection, [named_table,
				   public,
				   {keypos, #irc_connection.jid_server_host}]),
    ejabberd_router:register_routes(Hosts),
    loop(Hosts, Access).

loop(Hosts, Access) ->
    receive
	{route, From, To, Packet} ->
	    case catch do_route(To#jid.lserver, Access, From, To, Packet) of
		{'EXIT', Reason} ->
		    ?ERROR_MSG("~p", [Reason]);
		_ ->
		    ok
	    end,
	    loop(Hosts, Access);
	stop ->
	    ejabberd_router:unregister_routes(Hosts),
	    ok;
	_ ->
	    loop(Hosts, Access)
    end.


do_route(Host, Access, From, To, Packet) ->
    case acl:match_rule(Access, From) of
	allow ->
	    do_route1(Host, From, To, Packet);
	_ ->
	    {xmlelement, _Name, Attrs, _Els} = Packet,
	    Lang = xml:get_attr_s("xml:lang", Attrs),
	    ErrText = "Access denied by service policy",
	    Err = jlib:make_error_reply(Packet,
					?ERRT_FORBIDDEN(Lang, ErrText)),
	    ejabberd_router:route(To, From, Err)
    end.

do_route1(Host, From, To, Packet) ->
    #jid{user = ChanServ, resource = Resource} = To,
    {xmlelement, _Name, Attrs, _Els} = Packet,
    case ChanServ of
	"" ->
	    case Resource of
		"" ->
		    case jlib:iq_query_info(Packet) of
			#iq{type = get, xmlns = ?NS_DISCO_INFO = XMLNS,
			    sub_el = SubEl} = IQ ->
			    Res = IQ#iq{type = result,
					sub_el = [{xmlelement, "query",
						   [{"xmlns", XMLNS}],
						   iq_disco()}]},
			    ejabberd_router:route(To,
						  From,
						  jlib:iq_to_xml(Res));
			#iq{type = get, xmlns = ?NS_DISCO_ITEMS = XMLNS} = IQ ->
			    Res = IQ#iq{type = result,
					sub_el = [{xmlelement, "query",
						   [{"xmlns", XMLNS}],
						   []}]},
			    ejabberd_router:route(To,
						  From,
						  jlib:iq_to_xml(Res));
			#iq{xmlns = ?NS_REGISTER} = IQ ->
			    process_register(Host, From, To, IQ);
			#iq{type = get, xmlns = ?NS_VCARD = XMLNS,
			    lang = Lang} = IQ ->
			    Res = IQ#iq{type = result,
					sub_el =
                                            [{xmlelement, "vCard",
                                              [{"xmlns", XMLNS}],
                                              iq_get_vcard(Lang)}]},
                            ejabberd_router:route(To,
                                                  From,
                                                  jlib:iq_to_xml(Res));
			#iq{} = IQ ->
			    Err = jlib:make_error_reply(
				    Packet, ?ERR_FEATURE_NOT_IMPLEMENTED),
			    ejabberd_router:route(To, From, Err);
			_ ->
			    ok
		    end;
		_ ->
		    Err = jlib:make_error_reply(Packet, ?ERR_BAD_REQUEST),
		    ejabberd_router:route(To, From, Err)
	    end;
	_ ->
	    case string:tokens(ChanServ, "%") of
		[[_ | _] = Channel, [_ | _] = Server] ->
		    case ets:lookup(irc_connection, {From, Server, Host}) of
			[] ->
			    io:format("open new connection~n"),
			    {Username, Encoding} = get_user_and_encoding(
						     Host, From, Server),
			    {ok, Pid} = mod_irc_connection:start(
					  From, Host, Server,
					  Username, Encoding),
			    ets:insert(
			      irc_connection,
			      #irc_connection{jid_server_host = {From, Server, Host},
					      pid = Pid}),
			    mod_irc_connection:route_chan(
			      Pid, Channel, Resource, Packet),
			    ok;
			[R] ->
			    Pid = R#irc_connection.pid,
			    io:format("send to process ~p~n",
				      [Pid]),
			    mod_irc_connection:route_chan(
			      Pid, Channel, Resource, Packet),
			    ok
		    end;
		_ ->
		    case string:tokens(ChanServ, "!") of
			[[_ | _] = Nick, [_ | _] = Server] ->
			    case ets:lookup(irc_connection, {From, Server, Host}) of
				[] ->
				    Err = jlib:make_error_reply(
					    Packet, ?ERR_SERVICE_UNAVAILABLE),
				    ejabberd_router:route(To, From, Err);
				[R] ->
				    Pid = R#irc_connection.pid,
				    io:format("send to process ~p~n",
					      [Pid]),
				    mod_irc_connection:route_nick(
				      Pid, Nick, Packet),
				    ok
			    end;
			_ ->
			    Err = jlib:make_error_reply(
				    Packet, ?ERR_BAD_REQUEST),
			    ejabberd_router:route(To, From, Err)
		    end
	    end
    end.




stop() ->
    ejabberd_mod_irc ! stop,
    ok.

closed_connection(Host, From, Server) ->
    ets:delete(irc_connection, {From, Server, Host}).


iq_disco() ->
    [{xmlelement, "identity",
      [{"category", "conference"},
       {"type", "irc"},
       {"name", "ejabberd/mod_irc"}], []},
     {xmlelement, "feature",
      [{"var", ?NS_MUC}], []},
     {xmlelement, "feature",
      [{"var", ?NS_REGISTER}], []},
     {xmlelement, "feature",
      [{"var", ?NS_VCARD}], []}].

iq_get_vcard(Lang) ->
    [{xmlelement, "FN", [],
      [{xmlcdata, "ejabberd/mod_irc"}]},                  
     {xmlelement, "URL", [],
      [{xmlcdata,
        "http://ejabberd.jabberstudio.org/"}]},
     {xmlelement, "DESC", [],
      [{xmlcdata, translate:translate(Lang, "ejabberd IRC module\n"
        "Copyright (c) 2003-2005 Alexey Shchepin")}]}].

process_register(Host, From, To, #iq{} = IQ) ->
    case catch process_irc_register(Host, From, To, IQ) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]);
	ResIQ ->
	    if
		ResIQ /= ignore ->
		    ejabberd_router:route(To, From,
					  jlib:iq_to_xml(ResIQ));
		true ->
		    ok
	    end
    end.

find_xdata_el({xmlelement, _Name, _Attrs, SubEls}) ->
    find_xdata_el1(SubEls).

find_xdata_el1([]) ->
    false;

find_xdata_el1([{xmlelement, Name, Attrs, SubEls} | Els]) ->
    case xml:get_attr_s("xmlns", Attrs) of
	?NS_XDATA ->
	    {xmlelement, Name, Attrs, SubEls};
	_ ->
	    find_xdata_el1(Els)
    end;

find_xdata_el1([_ | Els]) ->
    find_xdata_el1(Els).

process_irc_register(Host, From, To,
		     #iq{type = Type, xmlns = XMLNS,
			 lang = Lang, sub_el = SubEl} = IQ) ->
    case Type of
	set ->
	    XDataEl = find_xdata_el(SubEl),
	    case XDataEl of
		false ->
		    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ACCEPTABLE]};
		{xmlelement, _Name, Attrs, SubEls} ->
		    case xml:get_attr_s("type", Attrs) of
			"cancel" ->
			    IQ#iq{type = result,
				sub_el = [{xmlelement, "query",
					   [{"xmlns", XMLNS}], []}]};
			"submit" ->
			    XData = jlib:parse_xdata_submit(XDataEl),
			    case XData of
				invalid ->
				    IQ#iq{type = error,
					  sub_el = [SubEl, ?ERR_BAD_REQUEST]};
				_ ->
				    Node = string:tokens(
					     xml:get_tag_attr_s("node", SubEl),
					     "/"),
				    case set_form(
					   Host, From, Node, Lang, XData) of
					{result, Res} ->
					    IQ#iq{type = result,
						  sub_el = [{xmlelement, "query",
							     [{"xmlns", XMLNS}],
							     Res
							    }]};
					{error, Error} ->
					    IQ#iq{type = error,
						  sub_el = [SubEl, Error]}
				    end
			    end;
			_ ->
			    IQ#iq{type = error,
				  sub_el = [SubEl, ?ERR_BAD_REQUEST]}
		    end
	    end;
	get ->
	    Node =
		string:tokens(xml:get_tag_attr_s("node", SubEl), "/"),
	    case get_form(Host, From, Node, Lang) of
		{result, Res} ->
		    IQ#iq{type = result,
			  sub_el = [{xmlelement, "query",
				     [{"xmlns", XMLNS}],
				     Res
				    }]};
		{error, Error} ->
		    IQ#iq{type = error,
			  sub_el = [SubEl, Error]}
	    end
    end.



get_form(Host, From, [], Lang) ->
    #jid{user = User, server = Server,
	 luser = LUser, lserver = LServer} = From,
    US = {LUser, LServer},
    Customs =
	case catch mnesia:dirty_read({irc_custom, {US, Host}}) of
	    {'EXIT', Reason} ->
		{error, ?ERR_INTERNAL_SERVER_ERROR};
	    [] ->
		{User, []};
	    [#irc_custom{data = Data}] ->
		{xml:get_attr_s(username, Data),
		 xml:get_attr_s(encodings, Data)}
	end,
    case Customs of
	{error, _Error} ->
	    Customs;
	{Username, Encodings} ->
	    {result,
	     [{xmlelement, "instructions", [],
	       [{xmlcdata,
	         translate:translate(
		   Lang,
		   "You need an x:data capable client "
		   "to configure mod_irc settings")}]},
	      {xmlelement, "x", [{"xmlns", ?NS_XDATA}],
	       [{xmlelement, "title", [],
	         [{xmlcdata,
		   translate:translate(
		     Lang,
		     "Registration in mod_irc for ") ++ User ++ "@" ++ Server}]},
	              {xmlelement, "instructions", [],
	               [{xmlcdata,
	                 translate:translate(
	                   Lang,
			   "Enter username and encodings you wish to use for "
			   "connecting to IRC servers")}]},
	        {xmlelement, "field", [{"type", "text-single"},
				       {"label",
				        translate:translate(
					  Lang, "IRC Username")},
				       {"var", "username"}],
	         [{xmlelement, "value", [], [{xmlcdata, Username}]}]},
	        {xmlelement, "field", [{"type", "fixed"}],
	         [{xmlelement, "value", [],
		   [{xmlcdata,
		     lists:flatten(
		       io_lib:format(
		         translate:translate(
			   Lang,
			   "If you want to specify different encodings "
			   "for IRC servers, fill this list with values "
			   "in format '{\"irc server\", \"encoding\"}'.  "
			   "By default this service use \"~s\" encoding."),
		         [?DEFAULT_IRC_ENCODING]))}]}]},
	        {xmlelement, "field", [{"type", "fixed"}],
	         [{xmlelement, "value", [],
		   [{xmlcdata,
		     translate:translate(
		       Lang,
		       "Example: [{\"irc.lucky.net\", \"koi8-r\"}, "
		       "{\"vendetta.fef.net\", \"iso8859-1\"}]."
		    )}]}]},
	        {xmlelement, "field", [{"type", "text-multi"},
				       {"label",
				        translate:translate(Lang, "Encodings")},
				       {"var", "encodings"}],
		         lists:map(
			   fun(S) ->
				   {xmlelement, "value", [], [{xmlcdata, S}]}
			   end,
			   string:tokens(
			     lists:flatten(
			       io_lib:format("~p.", [Encodings])),
			     "\n"))
	        }
	       ]}]}
    end;

get_form(_Host, _, _, Lang) ->
    {error, ?ERR_SERVICE_UNAVAILABLE}.




set_form(Host, From, [], Lang, XData) ->
    {LUser, LServer, _} = jlib:jid_tolower(From),
    US = {LUser, LServer},
    case {lists:keysearch("username", 1, XData),
	  lists:keysearch("encodings", 1, XData)} of
	{{value, {_, [Username]}}, {value, {_, Strings}}} ->
	    EncString = lists:foldl(fun(S, Res) ->
					    Res ++ S ++ "\n"
				    end, "", Strings),
	    case erl_scan:string(EncString) of
		{ok, Tokens, _} ->
		    case erl_parse:parse_term(Tokens) of
			{ok, Encodings} ->
			    case mnesia:transaction(
				   fun() ->
					   mnesia:write(
					     #irc_custom{us_host =
							 {US, Host},
							 data =
							 [{username,
							   Username},
							  {encodings,
							   Encodings}]})
				   end) of
				{atomic, _} ->
				    {result, []};
				_ ->
				    {error, ?ERR_NOT_ACCEPTABLE}
			    end;
			_ ->
			    {error, ?ERR_NOT_ACCEPTABLE}
		    end;
		_ ->
		    {error, ?ERR_NOT_ACCEPTABLE}
	    end;
	_ ->
	    {error, ?ERR_NOT_ACCEPTABLE}
    end;


set_form(_Host, _, _, Lang, XData) ->
    {error, ?ERR_SERVICE_UNAVAILABLE}.


get_user_and_encoding(Host, From, IRCServer) ->
    #jid{user = User, server = Server,
	 luser = LUser, lserver = LServer} = From,
    US = {LUser, LServer},
    case catch mnesia:dirty_read({irc_custom, {US, Host}}) of
	{'EXIT', Reason} ->
	    {User, ?DEFAULT_IRC_ENCODING};
	[] ->
	    {User, ?DEFAULT_IRC_ENCODING};
	[#irc_custom{data = Data}] ->
	    {xml:get_attr_s(username, Data),
	     case xml:get_attr_s(IRCServer, xml:get_attr_s(encodings, Data)) of
		"" -> ?DEFAULT_IRC_ENCODING;
		E -> E
	     end}
    end.


update_table(Host) ->
    Fields = record_info(fields, irc_custom),
    case mnesia:table_info(irc_custom, attributes) of
	Fields ->
	    ok;
	[userserver, data] ->
	    ?INFO_MSG("Converting irc_custom table from "
		      "{userserver, data} format", []),
	    {atomic, ok} = mnesia:create_table(
			     mod_irc_tmp_table,
			     [{disc_only_copies, [node()]},
			      {type, bag},
			      {local_content, true},
			      {record_name, irc_custom},
			      {attributes, record_info(fields, irc_custom)}]),
	    mnesia:transform_table(irc_custom, ignore, Fields),
	    F1 = fun() ->
			 mnesia:write_lock_table(mod_irc_tmp_table),
			 mnesia:foldl(
			   fun(#irc_custom{us_host = US} = R, _) ->
				   mnesia:dirty_write(
				     mod_irc_tmp_table,
				     R#irc_custom{us_host = {US, Host}})
			   end, ok, irc_custom)
		 end,
	    mnesia:transaction(F1),
	    mnesia:clear_table(irc_custom),
	    F2 = fun() ->
			 mnesia:write_lock_table(irc_custom),
			 mnesia:foldl(
			   fun(R, _) ->
				   mnesia:dirty_write(R)
			   end, ok, mod_irc_tmp_table)
		 end,
	    mnesia:transaction(F2),
	    mnesia:delete_table(mod_irc_tmp_table);
	_ ->
	    ?INFO_MSG("Recreating irc_custom table", []),
	    mnesia:transform_table(irc_custom, ignore, Fields)
    end.
