-module(mod_muc_domain_mapper).
-behaviour(gen_mod).

%% gen_mod API callbacks
-export([
    depends/2,
    filter_packet/1,
    mod_doc/0,
    mod_options/1,
    start/2,
    stop/1
]).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").

start(_Host, _Opts) ->
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(roomless_iqs, [named_table, public, set])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(filter_packet, ?MODULE, filter_packet, 10),
    ok.

stop(_Host) ->
    ejabberd_hooks:delete(filter_packet, ?MODULE, filter_packet, 10),
    try ets:delete(roomless_iqs)
    catch
        _:_ -> ok
    end.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_domain_mapper")}.

-spec filter_packet(stanza()) -> stanza().
filter_packet(#iq{sub_els = [#iq_conference{room = Room}]} = Packet) ->
    Packet1 = case string:split(Room, "@") of
    [_] -> Packet;
    [N, H] ->
        NewRoom = jid:to_string(vm_util:room_jid_match_rewrite(jid:make(N, H))),
        xmpp:set_els(Packet, [#iq_conference{room = NewRoom}])
    end,
    filter_packet_from_to(xmpp:get_from(Packet1), xmpp:get_to(Packet1), Packet1);
filter_packet(Packet) ->
    filter_packet_from_to(xmpp:get_from(Packet), xmpp:get_to(Packet), Packet).

-spec filter_packet_from_to(jid() | undefined, jid() | undefined, stanza()) -> stanza().
filter_packet_from_to(From, To, Packet) ->
    From1 = vm_util:internal_room_jid_match_rewrite(From, Packet),
    To1 = vm_util:room_jid_match_rewrite(To, Packet),
    % ?INFO_MSG("mod_muc_domain_mapper ~ts ~ts", [jid:to_string(From1), jid:to_string(To1)]),
    xmpp:set_from_to(Packet, From1, To1).
