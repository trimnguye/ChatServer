%%%----------------------------------------------------------------------
%%% File    : mod_irc_connection.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 15 Feb 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: mod_irc_connection.erl 307 2005-04-17 18:08:34Z tmallard $
%%%----------------------------------------------------------------------

-module(mod_irc_connection).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-behaviour(gen_fsm).

%% External exports
-export([start/5, receiver/2, route_chan/4, route_nick/3]).

%% gen_fsm callbacks
-export([init/1,
	 open_socket/2,
	 wait_for_registration/2,
	 stream_established/2,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3,
	 code_change/4]).

-include("ejabberd.hrl").
-include("jlib.hrl").

-define(SETS, gb_sets).

-record(state, {socket, encoding, receiver, queue,
		user, host, server, nick,
		channels = dict:new(),
		inbuf = "", outbuf = ""}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(From, Host, Server, Username, Encoding) ->
    gen_fsm:start(?MODULE, [From, Host, Server, Username, Encoding], ?FSMOPTS).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}                   
%%----------------------------------------------------------------------
init([From, Host, Server, Username, Encoding]) ->
    gen_fsm:send_event(self(), init),
    {ok, open_socket, #state{queue = queue:new(),
			     encoding = Encoding,
			     user = From,
			     nick = Username,
			     host = Host,
			     server = Server}}.

%%----------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
open_socket(init, StateData) ->
    Addr = StateData#state.server,
    Port = 6667,
    ?DEBUG("connecting to ~s:~p~n", [Addr, Port]),
    case gen_tcp:connect(Addr, Port, [binary, {packet, 0}]) of
	{ok, Socket} ->
	    NewStateData = StateData#state{socket = Socket},
	    send_text(NewStateData,
		      io_lib:format("NICK ~s\r\n", [StateData#state.nick])),
	    send_text(NewStateData,
		      io_lib:format(
			"USER ~s ~s ~s :~s\r\n",
			[StateData#state.nick,
			 StateData#state.nick,
			 StateData#state.host,
			 StateData#state.nick])),
	    send_text(NewStateData,
		      io_lib:format("CODEPAGE ~s\r\n", [StateData#state.encoding])),
	    {next_state, wait_for_registration,
	     NewStateData};
	{error, Reason} ->
	    ?DEBUG("connect return ~p~n", [Reason]),
	    Text = case Reason of
		       timeout -> "Server Connect Timeout";
		       _ -> "Server Connect Failed"
		   end,
	    bounce_messages(Text),
	    {stop, normal, StateData}
    end.

wait_for_registration(closed, StateData) ->
    {stop, normal, StateData}.

stream_established({xmlstreamend, Name}, StateData) ->
    {stop, normal, StateData};

stream_established(timeout, StateData) ->
    {stop, normal, StateData};

stream_established(closed, StateData) ->
    {stop, normal, StateData}.



%%----------------------------------------------------------------------
%% Func: StateName/3
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}                    
%%----------------------------------------------------------------------
%state_name(Event, From, StateData) ->
%    Reply = ok,
%    {reply, Reply, state_name, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
handle_event(Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}                    
%%----------------------------------------------------------------------
handle_sync_event(Event, From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

code_change(OldVsn, StateName, StateData, Extra) ->
    {ok, StateName, StateData}.

-define(SEND(S),
	if
	    StateName == stream_established ->
		send_text(StateData, S),
		StateData;
	    true ->
		StateData#state{outbuf = StateData#state.outbuf ++ S}
	end).

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                         
%%----------------------------------------------------------------------
handle_info({route_chan, Channel, Resource,
	     {xmlelement, "presence", Attrs, Els}},
	    StateName, StateData) ->
    NewStateData =
	case xml:get_attr_s("type", Attrs) of
	    "unavailable" ->
		S1 = ?SEND(io_lib:format("PART #~s\r\n", [Channel])),
		S1#state{channels =
			 dict:erase(Channel, S1#state.channels)};
	    "subscribe" -> StateData;
	    "subscribed" -> StateData;
	    "unsubscribe" -> StateData;
	    "unsubscribed" -> StateData;
	    "error" -> stop;
	    _ ->
		Nick = case Resource of
			   "" ->
			       StateData#state.nick;
			   _ ->
			       Resource
		       end,
		S1 = ?SEND(io_lib:format("NICK ~s\r\n"
					 "JOIN #~s\r\n",
					 [Nick, Channel])),
		case dict:is_key(Channel, S1#state.channels) of
		    true ->
			S1#state{nick = Nick};
		    _ ->
			S1#state{nick = Nick,
				 channels =
				 dict:store(Channel, ?SETS:new(),
					    S1#state.channels)}
		end
	end,
    if
	NewStateData == stop ->
	    {stop, normal, StateData};
	true ->
	    case length(dict:fetch_keys(NewStateData#state.channels)) of
		0 ->
		    {stop, normal, NewStateData};
		_ ->
		    {next_state, StateName, NewStateData}
	    end
    end;

handle_info({route_chan, Channel, Resource,
	     {xmlelement, "message", Attrs, Els} = El},
	    StateName, StateData) ->
    NewStateData =
	case xml:get_attr_s("type", Attrs) of
	    "groupchat" ->
		case xml:get_path_s(El, [{elem, "subject"}, cdata]) of
		    "" ->
			ejabberd_router:route(
			  jlib:make_jid(
			    lists:concat(
			      [Channel, "%", StateData#state.server]),
			    StateData#state.host, StateData#state.nick),
			  StateData#state.user, El),
			Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
			case Body of
			    "/quote " ++ Rest ->
				?SEND(Rest ++ "\r\n");
			    _ ->
				Body1 =
				    case Body of
					[$/, $m, $e, $  | Rest] ->
					    "\001ACTION " ++ Rest ++ "\001";
					_ ->
					    Body
				    end,
				Strings = string:tokens(Body1, "\n"),
				Res = lists:concat(
					lists:map(
					  fun(S) ->
						  io_lib:format(
						    "PRIVMSG #~s :~s\r\n",
						    [Channel, S])
					  end, Strings)),
				?SEND(Res)
			end;
		    Subject ->
			Strings = string:tokens(Subject, "\n"),
			Res = lists:concat(
				lists:map(
				  fun(S) ->
					  io_lib:format("TOPIC #~s :~s\r\n",
							[Channel, S])
				  end, Strings)),
			?SEND(Res)
		end;
	    "chat" ->
		Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
		case Body of
		    "/quote " ++ Rest ->
			?SEND(Rest ++ "\r\n");
		    _ ->
			Body1 = case Body of
				    [$/, $m, $e, $  | Rest] ->
					"\001ACTION " ++ Rest ++ "\001";
				    _ ->
					Body
				end,
			Strings = string:tokens(Body1, "\n"),
			Res = lists:concat(
				lists:map(
				  fun(S) ->
					  io_lib:format("PRIVMSG ~s :~s\r\n",
							[Resource, S])
				  end, Strings)),
			?SEND(Res)
		end;
	    "error" ->
		stop;
	    _ ->
		StateData
	end,
    if
	NewStateData == stop ->
	    {stop, normal, StateData};
	true ->
	    {next_state, StateName, NewStateData}
    end;


handle_info({route_chan, Channel, Resource,
	     {xmlelement, "iq", Attrs, Els} = El},
	    StateName, StateData) ->
    From = StateData#state.user,
    To = jlib:make_jid(lists:concat([Channel, "%", StateData#state.server]),
		       StateData#state.host, StateData#state.nick),
    case jlib:iq_query_info(El) of
	#iq{xmlns = ?NS_MUC_ADMIN} = IQ ->
	    iq_admin(StateData, Channel, From, To, IQ);
	#iq{xmlns = ?NS_VERSION} ->
	    Res = io_lib:format("PRIVMSG ~s :\001VERSION\001\r\n",
				[Resource]),
	    ?SEND(Res),
	    Err = jlib:make_error_reply(
		    El, ?ERR_FEATURE_NOT_IMPLEMENTED),
	    ejabberd_router:route(To, From, Err);
	#iq{xmlns = ?NS_TIME} ->
	    Res = io_lib:format("PRIVMSG ~s :\001TIME\001\r\n",
				[Resource]),
	    ?SEND(Res),
	    Err = jlib:make_error_reply(
		    El, ?ERR_FEATURE_NOT_IMPLEMENTED),
	    ejabberd_router:route(To, From, Err);
	#iq{} ->
	    Err = jlib:make_error_reply(
		    El, ?ERR_FEATURE_NOT_IMPLEMENTED),
	    ejabberd_router:route(To, From, Err);
	_ ->
	    ok
    end,
    {next_state, StateName, StateData};

handle_info({route_chan, Channel, Resource, Packet}, StateName, StateData) ->
    {next_state, StateName, StateData};


handle_info({route_nick, Nick,
	     {xmlelement, "message", Attrs, Els} = El},
	    StateName, StateData) ->
    NewStateData =
	case xml:get_attr_s("type", Attrs) of
	    "chat" ->
		Body = xml:get_path_s(El, [{elem, "body"}, cdata]),
		case Body of
		    "/quote " ++ Rest ->
			?SEND(Rest ++ "\r\n");
		    _ ->
			Body1 = case Body of
				    [$/, $m, $e, $  | Rest] ->
					"\001ACTION " ++ Rest ++ "\001";
				    _ ->
					Body
				end,
			Strings = string:tokens(Body1, "\n"),
			Res = lists:concat(
				lists:map(
				  fun(S) ->
					  io_lib:format("PRIVMSG ~s :~s\r\n",
							[Nick, S])
				  end, Strings)),
			?SEND(Res)
		end;
	    "error" ->
		stop;
	    _ ->
		StateData
	end,
    if
	NewStateData == stop ->
	    {stop, normal, StateData};
	true ->
	    {next_state, StateName, NewStateData}
    end;

handle_info({route_nick, Nick, Packet}, StateName, StateData) ->
    {next_state, StateName, StateData};


handle_info({ircstring, [$P, $I, $N, $G, $  | ID]}, StateName, StateData) ->
    send_text(StateData, "PONG " ++ ID ++ "\r\n"),
    {next_state, StateName, StateData};

handle_info({ircstring, [$: | String]}, StateName, StateData) ->
    Words = string:tokens(String, " "),
    NewStateData =
	case Words of
	    [_, "353" | Items] ->
		process_channel_list(StateData, Items);
	    [_, "332", Nick, [$# | Chan] | _] ->
		process_channel_topic(StateData, Chan, String),
		StateData;
	    [From, "PRIVMSG", [$# | Chan] | _] ->
		process_chanprivmsg(StateData, Chan, From, String),
		StateData;
	    [From, "NOTICE", [$# | Chan] | _] ->
		process_channotice(StateData, Chan, From, String),
		StateData;
	    [From, "PRIVMSG", Nick, ":\001VERSION\001" | _] ->
		process_version(StateData, Nick, From),
		StateData;
	    [From, "PRIVMSG", Nick | _] ->
		process_privmsg(StateData, Nick, From, String),
		StateData;
	    [From, "NOTICE", Nick | _] ->
		process_notice(StateData, Nick, From, String),
		StateData;
	    [From, "TOPIC", [$# | Chan] | _] ->
		process_topic(StateData, Chan, From, String),
		StateData;
	    [From, "PART", [$# | Chan] | _] ->
		process_part(StateData, Chan, From, String);
	    [From, "QUIT" | _] ->
		process_quit(StateData, From, String);
	    [From, "JOIN", Chan | _] ->
		process_join(StateData, Chan, From, String);
	    [From, "MODE", [$# | Chan], "+o", Nick | _] ->
		process_mode_o(StateData, Chan, From, Nick,
			       "admin", "moderator"),
		StateData;
	    [From, "MODE", [$# | Chan], "-o", Nick | _] ->
		process_mode_o(StateData, Chan, From, Nick,
			       "member", "participant"),
		StateData;
	    [From, "KICK", [$# | Chan], Nick | _] ->
		process_kick(StateData, Chan, From, Nick),
		StateData;
	    [From, "NICK", Nick | _] ->
		process_nick(StateData, From, Nick);
	    _ ->
		?DEBUG("unknown irc command '~s'~n", [String]),
		StateData
	end,
    NewStateData1 =
	case StateData#state.outbuf of
	    "" ->
		NewStateData;
	    Data ->
		send_text(NewStateData, Data),
		NewStateData#state{outbuf = ""}
	end,
    {next_state, stream_established, NewStateData1};

handle_info({ircstring, [$E, $R, $R, $O, $R | _] = String},
	    StateName, StateData) ->
    process_error(StateData, String),
    {next_state, StateName, StateData};


handle_info({ircstring, String}, StateName, StateData) ->
    ?DEBUG("unknown irc command '~s'~n", [String]),
    {next_state, StateName, StateData};


handle_info({send_text, Text}, StateName, StateData) ->
    send_text(StateData, Text),
    {next_state, StateName, StateData};
handle_info({tcp, Socket, Data}, StateName, StateData) ->
    Buf = StateData#state.inbuf ++ binary_to_list(Data),
    {ok, Strings} = regexp:split([C || C <- Buf, C /= $\r], "\n"),
    ?DEBUG("strings=~p~n", [Strings]),
    NewBuf = process_lines(StateData#state.encoding, Strings),
    {next_state, StateName, StateData#state{inbuf = NewBuf}};
handle_info({tcp_closed, Socket}, StateName, StateData) ->
    gen_fsm:send_event(self(), closed),
    {next_state, StateName, StateData};
handle_info({tcp_error, Socket, Reason}, StateName, StateData) ->
    gen_fsm:send_event(self(), closed),
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(Reason, StateName, StateData) ->
    mod_irc:closed_connection(StateData#state.host,
			      StateData#state.user,
			      StateData#state.server),
    bounce_messages("Server Connect Failed"),
    lists:foreach(
      fun(Chan) ->
	      ejabberd_router:route(
		jlib:make_jid(
		  lists:concat([Chan, "%", StateData#state.server]),
		  StateData#state.host, StateData#state.nick),
		StateData#state.user,
		{xmlelement, "presence", [{"type", "error"}],
		 [{xmlelement, "error", [{"code", "502"}],
		   [{xmlcdata, "Server Connect Failed"}]}]})
      end, dict:fetch_keys(StateData#state.channels)),
    case StateData#state.socket of
	undefined ->
	    ok;
	Socket ->
	    gen_tcp:close(Socket)
    end,
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

receiver(Socket, C2SPid) ->
    XMLStreamPid = xml_stream:start(C2SPid),
    receiver(Socket, C2SPid, XMLStreamPid).

receiver(Socket, C2SPid, XMLStreamPid) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Text} ->
	    xml_stream:send_text(XMLStreamPid, Text),
	    receiver(Socket, C2SPid, XMLStreamPid);
        {error, Reason} ->
	    exit(XMLStreamPid, closed),
	    gen_fsm:send_event(C2SPid, closed),
	    ok
    end.

send_text(#state{socket = Socket, encoding = Encoding}, Text) ->
    CText = iconv:convert("utf-8", Encoding, lists:flatten(Text)),
    %?DEBUG("IRC OUTu: ~s~nIRC OUTk: ~s~n", [Text, CText]),
    gen_tcp:send(Socket, CText).


%send_queue(Socket, Q) ->
%    case queue:out(Q) of
%	{{value, El}, Q1} ->
%	    send_element(Socket, El),
%	    send_queue(Socket, Q1);
%	{empty, Q1} ->
%	    ok
%    end.

bounce_messages(Reason) ->
    receive
	{send_element, El} ->
	    {xmlelement, Name, Attrs, SubTags} = El,
	    case xml:get_attr_s("type", Attrs) of
	        "error" ->
	            ok;
	        _ ->
	            Err = jlib:make_error_reply(El,
	        				"502", Reason),
		    From = jlib:string_to_jid(xml:get_attr_s("from", Attrs)),
		    To = jlib:string_to_jid(xml:get_attr_s("to", Attrs)),
		    ejabberd_router:route(To, From, Err)
	    end,
	    bounce_messages(Reason)
    after 0 ->
	    ok
    end.


route_chan(Pid, Channel, Resource, Packet) ->
    Pid ! {route_chan, Channel, Resource, Packet}.

route_nick(Pid, Nick, Packet) ->
    Pid ! {route_nick, Nick, Packet}.


process_lines(Encoding, [S]) ->
    S;
process_lines(Encoding, [S | Ss]) ->
    self() ! {ircstring, iconv:convert(Encoding, "utf-8", S)},
    process_lines(Encoding, Ss).

process_channel_list(StateData, Items) ->
    process_channel_list_find_chan(StateData, Items).

process_channel_list_find_chan(StateData, []) ->
    StateData;
process_channel_list_find_chan(StateData, [[$# | Chan] | Items]) ->
    process_channel_list_users(StateData, Chan, Items);
process_channel_list_find_chan(StateData, [_ | Items]) ->
    process_channel_list_find_chan(StateData, Items).

process_channel_list_users(StateData, Chan, []) ->
    StateData;
process_channel_list_users(StateData, Chan, [User | Items]) ->
    NewStateData = process_channel_list_user(StateData, Chan, User),
    process_channel_list_users(NewStateData, Chan, Items).

process_channel_list_user(StateData, Chan, User) ->
    User1 = case User of
		[$: | U1] -> U1;
		_ -> User
	    end,
    {User2, Affiliation, Role} =
	case User1 of
	    [$@ | U2] -> {U2, "admin", "moderator"};
	    [$+ | U2] -> {U2, "member", "participant"};
	    _ -> {User1, "member", "participant"}
	end,
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, User2),
      StateData#state.user,
      {xmlelement, "presence", [],
       [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
	 [{xmlelement, "item",
	   [{"affiliation", Affiliation},
	    {"role", Role}],
	   []}]}]}),
    case catch dict:update(Chan,
			   fun(Ps) ->
				   ?SETS:add_element(User2, Ps)
			   end, StateData#state.channels) of
	{'EXIT', _} ->
	    StateData;
	NS ->
	    StateData#state{channels = NS}
    end.


process_channel_topic(StateData, Chan, String) ->
    FromUser = "someone",
    {ok, Msg, _} = regexp:sub(String, ".*332[^:]*:", ""),
    Msg1 = filter_message(Msg),
    ejabberd_router:route(
      jlib:make_jid(
	lists:concat([Chan, "%", StateData#state.server]),
	StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "message", [{"type", "groupchat"}],
       [{xmlelement, "subject", [], [{xmlcdata, Msg1}]}]}).


process_chanprivmsg(StateData, Chan, From, String) ->
    [FromUser | _] = string:tokens(From, "!"),
    {ok, Msg, _} = regexp:sub(String, ".*PRIVMSG[^:]*:", ""),
    Msg1 = case Msg of
	       [1, $A, $C, $T, $I, $O, $N, $  | Rest] ->
		   "/me " ++ Rest;
	       _ ->
		   Msg
	   end,
    Msg2 = filter_message(Msg1),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "message", [{"type", "groupchat"}],
       [{xmlelement, "body", [], [{xmlcdata, Msg2}]}]}).



process_channotice(StateData, Chan, From, String) ->
    [FromUser | _] = string:tokens(From, "!"),
    {ok, Msg, _} = regexp:sub(String, ".*NOTICE[^:]*:", ""),
    Msg1 = case Msg of
	       [1, $A, $C, $T, $I, $O, $N, $  | Rest] ->
		   "/me " ++ Rest;
	       _ ->
		   Msg
	   end,
    Msg2 = filter_message(Msg1),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "message", [{"type", "groupchat"}],
       [{xmlelement, "body", [], [{xmlcdata, "NOTICE: " ++ Msg2}]}]}).




process_privmsg(StateData, Nick, From, String) ->
    [FromUser | _] = string:tokens(From, "!"),
    {ok, Msg, _} = regexp:sub(String, ".*PRIVMSG[^:]*:", ""),
    Msg1 = case Msg of
	       [1, $A, $C, $T, $I, $O, $N, $  | Rest] ->
		   "/me " ++ Rest;
	       _ ->
		   Msg
	   end,
    Msg2 = filter_message(Msg1),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([FromUser, "!", StateData#state.server]),
		    StateData#state.host, ""),
      StateData#state.user,
      {xmlelement, "message", [{"type", "chat"}],
       [{xmlelement, "body", [], [{xmlcdata, Msg2}]}]}).


process_notice(StateData, Nick, From, String) ->
    [FromUser | _] = string:tokens(From, "!"),
    {ok, Msg, _} = regexp:sub(String, ".*NOTICE[^:]*:", ""),
    Msg1 = case Msg of
	       [1, $A, $C, $T, $I, $O, $N, $  | Rest] ->
		   "/me " ++ Rest;
	       _ ->
		   Msg
	   end,
    Msg2 = filter_message(Msg1),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([FromUser, "!", StateData#state.server]),
		    StateData#state.host, ""),
      StateData#state.user,
      {xmlelement, "message", [{"type", "chat"}],
       [{xmlelement, "body", [], [{xmlcdata, "NOTICE: " ++ Msg2}]}]}).


process_version(StateData, Nick, From) ->
    [FromUser | _] = string:tokens(From, "!"),
    send_text(
      StateData,
      io_lib:format("NOTICE ~s :\001VERSION "
		    "ejabberd IRC transport ~s (c) Alexey Shchepin"
		    "\001\r\n",
		    [FromUser, ?VERSION]) ++
      io_lib:format("NOTICE ~s :\001VERSION "
		    "http://ejabberd.jabberstudio.org/"
		    "\001\r\n",
		    [FromUser])).


process_topic(StateData, Chan, From, String) ->
    [FromUser | _] = string:tokens(From, "!"),
    {ok, Msg, _} = regexp:sub(String, ".*TOPIC[^:]*:", ""),
    Msg1 = filter_message(Msg),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "message", [{"type", "groupchat"}],
       [{xmlelement, "subject", [], [{xmlcdata, Msg1}]},
	{xmlelement, "body", [],
	 [{xmlcdata, "/me has changed the subject to: " ++
	   Msg1}]}]}).

process_part(StateData, Chan, From, String) ->
    [FromUser | FromIdent] = string:tokens(From, "!"),
    {ok, Msg, _} = regexp:sub(String, ".*PART[^:]*", ""),    
    Msg1 = filter_message(Msg),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "message", [{"type", "groupchat"}],
       [{xmlelement, "body", [],
	 [{xmlcdata, "/me has part: " ++
	   Msg1 ++ "("  ++ FromIdent ++ ")" }]}]}),

    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "presence", [{"type", "unavailable"}],
       [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
	 [{xmlelement, "item",
	   [{"affiliation", "member"},
	    {"role", "none"}],
	   []}]},
	{xmlelement, "status", [],
	 [{xmlcdata, Msg1 ++ "("  ++ FromIdent ++ ")"}]}]
      }),
    case catch dict:update(Chan,
			   fun(Ps) ->
				   remove_element(FromUser, Ps)
			   end, StateData#state.channels) of
	{'EXIT', _} ->
	    StateData;
	NS ->
	    StateData#state{channels = NS}
    end.


process_quit(StateData, From, String) ->
    [FromUser | FromIdent] = string:tokens(From, "!"),
    
    {ok, Msg, _} = regexp:sub(String, ".*QUIT[^:]*:", ""),
    Msg1 = filter_message(Msg),
    NewChans =
	dict:map(
	  fun(Chan, Ps) ->
		  case ?SETS:is_member(FromUser, Ps) of
		      true ->
		          ejabberd_router:route(
			    jlib:make_jid(
			      lists:concat([Chan, "%", StateData#state.server]),
			      StateData#state.host, FromUser),
			    StateData#state.user,
			    {xmlelement, "message", [{"type", "groupchat"}],
			     [{xmlelement, "body", [],
			       [{xmlcdata, "/me has quit: " ++
				 Msg1 ++ "("  ++ FromIdent ++ ")" }]}]}),

			  ejabberd_router:route(
			    jlib:make_jid(
			      lists:concat([Chan, "%", StateData#state.server]),
			      StateData#state.host, FromUser),
			    StateData#state.user,
			    {xmlelement, "presence", [{"type", "unavailable"}],
			     [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
			       [{xmlelement, "item",
				 [{"affiliation", "member"},
				  {"role", "none"}],
				 []}]},
			      {xmlelement, "status", [],
			       [{xmlcdata, Msg1 ++ "("  ++ FromIdent ++ ")"}]}
			     ]}),
			  remove_element(FromUser, Ps);
		      _ ->
			  Ps
		  end
	  end, StateData#state.channels),
    StateData.


process_join(StateData, Channel, From, String) ->
    [FromUser | FromIdent] = string:tokens(From, "!"),
    Chan = lists:subtract(Channel, ":#"),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "presence", [],
       [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
	 [{xmlelement, "item",
	   [{"affiliation", "member"},
	    {"role", "participant"}],
	   []}]},
	{xmlelement, "status", [],
	 [{xmlcdata, FromIdent}]}]}),
    {ok, Msg, _} = regexp:sub(String, ".*JOIN[^:]*:", ""),    
    Msg1 = filter_message(Msg),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, FromUser),
      StateData#state.user,
      {xmlelement, "message", [{"type", "groupchat"}],
       [{xmlelement, "body", [],
	 [{xmlcdata, "/me has joined " ++
	   Msg1 ++ "("  ++ FromIdent ++ ")" }]}]}),

    case catch dict:update(Chan,
			   fun(Ps) ->
				   ?SETS:add_element(FromUser, Ps)
			   end, StateData#state.channels) of
	{'EXIT', _} ->
	    StateData;
	NS ->
	    StateData#state{channels = NS}
    end.



process_mode_o(StateData, Chan, From, Nick, Affiliation, Role) ->
    %Msg = lists:last(string:tokens(String, ":")),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, Nick),
      StateData#state.user,
      {xmlelement, "presence", [],
       [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
	 [{xmlelement, "item",
	   [{"affiliation", Affiliation},
	    {"role", Role}],
	   []}]}]}).

process_kick(StateData, Chan, From, Nick) ->
    %Msg = lists:last(string:tokens(String, ":")),
    ejabberd_router:route(
      jlib:make_jid(lists:concat([Chan, "%", StateData#state.server]),
		    StateData#state.host, Nick),
      StateData#state.user,
      {xmlelement, "presence", [{"type", "unavailable"}],
       [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
	 [{xmlelement, "item",
	   [{"affiliation", "none"},
	    {"role", "none"}],
	   []},
	  {xmlelement, "status", [{"code", "307"}], []}
	 ]}]}).

process_nick(StateData, From, NewNick) ->
    [FromUser | _] = string:tokens(From, "!"),
    Nick = lists:subtract(NewNick, ":"),
    NewChans =
	dict:map(
	  fun(Chan, Ps) ->
		  case ?SETS:is_member(FromUser, Ps) of
		      true ->
			  ejabberd_router:route(
			    jlib:make_jid(
			      lists:concat([Chan, "%", StateData#state.server]),
			      StateData#state.host, FromUser),
			    StateData#state.user,
			    {xmlelement, "presence", [{"type", "unavailable"}],
			     [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
			       [{xmlelement, "item",
				 [{"affiliation", "member"},
				  {"role", "participant"},
				  {"nick", Nick}],
				 []},
				{xmlelement, "status", [{"code", "303"}], []}
			       ]}]}),
			  ejabberd_router:route(
			    jlib:make_jid(
			      lists:concat([Chan, "%", StateData#state.server]),
			      StateData#state.host, Nick),
			    StateData#state.user,
			    {xmlelement, "presence", [],
			     [{xmlelement, "x", [{"xmlns", ?NS_MUC_USER}],
			       [{xmlelement, "item",
				 [{"affiliation", "member"},
				  {"role", "participant"}],
				 []}
			       ]}]}),
			  ?SETS:add_element(Nick,
					    remove_element(FromUser, Ps));
		      _ ->
			  Ps
		  end
	  end, StateData#state.channels),
    StateData#state{channels = NewChans}.


process_error(StateData, String) ->
    lists:foreach(
      fun(Chan) ->
	      ejabberd_router:route(
		jlib:make_jid(
		  lists:concat([Chan, "%", StateData#state.server]),
		  StateData#state.host, StateData#state.nick),
		StateData#state.user,
		{xmlelement, "presence", [{"type", "error"}],
		 [{xmlelement, "error", [{"code", "502"}],
		   [{xmlcdata, String}]}]})
      end, dict:fetch_keys(StateData#state.channels)).




remove_element(E, Set) ->
    case ?SETS:is_element(E, Set) of
	true ->
	    ?SETS:del_element(E, Set);
	_ ->
	    Set
    end.



iq_admin(StateData, Channel, From, To,
	 #iq{type = Type, xmlns = XMLNS, sub_el = SubEl} = IQ) ->
    case catch process_iq_admin(StateData, Channel, Type, SubEl) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]);
	Res ->
	    if
		Res /= ignore ->
		    ResIQ = case Res of
				{result, ResEls} ->
				    IQ#iq{type = result,
					  sub_el = [{xmlelement, "query",
						     [{"xmlns", XMLNS}],
						     ResEls
						    }]};
				{error, Error} ->
				    IQ#iq{type = error,
					  sub_el = [SubEl, Error]}
			    end,
		    ejabberd_router:route(To, From,
					  jlib:iq_to_xml(ResIQ));
		true ->
		    ok
	    end
    end.


process_iq_admin(StateData, Channel, set, SubEl) ->
    case xml:get_subtag(SubEl, "item") of
	false ->
	    {error, ?ERR_BAD_REQUEST};
	ItemEl ->
	    Nick = xml:get_tag_attr_s("nick", ItemEl),
	    Affiliation = xml:get_tag_attr_s("affiliation", ItemEl),
	    Role = xml:get_tag_attr_s("role", ItemEl),
	    Reason = xml:get_path_s(ItemEl, [{elem, "reason"}, cdata]),
	    process_admin(StateData, Channel, Nick, Affiliation, Role, Reason)
    end;
process_iq_admin(StateData, Channel, get, SubEl) ->
    {error, ?ERR_FEATURE_NOT_IMPLEMENTED}.



process_admin(StateData, Channel, "", Affiliation, Role, Reason) ->
    {error, ?ERR_FEATURE_NOT_IMPLEMENTED};

process_admin(StateData, Channel, Nick, Affiliation, "none", Reason) ->
    case Reason of
	"" ->
	    send_text(StateData,
		      io_lib:format("KICK #~s ~s\r\n",
				    [Channel, Nick]));
	_ ->
	    send_text(StateData,
		      io_lib:format("KICK #~s ~s :~s\r\n",
				    [Channel, Nick, Reason]))
    end,
    {result, []};



process_admin(StateData, Channel, Nick, Affiliation, Role, Reason) ->
    {error, ?ERR_FEATURE_NOT_IMPLEMENTED}.



filter_message(Msg) ->
    lists:filter(
      fun(C) ->
	      if (C < 32) and
		 (C /= 9) and
		 (C /= 10) and
		 (C /= 13) ->
		      false;
		 true -> true
	      end
      end, Msg).
