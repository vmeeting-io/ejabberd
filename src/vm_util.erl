-module(vm_util).

-export([
    find_nick_by_jid/2,
    get_state_from_jid/1,
    get_room_state/2,
    set_room_state/3,
    is_healthcheck_room/1,
    room_jid_match_rewrite/1,
    room_jid_match_rewrite/2,
    internal_room_jid_match_rewrite/2,
    filter_packet/1,
    extract_subdomain/1
]).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("mod_muc_room.hrl").

-spec find_nick_by_jid(jid(), mod_muc_room:state()) -> binary() | undefined.
find_nick_by_jid(JID, StateData) ->
    LJID = jid:tolower(JID),
    try maps:get(LJID, StateData#state.users) of
        #user{nick = Nick} -> Nick
    catch
        _:{badkey, _} -> undefined;
        _:{badmap, _} -> undefined
    end.

-spec is_healthcheck_room(binary()) -> boolean().
is_healthcheck_room(Room) ->
    string:find(Room, <<"__jicofo-health-check">>) == Room.

-spec get_room_state(binary(), binary()) -> {ok, mod_muc_room:state()} | error.
get_room_state(RoomName, MucService) ->
    #jid{luser = R1, lserver = H1} = room_jid_match_rewrite(jid:make(RoomName, MucService)),
    case mod_muc:find_online_room(R1, H1) of
	{ok, RoomPid} ->
	    get_room_state(RoomPid);
	error ->
	    error
    end.

-spec get_room_state(pid()) -> {ok, mod_muc_room:state()} | error.
get_room_state(RoomPid) ->
    case mod_muc_room:get_state(RoomPid) of
    {ok, State} ->
        {ok, State};
    {error, _} ->
        error
    end.

-spec set_room_state(binary(), binary(), mod_muc_room:state()) -> {ok, mod_muc_room:state()} | {error, notfound | timeout}.
set_room_state(RoomName, MucService, State) ->
    #jid{luser = R1, lserver = H1} = room_jid_match_rewrite(jid:make(RoomName, MucService)),
    case mod_muc:find_online_room(R1, H1) of
	{ok, RoomPid} ->
	    set_room_state(RoomPid, State);
	error ->
	    error
    end.

-spec set_room_state(pid(), mod_muc_room:state()) -> {ok, mod_muc_room:state()} | {error, notfound | timeout}.
set_room_state(RoomPid, State) ->
    case mod_muc_room:set_state(RoomPid, State) of
    {ok, NewState} ->
        {ok, NewState};
    {error, _} ->
        error
    end.

% Finds and returns room by its jid
% @param room_jid the room jid to search in the muc component
% @return returns room if found or nil
-spec get_state_from_jid(jid()) -> {ok, mod_muc_room:state()} | error.
get_state_from_jid(RoomJid) ->
    { Room, Host, _ } = jid:split(RoomJid),
    get_room_state(Room, Host).

% Utility function to split room JID to include room name and subdomain
% (e.g. from room1@conference.foo.example.com/res returns (room1, example.com, res, foo))
room_jid_split_subdomain(RoomJid) ->
    { N, H, R } = jid:split(RoomJid),
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),
    [Prefix, Base] = string:split(MucDomain, "."),
    case (H == MucDomain) or (string:find(H, Prefix) /= H) of
    true -> {N, H, R, <<>>};
    false ->
        {ok, RE} = re:compile(<<"^", Prefix/binary, "\.([^.]+)\.", Base/binary, "$">>),
        case re:run(H, RE, [{capture, [1], binary}]) of
        nomatch -> {N, H, R, <<>>};
        {match, [Subdomain]} -> 
            % ?INFO_MSG("room_jid_split_subdomain ~p", [{N, H, R, Subdomain}]),
            {N, H, R, Subdomain}
        end
    end.

% Utility function to check and convert a room JID from
% virtual room1@conference.foo.example.com to real [foo]room1@conference.example.com
% @param room_jid the room jid to match and rewrite if needed
% @param stanza the stanza
% @return returns room jid [foo]room1@conference.example.com when it has subdomain
% otherwise room1@conference.example.com(the room_jid value untouched)
room_jid_match_rewrite(RoomJid) ->
    room_jid_match_rewrite(RoomJid, undefined).

room_jid_match_rewrite(RoomJid, Stanza) ->
    {N, H, R, S} = room_jid_split_subdomain(RoomJid),
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),

    jid:make(case {N, H, R, S} of
    {_, _, _, <<"">>} ->
        {N, H, R};
    {<<"">>, _, _, _} ->
        Result = (Stanza /= undefined) and (xmpp:get_id(Stanza) /= <<>>),
        if Result ->
            ets:insert(roomless_iqs, {xmpp:get_id(Stanza), xmpp:get_to(Stanza)});
        true -> ok
        end,
        % ?INFO_MSG("Rewrote to ~ts", [jid:to_string({N, MucDomain, R})]),
        {N, MucDomain, R};
    _ ->
        NewJid = {<<"[", S/binary, "]", N/binary>>, MucDomain, R},
        % ?INFO_MSG("Rewrote to ~ts", [jid:to_string(NewJid)]),
        NewJid
    end).

% Extracts the subdomain and room name from internal jid node [foo]room1
% @return subdomain(optional, if extracted or nil), the room name
extract_subdomain(Room) ->
    % optimization, skip matching if there is no subdomain, no [subdomain] part in the beginning of the node
    case string:find(Room, "[") of
    Room -> 
        {ok, RE} = re:compile(<<"^\\[([^\\]]+)\\](.+)$">>),
        {match, [Subdomain, Node]} = re:run(Room, RE, [{capture, [1,2], binary}]),
        {Subdomain, Node};
    _ -> {<<>>, Room}
    end.

% Utility function to check and convert a room JID from real [foo]room1@muc.example.com to virtual room1@muc.foo.example.com
internal_room_jid_match_rewrite(RoomJid, Stanza) ->
    {N, H, R} = jid:split(RoomJid),
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),
    [Prefix, Base] = string:split(MucDomain, "."),
    Id = xmpp:get_id(Stanza),

    case {(H /= MucDomain) or (not jid:is_nodename(N)), ets:lookup(roomless_iqs, Id)} of
    {true, []} -> RoomJid;
    {true, [{_, Result}]} -> 
        ets:delete(roomless_iqs, Id),
        Result;
    _ -> 
        case extract_subdomain(N) of
        {Subdomain, Node} -> 
            % Ok, rewrite room_jid address to pretty format
            NewRoomJid = jid:make({Node, <<Prefix/binary, ".", Subdomain/binary, ".", Base/binary>>, R}),
            ?DEBUG("Rewrote to ~ts", [jid:to_string(NewRoomJid)]),
            NewRoomJid;
        _ -> 
            ?DEBUG("Not rewriting... unexpected node format: ~ts", [N]),
            RoomJid
        end
    end.

-spec filter_packet(stanza()) -> stanza().
filter_packet(#iq{sub_els = [#iq_conference{room = Room}]} = Packet) ->
    Packet1 = case string:split(Room, "@") of
    [_] -> Packet;
    [N, H] ->
        NewRoom = jid:to_string(room_jid_match_rewrite(jid:make(N, H))),
        xmpp:set_els(Packet, [#iq_conference{room = NewRoom}])
    end,
    Packet2 = filter_packet_from(Packet1, xmpp:get_from(Packet1)),
    filter_packet_to(Packet1, xmpp:get_to(Packet2));
filter_packet(Packet) ->
    Packet1 = filter_packet_from(Packet, xmpp:get_from(Packet)),
    filter_packet_to(Packet1, xmpp:get_to(Packet)).

-spec filter_packet_from(stanza(), jid()) -> stanza().
filter_packet_from(Packet, undefined) ->
    Packet;
filter_packet_from(Packet, From) ->
    From1 = internal_room_jid_match_rewrite(From, Packet),
    ?DEBUG("filter_packet2: from(~ts -> ~ts)", [jid:to_string(From), jid:to_string(From1)]),
    xmpp:set_from(Packet, From1).

-spec filter_packet_to(stanza(), jid()) -> stanza().
filter_packet_to(Packet, undefined) ->
    Packet;
filter_packet_to(Packet, To) ->
    To1 = room_jid_match_rewrite(To, Packet),
    ?DEBUG("filter_packet2: to(~ts -> ~ts)", [jid:to_string(To), jid:to_string(To1)]),
    xmpp:set_to(Packet, To1).