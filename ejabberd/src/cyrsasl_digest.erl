%%%----------------------------------------------------------------------
%%% File    : cyrsasl_digest.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : DIGEST-MD5 SASL mechanism
%%% Created : 11 Mar 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: cyrsasl_digest.erl 307 2005-04-17 18:08:34Z tmallard $
%%%----------------------------------------------------------------------

-module(cyrsasl_digest).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/1,
	 stop/0,
	 mech_new/2,
	 mech_step/2]).

-behaviour(cyrsasl).

-record(state, {step, nonce, username, authzid, get_password}).

start(_Opts) ->
    case ejabberd_auth:plain_password_required() of
	true ->
	    ok;
	false ->
	    cyrsasl:register_mechanism("DIGEST-MD5", ?MODULE),
	    ok
    end.

stop() ->
    ok.

mech_new(GetPassword, _CheckPassword) ->
    {ok, #state{step = 1,
		nonce = randoms:get_string(),
		get_password = GetPassword}}.

mech_step(#state{step = 1, nonce = Nonce} = State, _) ->
    {continue,
     "nonce=\"" ++ Nonce ++
     "\",qop=\"auth\",charset=utf-8,algorithm=md5-sess",
     State#state{step = 3}};
mech_step(#state{step = 3, nonce = Nonce} = State, ClientIn) ->
    case parse(ClientIn) of
	bad ->
	    {error, "bad-protocol"};
	KeyVals ->
	    UserName = xml:get_attr_s("username", KeyVals),
	    AuthzId = xml:get_attr_s("authzid", KeyVals),
	    case (State#state.get_password)(UserName) of
		false ->
		    {error, "not-authorized"};
		Passwd ->
		    Response = response(KeyVals, UserName, Passwd,
					Nonce, AuthzId, "AUTHENTICATE"),
		    case xml:get_attr_s("response", KeyVals) of
			Response ->
			    RspAuth = response(KeyVals,
					       UserName, Passwd,
					       Nonce, AuthzId, ""),
			    {continue,
			     "rspauth=" ++ RspAuth,
			     State#state{step = 5,
					 username = UserName,
					 authzid = AuthzId}};
			_ ->
			    {error, "not-authorized"}
		    end
	    end
    end;
mech_step(#state{step = 5,
		 username = UserName,
		 authzid = AuthzId}, "") ->
    {ok, [{username, UserName}, {authzid, AuthzId}]};
mech_step(A, B) ->
    io:format("SASL DIGEST: A ~p B ~p", [A,B]),
    {error, "bad-protocol"}.


parse(S) ->
    parse1(S, "", []).

parse1([$= | Cs], S, Ts) ->
    parse2(Cs, lists:reverse(S), "", Ts);
parse1([C | Cs], S, Ts) ->
    parse1(Cs, [C | S], Ts);
parse1([], [], T) ->
    lists:reverse(T);
parse1([], _S, _T) ->
    bad.

parse2([$" | Cs], Key, Val, Ts) ->
    parse3(Cs, Key, Val, Ts);
parse2([C | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, [C | Val], Ts);
parse2([], _, _, _) ->
    bad.

parse3([$" | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, Val, Ts);
parse3([C | Cs], Key, Val, Ts) ->
    parse3(Cs, Key, [C | Val], Ts);
parse3([], _, _, _) ->
    bad.

parse4([$, | Cs], Key, Val, Ts) ->
    parse1(Cs, "", [{Key, lists:reverse(Val)} | Ts]);
parse4([C | Cs], Key, Val, Ts) ->
    parse4(Cs, Key, [C | Val], Ts);
parse4([], Key, Val, Ts) ->
    parse1([], "", [{Key, lists:reverse(Val)} | Ts]).






digit_to_xchar(D) when (D >= 0) and (D < 10) ->
    D + 48;
digit_to_xchar(D) ->
    D + 87.

hex(S) ->
    hex(S, []).

hex([], Res) ->
    lists:reverse(Res);
hex([N | Ns], Res) ->
    hex(Ns, [digit_to_xchar(N rem 16),
	     digit_to_xchar(N div 16) | Res]).


response(KeyVals, User, Passwd, Nonce, AuthzId, A2Prefix) ->
    Realm = xml:get_attr_s("realm", KeyVals),
    CNonce = xml:get_attr_s("cnonce", KeyVals),
    DigestURI = xml:get_attr_s("digest-uri", KeyVals),
    NC = xml:get_attr_s("nc", KeyVals),
    QOP = xml:get_attr_s("qop", KeyVals),
    A1 = case AuthzId of
	     "" ->
		 binary_to_list(
		   crypto:md5(User ++ ":" ++ Realm ++ ":" ++ Passwd)) ++
		     ":" ++ Nonce ++ ":" ++ CNonce;
	     _ ->
		 binary_to_list(
		   crypto:md5(User ++ ":" ++ Realm ++ ":" ++ Passwd)) ++
		     ":" ++ Nonce ++ ":" ++ CNonce ++ ":" ++ AuthzId
	 end,
    A2 = case QOP of
	     "auth" ->
		 A2Prefix ++ ":" ++ DigestURI;
	     _ ->
		 A2Prefix ++ ":" ++ DigestURI ++
		     ":00000000000000000000000000000000"
	 end,
    T = hex(binary_to_list(crypto:md5(A1))) ++ ":" ++ Nonce ++ ":" ++
	NC ++ ":" ++ CNonce ++ ":" ++ QOP ++ ":" ++
	hex(binary_to_list(crypto:md5(A2))),
    hex(binary_to_list(crypto:md5(T))).



