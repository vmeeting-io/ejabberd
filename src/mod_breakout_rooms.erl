-module(mod_breakout_rooms).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").
-include("ejabberd_http.hrl").

-define(BROADCAST_ROOMS_INTERVAL, 0.3).
-define(ROOMS_TTL_IF_ALL_LEFT, 5).
-define(JSON_TYPE_ADD_BREAKOUT_ROOM, <<"features/breakout-rooms/add">>).
-define(JSON_TYPE_MOVE_TO_ROOM_REQUEST, <<"features/breakout-rooms/move-to-room-request">>).
-define(JSON_TYPE_REMOVE_BREAKOUT_ROOM, <<"features/breakout-rooms/remove">>).
-define(JSON_TYPE_UPDATE_BREAKOUT_ROOMS, <<"features/breakout-rooms/update">>).
-define(BREAKOUT_ROOMS_SUFFIX_PATTERN, "_breakout-[-0-9a-fA-F]+$").


%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_doc/0,
    process_message/1, check_create_room/4,
    on_start_room/4, on_room_destroyed/4, on_join_room/4, on_leave_room/4]).

start(Host, _Opts) ->
    ejabberd_hooks:add(start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:add(join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:add(local_send_to_resource_hook, Host, ?MODULE, process_message, 50),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ejabberd_hooks:add(check_create_room, Host, ?MODULE, check_create_room, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:delete(join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:delete(local_send_to_resource_hook, Host, ?MODULE, process_message, 50),
    ejabberd_hooks:delete(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ejabberd_hooks:delete(check_create_room, Host, ?MODULE, check_create_room, 50),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_breakout_rooms")}.

% Utility functions
get_main_room_jid(#jid{user = Room} = RoomJid) ->
    {ok, Suffix} = re:compile(?BREAKOUT_ROOMS_SUFFIX_PATTERN),
    case re:replace(binary_to_list(Room), Suffix, "") of
    [RoomName, _] ->
        LRoomName = jid:nodeprep(RoomName),
        RoomJid#jid{user = RoomName, luser = LRoomName};
    _ ->
        RoomJid
    end.

get_main_room(RoomJid) ->
    MainRoomJid = get_main_room_jid(RoomJid),
    case vm_util:get_state_from_jid(MainRoomJid) of
    {ok, State} ->
        {State, MainRoomJid};
    _ ->
        {undefined, MainRoomJid}
    end.

send_json_msg(RoomJid, To, JsonMsg)
    when RoomJid /= undefined, To /= undefined ->
    ejabberd_router:route(#message{
        to = To,
        type = chat,
        from = jid:replace_resource(RoomJid, <<"focus">>),
        sub_els = [#json_message{data=JsonMsg}]
    }).

broadcast_json_msg(State, JsonMsg)
    when State /= undefined ->
    mod_muc_room:broadcast_json_msg(State, <<"focus">>, JsonMsg).

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

broadcast_breakout_rooms(RoomJid) ->
    case get_main_room(RoomJid) of
    { State, MainRoomJid } when State#state.is_broadcast_breakout_scheduled /= true ->
        % Only send each BROADCAST_ROOMS_INTERVAL seconds to prevent flooding of messages.
        State1 = State#state{ is_broadcast_breakout_scheduled = true },
        { Room, Host, _ } = jid:split(MainRoomJid),
        vm_util:set_room_state(Room, Host, State1),
        timer:apply_after(
            ?BROADCAST_ROOMS_INTERVAL * 1000,
            mod_breakout_rooms,
            fun(S, JID) ->
                S2 = S#state{ is_broadcast_breakout_scheduled = false },
                Node = JID#jid.luser,
                vm_util:set_room_state(Node, JID#jid.lserver, S2),

                Rooms = #{ Node => #{
                    isMainRoom => true,
                    id => Node,
                    jid => jid:to_string(JID),
                    name => S2#state.subject,
                    participants => get_participants(S2)
                }},

                Rooms2 = maps:fold(fun(K, V, Acc) ->
                    BreakoutJid  = jid:make(K),
                    BreakoutNode = BreakoutJid#jid.luser,
                    Info = #{ id => BreakoutNode, jid => jid:to_string(BreakoutJid), name => V },
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
                end, Rooms, S2#state.breakout_rooms),

                JsonMsg = jiffy:encode(#{
                    type => ?JSON_TYPE_UPDATE_BREAKOUT_ROOMS,
                    nextIndex => S2#state.next_index,
                    rooms => Rooms2
                }),

                broadcast_json_msg(S2, JsonMsg),
                maps:foreach(fun(K, _V) ->
                    case vm_util:get_state_from_jid(jid:make(K)) of
                    {ok, S0} ->
                        broadcast_json_msg(S0, JsonMsg)
                    end
                end, S2#state.breakout_rooms),
                ok
            end,
            [State1, MainRoomJid]
        )
    end.


% Managing breakout rooms

create_breakout_room(RoomJid, _From, Subject, NextIndex) ->
    case get_main_room(RoomJid) of
    { State, MainRoomJid } ->
        % Breakout rooms are named like the main room with a random uuid suffix
        MainRoom = MainRoomJid#jid.luser,
        RandUUID = list_to_binary(uuid:uuid_to_string(uuid:get_v4())),
        BreakoutRoom = <<MainRoom/binary, "_breakout-", RandUUID/binary>>,
        BreakoutRoomJid = jid:make(BreakoutRoom, MainRoomJid#jid.lserver),

        BreakoutRooms = State#state.breakout_rooms,
        MainRoomPid = vm_util:get_room_pid_from_jid(MainRoomJid),
        vm_util:set_room_state(MainRoomPid, State#state{
            breakout_rooms = maps:put(jid:tolower(BreakoutRoomJid), Subject, BreakoutRooms),
            next_index = NextIndex
        }),

        % Make room persistent - not to be destroyed - if all participants join breakout rooms.
        mod_muc_admin:change_room_option(MainRoomPid, persistent, true),
        broadcast_breakout_rooms(MainRoomJid)
    end.

destroy_breakout_room(RoomJid, Message) ->
    case get_main_room(RoomJid) of
    { State, MainRoomJid } when MainRoomJid /= RoomJid ->
        case vm_util:get_state_from_jid(RoomJid) of
        { ok, _ } ->
            mod_muc_room:destroy(vm_util:get_room_pid_from_jid(RoomJid), Message)
        end,
        BreakoutRooms = State#state.breakout_rooms,
        MainRoomPid = vm_util:get_room_pid_from_jid(MainRoomJid),
        vm_util:set_room_state(MainRoomPid, State#state{
            breakout_rooms = maps:remove(jid:tolower(RoomJid), BreakoutRooms)
        }),
        broadcast_breakout_rooms(MainRoomJid)
    end.

destroy_breakout_room(RoomJid) ->
    destroy_breakout_room(RoomJid, <<"Breakout room removed.">>).


% Handling events

process_message(#message{
    to = To,
    from = From,
    type = chat,
    sub_els = [#json_message{data = Data}]
}) when is_binary(Data) ->
	Message = jiffy:decode(Data, [return_maps]),
    Type = maps:get(<<"type">>, Message),
    RoomJid = jid:remove_resource(To),
    MainRoomJid = get_main_room_jid(RoomJid),

    case vm_util:get_state_from_jid(RoomJid) of
    {ok, State} ->
        case {mod_muc_room:get_affiliation(From, State), Type} of
        {owner, ?JSON_TYPE_ADD_BREAKOUT_ROOM} ->
            Subject = maps:get(<<"subject">>, Message),
            NextIndex = maps:get(<<"nextIndex">>, Message),
            create_breakout_room(MainRoomJid, RoomJid, Subject, NextIndex);
        {owner, ?JSON_TYPE_REMOVE_BREAKOUT_ROOM} ->
            BreakoutRoomJid = maps:get(<<"breakoutRoomJid">>, Message),
            destroy_breakout_room(jid:decode(BreakoutRoomJid));
        {owner, ?JSON_TYPE_MOVE_TO_ROOM_REQUEST} ->
            Nick = To#jid.resource,
            ParticipantRoomJid = jid:from_string(Nick),
            case vm_util:get_state_from_jid(ParticipantRoomJid) of
            { ok, ParticipantRoomState } ->
                Occupant = maps:get(jid:tolower(To), ParticipantRoomState#state.users),
                send_json_msg(ParticipantRoomState, Occupant#user.jid, Data)
            end
        end
    end.

-spec check_create_room(boolean(), binary(), binary(), binary()) -> boolean().
check_create_room(Acc, _ServerHost, Room, Host) when Acc == true ->
    RoomJid = jid:make(Room, Host),
    RoomState = vm_util:get_state_from_jid(RoomJid),
    case get_main_room(RoomJid) of
    { State, MainRoomJid } when RoomJid /= MainRoomJid ->
        BreakoutRooms = State#state.breakout_rooms,
        case maps:get(jid:tolower(RoomJid), BreakoutRooms, false) of
        false ->
            false;
        Subject ->
            RoomPid = vm_util:get_room_pid_from_jid(RoomJid),
            vm_util:set_room_state(RoomPid, RoomState#state{
                subject = Subject
            }),
            true
        end;
    _ ->
        true
    end.

on_join_room(_ServerHost, Room, Host, JID) ->
    RoomJid = jid:make(Room, Host),
    if JID#jid.user /= <<"focus">> ->
        broadcast_breakout_rooms(RoomJid);
    true ->
        ok
    end,

    case get_main_room(RoomJid) of
    { undefined, _ } ->
        ok;
    { State, _ } ->
        % Prevent closing all rooms if a participant has joined (see on_occupant_left).
        if State#state.is_close_all_scheduled ->
            RoomPid = vm_util:get_room_pid_from_jid(RoomJid),
            vm_util:set_room_state(RoomPid, State#state{
                is_close_all_scheduled = false
            });
        true ->
            ok
        end
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


on_leave_room(_ServerHost, Room, Host, JID) ->
    RoomJid = jid:make(Room, Host),
    (JID#jid.user /= <<"focus">>) 
        andalso broadcast_breakout_rooms(RoomJid),

    case get_main_room(RoomJid) of
    { State, MainRoomJid } ->
        % Close the conference if all left for good.
        ExistOccupantsInRooms = exist_occupants_in_rooms(State),
        if not State#state.is_close_all_scheduled and not ExistOccupantsInRooms ->
            MainRoomPid = vm_util:get_room_pid_from_jid(MainRoomJid),
            vm_util:set_room_state(MainRoomPid, State#state{
                is_close_all_scheduled = true
            }),
            timer:apply_after(
                ?ROOMS_TTL_IF_ALL_LEFT * 1000,
                mod_breakout_rooms,
                fun(Jid, PID) ->
                    ?INFO_MSG("Closing conference ~ts as all left for good.", [Jid]),
                    mod_muc_admin:change_room_option(PID, persistent, false),
                    mod_muc_room:destroy(PID, <<"All occupants left.">>)
                end,
                [jid:to_string(MainRoomJid), MainRoomPid]
            );
        true ->
            ok
        end;
    _ ->
        ok
    end.


on_start_room(State, _ServerHost, Room, Host) ->
    RoomJid = jid:make(Room, Host),
    case get_main_room(RoomJid) of
    { MainRoomState, MainRoomJid } when MainRoomJid /= RoomJid ->
        State#state{
            lobbyroom = MainRoomState#state.lobbyroom,
            config = (State#state.config)#config{
                members_only = (MainRoomState#state.config)#config.members_only
            }
        };
    _ ->
        State
    end.

on_room_destroyed(State, _ServerHost, _Room, _Host) ->
    Message = <<"Conference ended.">>,
    maps:foreach(
        fun(K, _V) -> destroy_breakout_room(jid:make(K), Message) end,
        State#state.breakout_rooms
    ).
