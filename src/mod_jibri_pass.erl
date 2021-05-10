-module(mod_jibri_pass).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").


%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_callback/3, mod_doc/0]).

start(Host, _Opts) ->
    ejabberd_hooks:add(muc_filter_presence, Host, ?MODULE, on_callback, 50).

stop(Host) ->
    ejabberd_hooks:delete(muc_filter_presence, Host, ?MODULE, on_callback, 50).

-spec on_callback(presence(), mod_muc_room:state(), binary()) -> presence().
on_callback(Presence, MUCState, _Nick) ->
    FromLuser = Presence#presence.from#jid.luser,
    FromLserver = Presence#presence.from#jid.lserver,
    MUCSubtag = xmpp:get_subtag(Presence, #muc{}),

    JIBRI_RECORDER_USER = list_to_binary(os:getenv("JIBRI_RECORDER_USER")),
    XMPP_RECORDER_DOMAIN = list_to_binary(os:getenv("XMPP_RECORDER_DOMAIN")),

    if
        FromLuser == JIBRI_RECORDER_USER,
        FromLserver == XMPP_RECORDER_DOMAIN,
        MUCSubtag /= false ->
            MUCwPassword = MUCSubtag#muc{password = MUCState#state.config#config.password},
            xmpp:set_subtag(Presence, MUCwPassword);

        true ->
            Presence
    end.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_jibri_pass")}.
