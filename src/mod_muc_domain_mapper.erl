-module(mod_muc_domain_mapper).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").

%% gen_mod API callbacks
-export([
    depends/2,
    filter_packet/1,
    mod_doc/0,
    mod_options/1,
    start/2,
    stop/1
]).

start(_Host, _Opts) ->
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(roomless_iqs, [named_table, public, set])
    catch
        _:badarg -> ok
    end,

    % ejabberd_hooks:add(filter_packet, Host, ?MODULE, filter_packet, 10),
    ok.

stop(_Host) ->
    % ejabberd_hooks:delete(filter_packet, Host, ?MODULE, filter_packet, 10),
    ets:delete(roomless_iqs),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    ?INFO_MSG("mod_muc_domain_mapper ~ts", [_Host]),
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_domain_mapper")}.

filter_packet(Packet) ->
    ?INFO_MSG("filter_packet1: ~ts -> ~ts", [jid:to_string(xmpp:get_from(Packet)), jid:to_string(xmpp:get_to(Packet))]),
    To = xmpp:get_to(Packet),
    From = xmpp:get_from(Packet),
    Packet1 = case To of
        undefined ->
            Packet;
        _ -> 
            To1 = vm_util:room_jid_match_rewrite(To, Packet),
            ?INFO_MSG("filter_packet2: to(~ts -> ~ts)", [jid:to_string(To), jid:to_string(To1)]),
            xmpp:set_to(Packet, To1)
        end,
    case From of
        undefined ->
            Packet1;
        _ ->
            From1 = vm_util:internal_room_jid_match_rewrite(From, Packet1),
            ?INFO_MSG("filter_packet2: from(~ts -> ~ts)", [jid:to_string(From), jid:to_string(From1)]),
            xmpp:set_from(Packet1, From1)
        end.
