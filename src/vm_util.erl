-module(vm_util).

-export([
    find_nick_by_jid/2,
    get_state_from_jid/1,
    get_room_state/2,
    set_room_state/3,
    is_healthcheck_room/1
]).

-include_lib("xmpp/include/xmpp.hrl").
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
    case mod_muc:find_online_room(RoomName, MucService) of
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
    case mod_muc:find_online_room(RoomName, MucService) of
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
    StartsWith = string:find(H, Prefix) == H,
    case [H, StartsWith] of
    [MucDomain, _] -> [N, H, R, <<>>];
    [_, true] -> [N, H, R, <<>>];
    _ ->
        {ok, RE} = re:compile(<<"^", Prefix/binary, "\.([^.]+)\.", Base/binary, "$">>),
        case re:run(H, RE, [{capture, [1], binary}]) of
        nomatch -> [N, H, R, <<>>];
        {match, [Subdomain]} -> [N, H, R, Subdomain]
        end
    end.

% Utility function to check and convert a room JID from
% virtual room1@conference.foo.example.com to real [foo]room1@conference.example.com
% @param room_jid the room jid to match and rewrite if needed
% @param stanza the stanza
% @return returns room jid [foo]room1@conference.example.com when it has subdomain
% otherwise room1@conference.example.com(the room_jid value untouched)
room_jid_match_rewrite(RoomJid) ->
    [N, H, R, S] = room_jid_split_subdomain(RoomJid),
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),

    [N1, H1, R1] = case [N, H, R, S] of
        [_, _, _, <<"">>] -> [N, H, R];
        [<<"">>, _, _, _] -> [N, MucDomain, R];
        _ -> [<<"[", S/binary, "]", N/binary>>, MucDomain, R]
    end,
            
    jid:make(N1, H1, R1).

