-module(vm_util).

-export([
    find_nick_by_jid/2,
    get_state_from_jid/1,
    get_room_pid_from_jid/1,
    get_room_state/2,
    set_room_state/3,
    set_room_state_from_jid/2,
    is_healthcheck_room/1,
    room_jid_match_rewrite/1,
    room_jid_match_rewrite/2,
    internal_room_jid_match_rewrite/1,
    internal_room_jid_match_rewrite/2,
    extract_subdomain/1,
    get_subtag_value/2,
    get_subtag_value/3,
    percent_encode/1,
    split_room_and_site/1
]).

-include_lib("xmpp/include/xmpp.hrl").
-include("logger.hrl").
-include("mod_muc_room.hrl").

-type state() :: #state{}.

-spec find_nick_by_jid(jid() | undefined, state()) -> binary().
find_nick_by_jid(undefined, _StateData) ->
    <<>>;
find_nick_by_jid(JID, StateData) ->
    LJID = jid:tolower(JID),
    case maps:find(LJID, StateData#state.users) of
	{ok, #user{nick = Nick}} ->
	    Nick;
	_ ->
	    case maps:find(LJID, (StateData#state.muc_subscribers)#muc_subscribers.subscribers) of
		{ok, #subscriber{nick = Nick}} ->
		    Nick;
		_ ->
		    <<>>
	    end
    end.

-spec is_healthcheck_room(binary()) -> boolean().
is_healthcheck_room(Room) ->
    string:find(Room, <<"__jicofo-health-check">>) == Room.

-spec get_room_state(binary(), binary()) -> {ok, mod_muc_room:state()} | error.
get_room_state(RoomName, MucService) ->
    case room_jid_match_rewrite(jid:make(RoomName, MucService)) of
    #jid{luser = R1, lserver = H1} ->
        case mod_muc:find_online_room(R1, H1) of
        {ok, RoomPid} ->
            get_room_state(RoomPid);
        error ->
            ?INFO_MSG("get_room_state: ~ts@~ts ERROR", [RoomName, MucService]),
            error
        end;
    _ ->
        error
    end.

-spec get_room_state(pid()) -> {ok, mod_muc_room:state()} | error.
get_room_state(RoomPid) ->
    case mod_muc_room:get_state(RoomPid) of
    {ok, State} ->
        {ok, State};
    _ ->
        error
    end.

-spec set_room_state(binary(), binary(), mod_muc_room:state()) -> {ok, mod_muc_room:state()} | {error, notfound | timeout}.
set_room_state(RoomName, MucService, State) ->
    case room_jid_match_rewrite(jid:make(RoomName, MucService)) of
    #jid{luser = R1, lserver = H1} ->
        case mod_muc:find_online_room(R1, H1) of
        {ok, RoomPid} ->
            set_room_state(RoomPid, State);
        error ->
            error
        end;
    _ ->
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

-spec get_room_pid_from_jid(jid()) -> pid() | none.
get_room_pid_from_jid(RoomJid) ->
    { Room, Host, _ } = jid:split(RoomJid),
    mod_muc_admin:get_room_pid(Room, Host).

-spec set_room_state_from_jid(jid(), mod_muc_room:state()) -> {ok, mod_muc_room:state()} | error.
set_room_state_from_jid(RoomJid, State) ->
    case get_room_pid_from_jid(RoomJid) of
    RoomPid when RoomPid /= room_not_found, RoomPid /= invalid_service ->
        set_room_state(RoomPid, State);
    _ ->
        error
    end.

-spec set_room_config_from_jid(jid(), mod_muc_room:config()) -> {ok, mod_muc_room:config()} | {error, notfound | timeout}.
set_room_config_from_jid(RoomJid, Config) ->
    case get_room_pid_from_jid(RoomJid) of
    RoomPid when RoomPid /= room_not_found, RoomPid /= invalid_service ->
        mod_muc_room:set_config(RoomPid, Config);
    _ ->
        error
    end.

% Utility function to split room JID to include room name and subdomain
% (e.g. from room1@conference.foo.example.com/res returns (room1, example.com, res, foo))
room_jid_split_subdomain(RoomJid) ->
    case jid:split(RoomJid) of
    { N, H, R } ->
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
        end;
    _ ->
        error
    end.

% Utility function to check and convert a room JID from
% virtual room1@conference.foo.example.com to real [foo]room1@conference.example.com
% @param room_jid the room jid to match and rewrite if needed
% @param stanza the stanza
% @return returns room jid [foo]room1@conference.example.com when it has subdomain
% otherwise room1@conference.example.com(the room_jid value untouched)
-spec room_jid_match_rewrite(undefined | jid()) -> undefined | jid().
room_jid_match_rewrite(RoomJid) when RoomJid == undefined ->
    undefined;
room_jid_match_rewrite(RoomJid) ->
    room_jid_match_rewrite(RoomJid, undefined).

-spec room_jid_match_rewrite(undefined | jid(), stanza()) -> undefined | jid().
room_jid_match_rewrite(RoomJid, _Stanza) when RoomJid == undefined ->
    undefined;
room_jid_match_rewrite(RoomJid, Stanza) ->
    case room_jid_split_subdomain(RoomJid) of
    {N, H, R, S} ->
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
            % ?INFO_MSG("Rewrote ~ts -> ~ts", [jid:to_string(RoomJid), jid:to_string({N, MucDomain, R})]),
            {N, MucDomain, R};
        _ ->
            NewJid = {<<"[", S/binary, "]", N/binary>>, MucDomain, R},
            % ?INFO_MSG("Rewrote ~ts -> ~ts", [jid:to_string(RoomJid), jid:to_string(NewJid)]),
            NewJid
        end);
    _ ->
        error
    end.

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
-spec internal_room_jid_match_rewrite(undefined | jid()) -> undefined | jid().
internal_room_jid_match_rewrite(RoomJid) when RoomJid == undefined ->
    undefined;
internal_room_jid_match_rewrite(RoomJid) ->
    internal_room_jid_match_rewrite(RoomJid, undefined).

-spec internal_room_jid_match_rewrite(undefined | jid(), stanza()) -> undefined | jid().
internal_room_jid_match_rewrite(RoomJid, _Stanza) when RoomJid == undefined ->
    undefined;
internal_room_jid_match_rewrite(RoomJid, Stanza) ->
    {N, H, R} = jid:split(RoomJid),
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),
    [Prefix, Base] = string:split(MucDomain, "."),

    case {(H /= MucDomain) or (not jid:is_nodename(N)), Stanza == undefined orelse ets:lookup(roomless_iqs, xmpp:get_id(Stanza))} of
    {true, true} -> RoomJid;
    {true, []} -> RoomJid;
    {true, [{_, Result}]} ->
        ets:delete(roomless_iqs, xmpp:get_id(Stanza)),
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


get_subtag_value([El | Els], Name) ->
    get_subtag_value([El | Els], Name, null);
get_subtag_value([], _) -> null.

get_subtag_value([El | Els], Name, Default) ->
    case El of
      #xmlel{name = Name} -> fxml:get_tag_cdata(El);
      _ -> get_subtag_value(Els, Name, Default)
    end;
get_subtag_value([], _, Default) -> Default.

% uri_string did percentage encoding, but encoded hexa are in uppercase, while othe other component
% encode in lowercase. edoc_lib cannot encode utf8 correctly
% https://stackoverflow.com/a/3743323
percent_encode(S) ->
    binary:list_to_bin(escape_uri(S)).
escape_uri(S) when is_list(S) ->
    escape_uri(unicode:characters_to_binary(S));
escape_uri(<<C:8, Cs/binary>>) when C >= $a, C =< $z ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $A, C =< $Z ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $0, C =< $9 ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $. ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $- ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $_ ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) ->
    escape_byte(C) ++ escape_uri(Cs);
escape_uri(<<>>) ->
    "".

escape_byte(C) ->
    "%" ++ hex_octet(C).

hex_octet(N) when N =< 9 ->
    [$0 + N];
hex_octet(N) when N > 15 ->
    hex_octet(N bsr 4) ++ hex_octet(N band 15);
hex_octet(N) ->
    [N - 10 + $a].

split_room_and_site(Room) ->
    case re:run(Room,
        "\\[(?<site>[^\\]]+)\\](?<room>.+)",
        [{capture, [site, room], binary}]) of
    {match, [SiteID, RoomName]} ->
        {RoomName, SiteID};
    _ ->
        {Room, <<"">>}
    end.
