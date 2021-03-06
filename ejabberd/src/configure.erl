%%%----------------------------------------------------------------------
%%% File    : configure.erl
%%% Author  : Alexey Shchepin <alexey@sevcom.net>
%%% Purpose : 
%%% Created : 27 Jan 2003 by Alexey Shchepin <alexey@sevcom.net>
%%% Id      : $Id: configure.erl 259 2004-08-22 21:54:14Z aleksey $
%%%----------------------------------------------------------------------

-module(configure).
-author('alexey@sevcom.net').
-vsn('$Revision$ ').

-export([start/0]).

-include("ejabberd.hrl").

start() ->
    Static = case os:getenv("arg") of
		 false ->
		     false;
		 "static" ->
		     true;
		 _ ->
		     false
	     end,
    case Static of
	true ->
	    ExpatLib  = "EXPAT_LIB = $(EXPAT_DIR)\\StaticLibs\\libexpatMT.lib\n",
	    ExpatFlag = "EXPAT_FLAG = -DXML_STATIC\n",
	    IconvDir  = "ICONV_DIR = c:\\progra~1\\libiconv-1.9.1-static\n",
	    IconvLib  = "ICONV_LIB = $(ICONV_DIR)\\lib\\iconv.lib\n";
	false ->
	    ExpatLib  = "EXPAT_LIB = $(EXPAT_DIR)\\Libs\\libexpat.lib\n",
	    ExpatFlag = "",
	    IconvDir  = "ICONV_DIR = c:\\progra~1\\libiconv-1.9.1\n",
	    IconvLib  = "ICONV_LIB = $(ICONV_DIR)\\lib\\iconv.lib\n"
    end,

    EIDirS   = "EI_DIR = " ++ code:lib_dir("erl_interface") ++ "\n",
    RootDirS = "ERLANG_DIR = " ++ code:root_dir() ++ "\n",
    Version  = "EJABBERD_VERSION = " ++ ?VERSION ++ "\n",
    ExpatDir = "EXPAT_DIR = c:\\progra~1\\expat-1.95.7\n",
    OpenSSLDir = "OPENSSL_DIR = c:\\progra~1\\OpenSSL\n",

    SSLDir    = "SSLDIR = " ++ code:lib_dir("ssl") ++ "\n",
    StdLibDir = "STDLIBDIR = " ++ code:lib_dir("stdlib") ++ "\n",

    file:write_file("Makefile.inc",
		    list_to_binary(EIDirS ++
				   RootDirS ++
				   Version ++
				   SSLDir ++
				   StdLibDir ++
				   OpenSSLDir ++
				   ExpatDir ++
				   ExpatLib ++
				   ExpatFlag ++
				   IconvDir ++
				   IconvLib)),
    halt().


