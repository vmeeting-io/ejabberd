-module(mod_muc_breakout_rooms).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").
-include("ejabberd_http.hrl").
-include("vmeeting_common.hrl").

-define(BROADCAST_ROOMS_INTERVAL, 0.3).
-define(ROOMS_TTL_IF_ALL_LEFT, 5).
-define(JSON_TYPE_ADD_BREAKOUT_ROOM, <<"features/breakout-rooms/add">>).
-define(JSON_TYPE_MOVE_TO_ROOM_REQUEST, <<"features/breakout-rooms/move-to-room-request">>).
-define(JSON_TYPE_REMOVE_BREAKOUT_ROOM, <<"features/breakout-rooms/remove">>).
-define(JSON_TYPE_UPDATE_BREAKOUT_ROOMS, <<"features/breakout-rooms/update">>).


%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_doc/0,
    process_message/1, on_start_room/4, on_room_destroyed/4, disco_local_identity/5,
    on_join_room/6, on_leave_room/4, on_check_create_room/4,
    destroy_main_room/1, update_breakout_rooms/1]).

start(Host, _Opts) ->
    ?INFO_MSG("muc_breakout_rooms:start ~ts", [Host]),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(leave_room, Host, ?MODULE, on_leave_room, 100),
    % ejabberd_hooks:add(check_create_room, Host, ?MODULE, on_check_create_room, 100),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, process_message, 100),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(leave_room, Host, ?MODULE, on_leave_room, 100),
    % ejabberd_hooks:delete(check_create_room, Host, ?MODULE, on_check_create_room, 100),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, process_message, 100),
    ejabberd_hooks:delete(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_breakout_rooms")}.

breakout_room_muc() ->
    [ServerHost | _RestServers] = ejabberd_option:hosts(),
    <<"breakout.", ServerHost/binary>>.

send_timeout(Time, Func, Args) ->
    Pid = spawn(?MODULE, Func, Args),
    erlang:send_after(Time, Pid, timeout).

% Utility functions
get_main_room_jid(#jid{luser = Room, lserver = Host} = RoomJid) ->
    {ok, Suffix} = re:compile("_[-0-9a-fA-F]+$"),
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    case {string:equal(Host, MucHost), re:replace(binary_to_list(Room), Suffix, "", [{return, binary}])} of
    {true, _} ->
        RoomJid;
    {_, RoomName} ->
        LRoomName = jid:nodeprep(RoomName),
        RoomJid#jid{
            user = RoomName, luser = LRoomName,
            server = MucHost, lserver = MucHost}
    end.

get_main_room(RoomJid) ->
    MainRoomJid = get_main_room_jid(RoomJid),
    case vm_util:get_state_from_jid(MainRoomJid) of
    {ok, State} ->
        ?INFO_MSG("get_main_room(~ts): ok, state", [jid:encode(MainRoomJid)]),
        {State, MainRoomJid};
    _ ->
        ?INFO_MSG("get_main_room(~ts): unknown, state", [jid:encode(MainRoomJid)]),
        {undefined, MainRoomJid}
    end.

send_json_msg(RoomJid, To, JsonMsg)
    when RoomJid /= undefined, To /= undefined ->
    ejabberd_router:route(#message{
        to = To,
        type = chat,
        from = RoomJid,
        sub_els = [#json_message{data=JsonMsg}]
    }).

broadcast_json_msg(State, JsonMsg)
    when State /= undefined ->
    mod_muc_room:broadcast_json_msg(State, <<"">>, JsonMsg).

get_participants(State) ->
    maps:fold(fun(K, V, Acc) ->
        % Filter focus as we keep it as a hidden participant
        case K of
        {<<"focus">>, _, _} ->
            Acc;
        _ ->
            DisplayName = vm_util:get_subtag_value(
                (V#user.last_presence)#presence.sub_els,
                <<"nick">>),
            maps:put(V#user.nick, #{
                jid => jid:to_string(V#user.jid),
                role => V#user.role,
                displayName => DisplayName
            }, Acc)
        end
    end, #{}, State#state.users).

update_breakout_rooms(RoomJid) ->
    receive
    timeout ->
        ?INFO_MSG("update_breakout_rooms: ~ts", [jid:encode(RoomJid)]),
        case vm_util:get_state_from_jid(RoomJid) of
        {ok, State} ->
            State2 = State#state{ is_broadcast_breakout_scheduled = false },
            vm_util:set_room_state_from_jid(RoomJid, State2),

            Node = RoomJid#jid.luser,
            Subject = case State2#state.subject of
                [] ->
                    {R, _} = vm_util:split_room_and_site(State2#state.room),
                    R;
                [T|_] -> T
            end,
            Rooms = #{ Node => #{
                isMainRoom => true,
                id => Node,
                jid => jid:to_string(RoomJid),
                name => Subject,
                participants => get_participants(State2)
            }},

            Rooms2 = maps:fold(fun(K, V, Acc) ->
                BreakoutJid  = jid:decode(K),
                BreakoutNode = BreakoutJid#jid.luser,
                Info = #{ id => BreakoutNode, jid => K, name => V },
                Info1 = case vm_util:get_state_from_jid(BreakoutJid) of
                    {ok, BreakoutRoomState} ->
                        maps:put(
                            participants,
                            get_participants(BreakoutRoomState),
                            Info);
                    _ ->
                        Info
                    end,
                maps:put(BreakoutNode, Info1, Acc)
            end, Rooms, State2#state.breakout_rooms),

            JsonMsg = #{
                type => ?JSON_TYPE_UPDATE_BREAKOUT_ROOMS,
                nextIndex => State2#state.next_index,
                rooms => Rooms2
            },

            broadcast_json_msg(State2, JsonMsg),
            lists:foreach(fun({K, _}) ->
                case vm_util:get_state_from_jid(jid:decode(K)) of
                {ok, S0} ->
                    broadcast_json_msg(S0, JsonMsg);
                _ ->
                    ok
                end
            end, maps:to_list(State2#state.breakout_rooms));
        _ ->
            error
        end;
    _ ->
        ?INFO_MSG("Unknown message received.", [])
    end.

broadcast_breakout_rooms(RoomJid) ->
    case get_main_room(RoomJid) of
    { State, MainRoomJid }
    when State /= undefined, State#state.is_broadcast_breakout_scheduled /= true ->
        % Only send each BROADCAST_ROOMS_INTERVAL seconds to prevent flooding of messages.
        ?INFO_MSG("broadcast_breakout_rooms: ~ts", [jid:encode(MainRoomJid)]),
        State1 = State#state{ is_broadcast_breakout_scheduled = true },
        vm_util:set_room_state_from_jid(MainRoomJid, State1),
        send_timeout(300, update_breakout_rooms, [MainRoomJid]);
    _ ->
        ok
    end.


% Managing breakout rooms

create_breakout_room(State, RoomJid, Subject, NextIndex) ->
    % Breakout rooms are named like the main room with a random uuid suffix
    RoomName = RoomJid#jid.luser,
    RandUUID = list_to_binary(uuid:uuid_to_string(uuid:get_v4())),
    BreakoutRoom = <<RoomName/binary, "_", RandUUID/binary>>,
    BreakoutRoomJid = jid:make(BreakoutRoom, breakout_room_muc()),

    BreakoutRooms = State#state.breakout_rooms,
    vm_util:set_room_state_from_jid(RoomJid, State#state{
        breakout_rooms = maps:put(jid:encode(BreakoutRoomJid), Subject, BreakoutRooms),
        next_index = NextIndex
    }),

    % Make room persistent - not to be destroyed - if all participants join breakout rooms.
    RoomPid = vm_util:get_room_pid_from_jid(RoomJid),
    mod_muc_admin:change_room_option(RoomPid, persistent, true),
    broadcast_breakout_rooms(RoomJid).

destroy_breakout_room(MainState, RoomJid, Message) ->
    ?INFO_MSG("destory_breakout_room: ~p", [RoomJid]),
    case get_main_room(RoomJid) of
    { _, MainJid } when MainJid /= RoomJid ->
        BreakoutRooms = MainState#state.breakout_rooms,
        vm_util:set_room_state_from_jid(MainJid, MainState#state{
            breakout_rooms = maps:remove(jid:encode(RoomJid), BreakoutRooms)
        }),
        broadcast_breakout_rooms(MainJid),
        case vm_util:get_state_from_jid(RoomJid) of
        { ok, _ } ->
            mod_muc_room:destroy(vm_util:get_room_pid_from_jid(RoomJid), Message);
        _ ->
            ok
        end;
    _ ->
        ok
    end.

destroy_breakout_room(MainState, RoomJid) ->
    destroy_breakout_room(MainState, RoomJid, <<"Breakout room removed.">>).


% Handling events

process_message({#message{
    to = #jid{lresource = Res} = To,
    from = From
} = Packet, State}) ->
    case vm_util:get_subtag_value(Packet#message.sub_els, <<"json-message">>) of
    Data when Data /= null ->
	    Message = jiffy:decode(Data, [return_maps]),
        ?INFO_MSG("decoded message: ~p", [Message]),
        Type = maps:get(<<"type">>, Message),
        RoomJid = vm_util:room_jid_match_rewrite(jid:remove_resource(To)),
        case get_main_room(RoomJid) of
        {MainState, MainJid} ->
            case {mod_muc_room:get_affiliation(From, MainState), Type} of
            {owner, ?JSON_TYPE_ADD_BREAKOUT_ROOM} ->
                Subject = maps:get(<<"subject">>, Message),
                NextIndex = maps:get(<<"nextIndex">>, Message),
                create_breakout_room(MainState, MainJid, Subject, NextIndex),
                {drop, State};
            {owner, ?JSON_TYPE_REMOVE_BREAKOUT_ROOM} ->
                BreakoutRoomJid = maps:get(<<"breakoutRoomJid">>, Message),
                destroy_breakout_room(MainState, jid:decode(BreakoutRoomJid)),
                {drop, State};
            {owner, ?JSON_TYPE_MOVE_TO_ROOM_REQUEST} ->
                Nick = jid:decode(To#jid.resource),
                ParticipantRoomJid = vm_util:room_jid_match_rewrite(Nick),
                case vm_util:get_state_from_jid(ParticipantRoomJid) of
                { ok, ParticipantRoomState } ->
                    Occupant = maps:get(jid:tolower(Nick), ParticipantRoomState#state.users),
                    send_json_msg(ParticipantRoomState, Occupant#user.jid, Data)
                end,
                {drop, State}
            end;
        _ ->
            {Packet, State}
        end;
    _ ->
        {Packet, State}
    end;
process_message({Packet, State}) ->
    {Packet, State}.

on_join_room(State, _ServerHost, Packet, From, _RoomID, _Nick) ->
    MainMuc = gen_mod:get_module_opt(global, mod_muc, host),

    if MainMuc == Packet#presence.to#jid.server ->
        RoomJid = Packet#presence.to,

        ?INFO_MSG("breakout_rooms:on_join_room: ~ts, ~ts", [jid:encode(RoomJid), jid:encode(From)]),
        if From#jid.user /= <<"focus">> ->
            broadcast_breakout_rooms(RoomJid);
        true ->
            ok
        end,

        if State#state.is_close_all_scheduled == true ->
            % Prevent closing all rooms if a participant has joined (see on_occupant_left).
            State#state{ is_close_all_scheduled = false };
        true ->
            State
        end;
    true ->
        State
    end.

exist_occupants_in_room(State) ->
    State /= undefined andalso lists:any(
        fun({_K, V}) -> (V#user.jid)#jid.luser /= <<"focus">> end,
        maps:to_list(State#state.users)
    ).


exist_occupants_in_rooms(State) ->
    exist_occupants_in_room(State) orelse lists:any(
        fun({K, _V}) ->
            case vm_util:get_state_from_jid(jid:make(K)) of
            { ok, RoomState } ->
                exist_occupants_in_room(RoomState);
            _ ->
                false
            end
        end,
        maps:to_list(State#state.breakout_rooms)
    ).


destroy_room(RoomJID, Message) ->
    RoomPID = vm_util:get_room_pid_from_jid(RoomJID),
    if RoomPID == room_not_found; RoomPID == invalid_service ->
        ?INFO_MSG("destroy_room ERROR: ~p", [RoomPID]),
        ok;
    true ->
        Mes = binary:list_to_bin(io_lib:format(Message, [])),
        mod_muc_room:kick_all(RoomPID, Mes),
        ?INFO_MSG("destroy_room success: ~p", [RoomPID])
    end.

-spec disco_local_identity([identity()], jid(), jid(),
			   binary(), binary()) -> [identity()].
disco_local_identity(Acc, _From, To, <<>>, _Lang) ->
    ToServer = To#jid.server,
    [#identity{category = <<"component">>,
	       type = <<"breakout_rooms">>,
	       name = <<"breakout.", ToServer/binary>>}
    | Acc];
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.


destroy_main_room(RoomJid) ->
    receive
    timeout ->
        ?INFO_MSG("Destroy main room ~ts as all left for good.", [jid:encode(RoomJid)]),
        Pid = vm_util:get_room_pid_from_jid(RoomJid),
        mod_muc_admin:change_room_option(Pid, persistent, false),
        mod_muc_room:destroy(Pid, <<"All occupants left.">>);
    _ ->
        ?INFO_MSG("Unknown message received", [])
    end.

on_leave_room(_ServerHost, Room, Host, JID) ->
    RoomJid = jid:make(Room, Host),
    ?INFO_MSG("breakout_rooms:on_leave_room: ~ts, ~ts", [jid:encode(RoomJid), jid:encode(JID)]),
    (JID#jid.user /= <<"focus">>) 
        andalso broadcast_breakout_rooms(RoomJid),

    case get_main_room(RoomJid) of
    { undefined, _ } ->
        ok;
    { State, MainRoomJid } ->
        % Close the conference if all left for good.
        ?INFO_MSG("on_leave_room: mainRoomState = ~p", [State]),
        ExistOccupantsInRooms = exist_occupants_in_rooms(State),
        if not State#state.is_close_all_scheduled and not ExistOccupantsInRooms ->
            vm_util:set_room_state_from_jid(MainRoomJid, State#state{
                is_close_all_scheduled = true
            }),
            send_timeout(
                ?ROOMS_TTL_IF_ALL_LEFT * 1000,
                destroy_main_room,
                [MainRoomJid]);
        true ->
            ok
        end
    end.


on_check_create_room(Acc, ServerHost, Room, Host) when Acc == true ->
    if ServerHost == Host ->
        RoomJid = jid:make(Room, Host),
        ?INFO_MSG("breakout_rooms:on_check_create_room: ~ts", [jid:encode(RoomJid)]),

        { MainRoomState, MainRoomJid } = get_main_room(RoomJid),
        case (MainRoomState /= undefined)
            andalso maps:get(jid:encode(RoomJid), MainRoomState#state.breakout_rooms, null) of
        Subject when Subject /= null, Subject /= false ->
            true;
        _ ->
            ?INFO_MSG("Invalid breakout room ~ts will not be created.", [jid:encode(RoomJid)]),
            destroy_room(MainRoomJid, "invalid_breakout_room"),
            false
        end;
    true ->
        true
    end.

on_start_room(State, ServerHost, Room, Host) ->
    ?INFO_MSG("breakout_rooms:on_start_room: ~ts, ~ts", [Room, Host]),
    if ServerHost == Host ->
        RoomJid = jid:make(Room, Host),
        case get_main_room(RoomJid) of
        { MainRoomState, _ } when MainRoomState /= undefined ->
            Subject = maps:get(jid:encode(RoomJid), MainRoomState#state.breakout_rooms, null),
            if Subject /= null ->
                State#state{subject = Subject};
            true ->
                State
            end;
        _ ->
            State
        end;
    true ->
        State
    end.

on_room_destroyed(State, _ServerHost, _Room, _Host) ->
    ?INFO_MSG("breakout_rooms:on_room_destory", []),
    Message = <<"Conference ended.">>,
    lists:foreach(
        fun({K, _}) -> destroy_breakout_room(State, jid:decode(K), Message) end,
        maps:to_list(State#state.breakout_rooms)
    ).
