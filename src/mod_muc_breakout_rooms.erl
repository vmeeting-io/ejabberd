-module(mod_muc_breakout_rooms).

-behaviour(gen_mod).

-include("logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").
-include("mod_muc.hrl").
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
    on_join_room/4, on_leave_room/4, on_check_create_room/4,
    destroy_main_room/1, update_breakout_rooms/1]).

-record(data,
{
    is_close_all_scheduled  = false :: boolean(),
    is_broadcast_breakout_scheduled = false :: boolean(),
    breakout_rooms          = #{} :: #{binary() => binary()},
    next_index              = 0 :: non_neg_integer(),
    room_infos              = #{} :: #{binary() => #{}}
}).

start(Host, _Opts) ->
    ?INFO_MSG("muc_breakout_rooms:start ~ts", [Host]),
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(vm_breakout_rooms, [set, named_table, public])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:add(join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:add(check_create_room, Host, ?MODULE, on_check_create_room, 100),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, process_message, 100),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:delete(check_create_room, Host, ?MODULE, on_check_create_room, 100),
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
    gen_mod:get_module_opt(global, mod_muc, host).
    % <<"breakout.", ServerHost/binary>>.

send_timeout(Time, Func, Args) ->
    Pid = spawn(?MODULE, Func, Args),
    erlang:send_after(Time, Pid, timeout).

% Utility functions
get_main_room_jid(#jid{luser = Room, lserver = Host} = RoomJid) ->
    {ok, Suffix} = re:compile("_[-0-9a-fA-F]+$"),
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    case re:run(binary_to_list(Room), Suffix) of
    nomatch ->
        RoomJid;
    {match, _} ->
        RoomName = re:replace(binary_to_list(Room), Suffix, "", [{return, binary}]),
        LRoomName = jid:nodeprep(RoomName),
        RoomJid#jid{
            user = RoomName, luser = LRoomName,
            server = MucHost, lserver = MucHost}
    end.

get_main_room(RoomJid) ->
    MainRoomJid = get_main_room_jid(RoomJid),
    case ets:lookup(vm_breakout_rooms, jid:tolower(MainRoomJid)) of
    [] ->
        % ?INFO_MSG("get_main_room(~ts): not found", [jid:encode(MainRoomJid)]),
        {undefined, MainRoomJid};
    [{_, Data}] ->
        % ?INFO_MSG("get_main_room(~ts): ~p", [jid:encode(MainRoomJid), Data]),
        {Data, MainRoomJid}
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
            [{LJID, Data}] = ets:lookup(vm_breakout_rooms, jid:tolower(RoomJid)),
            Data2 = Data#data{ is_broadcast_breakout_scheduled = false },
            ets:insert(vm_breakout_rooms, { LJID, Data2 }),

            {Node, _} = vm_util:split_room_and_site(RoomJid#jid.luser),
            Subject = case State#state.subject of
                [] ->
                    {R, _} = vm_util:split_room_and_site(State#state.room),
                    R;
                [T|_] -> T
            end,
            Rooms = #{ Node => #{
                isMainRoom => true,
                id => Node,
                jid => jid:to_string(RoomJid),
                name => Subject,
                participants => get_participants(State)
            }},

            BreakoutStates = maps:fold(fun(K, _, Acc) ->
                Key = jid:decode(K),
                case vm_util:get_state_from_jid(Key) of
                {ok, BreakoutState} ->
                    maps:put(Key, BreakoutState, Acc);
                _ ->
                    Acc
                end
            end, #{}, Data2#data.breakout_rooms),
            Rooms2 = maps:fold(fun(K, V, Acc) ->
                BreakoutJid  = jid:decode(K),
                {BreakoutNode, _} = vm_util:split_room_and_site(BreakoutJid#jid.luser),
                Info = #{ id => BreakoutNode, jid => K, name => V },
                Info1 = case maps:get(BreakoutJid, BreakoutStates, null) of
                    RoomState when RoomState /= null ->
                        maps:put(
                            participants,
                            get_participants(RoomState),
                            Info);
                    _ ->
                        Info
                    end,
                maps:put(BreakoutNode, Info1, Acc)
            end, Rooms, Data2#data.breakout_rooms),

            JsonMsg = #{
                type => ?JSON_TYPE_UPDATE_BREAKOUT_ROOMS,
                nextIndex => Data2#data.next_index,
                rooms => Rooms2
            },

    		?INFO_MSG("update_breakout_rooms: ~p", [JsonMsg]),
            broadcast_json_msg(State, JsonMsg),
            lists:foreach(fun({K, _}) ->
                case maps:get(jid:decode(K), BreakoutStates, null) of
                RoomState when RoomState /= null ->
                    broadcast_json_msg(RoomState, JsonMsg);
                _ ->
                    ok
                end
            end, maps:to_list(Data2#data.breakout_rooms));
        _ ->
            error
        end;
    _ ->
        ?INFO_MSG("Unknown message received.", [])
    end.

broadcast_breakout_rooms(RoomJid) ->
    case get_main_room(RoomJid) of
    { Data, MainRoomJid }
    when Data /= undefined,
         Data#data.is_broadcast_breakout_scheduled /= true ->
        % Only send each BROADCAST_ROOMS_INTERVAL seconds to prevent flooding of messages.
        % ?INFO_MSG("broadcast_breakout_rooms: ~ts", [jid:encode(MainRoomJid)]),
        Data1 = Data#data{ is_broadcast_breakout_scheduled = true },
        ets:insert(vm_breakout_rooms, {jid:tolower(MainRoomJid), Data1}),
        send_timeout(300, update_breakout_rooms, [MainRoomJid]);
    Ret ->
        % ?INFO_MSG("broadcast_breakout_rooms: ~p", Ret),
        ok
    end.


% Managing breakout rooms

create_breakout_room(RoomJid, Subject, NextIndex) ->
    ?INFO_MSG("create_breakout_room: ~p, ~p, ~p", [jid:encode(RoomJid), Subject, NextIndex]),
    % Breakout rooms are named like the main room with a random uuid suffix
    RoomName = RoomJid#jid.luser,
    RandUUID = list_to_binary(uuid:uuid_to_string(uuid:get_v4())),
    BreakoutRoom = <<RoomName/binary, "_", RandUUID/binary>>,
    BreakoutRoomJid = jid:make(BreakoutRoom, breakout_room_muc()),

    Key = jid:tolower(RoomJid),
    Data = case ets:lookup(vm_breakout_rooms, Key) of
        [] -> #data{ breakout_rooms = #{} };
        [{_, FoundData}] -> FoundData
    end,

    % TODO: create room on vmapi
    {Name, SiteID} = vm_util:split_room_and_site(BreakoutRoom),
    Url = "http://vmapi:5000/sites/"
        ++ binary:bin_to_list(SiteID)
        ++ "/conferences/",
    ContentType = "application/json",
    Body = #{name => Name},
    ReqBody = jiffy:encode(Body),
    Token = gen_mod:get_module_opt(global, mod_site_license, vmeeting_api_token),
    Headers = [{"Authorization", "Bearer " ++ Token}],
    case httpc:request(post, {Url, Headers, ContentType, ReqBody}, [], []) of
    {ok, {{_, 201, _} , _Header, Rep}} ->
        RepJSON = jiffy:decode(Rep, [return_maps]),
        #data{breakout_rooms = Rooms, room_infos = Infos} = Data,
        RoomStr = jid:encode(BreakoutRoomJid),
        ets:insert(vm_breakout_rooms, {
            Key,
            Data#data{
                breakout_rooms = maps:put(RoomStr, Subject, Rooms),
                room_infos = maps:put(RoomStr, RepJSON, Infos),
                next_index = NextIndex
            }
        });
    Err ->
        ?INFO_MSG("create_breakout_room: failed ~p", [Err]),
        ok
    end,

    % Make room persistent - not to be destroyed - if all participants join breakout rooms.
    RoomPid = vm_util:get_room_pid_from_jid(RoomJid),
    mod_muc_admin:change_room_option(RoomPid, persistent, true),
    broadcast_breakout_rooms(RoomJid).

destroy_breakout_room(RoomJid, Message) ->
    ?INFO_MSG("destory_breakout_room: ~p", [jid:encode(RoomJid)]),
    case get_main_room(RoomJid) of
    { Data, MainJid } when MainJid /= RoomJid ->
        #data{breakout_rooms = Rooms, room_infos = Infos} = Data,
        RoomStr = jid:encode(RoomJid),
        RoomInfo = maps:get(RoomStr, Infos),
        RoomID = maps:get(<<"_id">>, RoomInfo),
        ets:insert(vm_breakout_rooms, {
            jid:tolower(MainJid),
            Data#data{
                breakout_rooms = maps:remove(RoomStr, Rooms),
                room_infos = maps:remove(RoomStr, Infos)
            }
        }),

        % TODO: delete room on vmapi
        {Name, SiteID} = vm_util:split_room_and_site(RoomJid#jid.luser),
        Url = "http://vmapi:5000/sites/"
            ++ binary:bin_to_list(SiteID)
            ++ "/conferences/"
            ++ binary:bin_to_list(RoomID),
        Token = gen_mod:get_module_opt(global, mod_site_license, vmeeting_api_token),
        Headers = [{"Authorization", "Bearer " ++ Token}],
        httpc:request(delete, {Url, Headers, [], []}, [], [{sync, false}]),

        broadcast_breakout_rooms(MainJid),
        case vm_util:get_room_pid_from_jid(RoomJid) of
        RoomPid when RoomPid /= room_not_found, RoomPid /= invalid_service ->
            mod_muc_room:destroy(RoomPid, Message);
        _ ->
            ok
        end;
    _ ->
        ok
    end.

destroy_breakout_room(RoomJid) ->
    destroy_breakout_room(RoomJid, <<"Breakout room removed.">>).

find_user_by_nick(Nick, StateData) ->
    try maps:get(Nick, StateData#state.nicks) of
	[User] -> maps:get(User, StateData#state.users);
	[FirstUser | _Users] -> maps:get(FirstUser, StateData#state.users)
    catch _:{badkey, _} ->
	    false
    end.

% Handling events

process_message({#message{
    to = To,
    from = From
} = Packet, State}) ->
    case vm_util:get_subtag_value(Packet#message.sub_els, <<"json-message">>) of
    JsonMesage when JsonMesage /= null ->
	    Message = jiffy:decode(JsonMesage, [return_maps]),
        ?INFO_MSG("decoded message: ~p", [Message]),
        Type = maps:get(<<"type">>, Message),
        RoomJid = vm_util:room_jid_match_rewrite(jid:remove_resource(To)),
        case [vm_util:get_state_from_jid(RoomJid), get_main_room(RoomJid)] of
        [{ok, RoomState}, {_, MainJid}] ->
            case {mod_muc_room:get_affiliation(From, RoomState), Type} of
            {owner, ?JSON_TYPE_ADD_BREAKOUT_ROOM} ->
                Subject = maps:get(<<"subject">>, Message),
                NextIndex = maps:get(<<"nextIndex">>, Message),
                create_breakout_room(MainJid, Subject, NextIndex),
                {drop, State};
            {owner, ?JSON_TYPE_REMOVE_BREAKOUT_ROOM} ->
                BreakoutRoomJid = maps:get(<<"breakoutRoomJid">>, Message),
                destroy_breakout_room(jid:decode(BreakoutRoomJid)),
                {drop, State};
            {owner, ?JSON_TYPE_MOVE_TO_ROOM_REQUEST} ->
                Nick = jid:decode(To#jid.resource),
                ParticipantRoomJid = vm_util:room_jid_match_rewrite(Nick),
                case vm_util:get_state_from_jid(ParticipantRoomJid) of
                { ok, ParticipantRoomState } ->
                    Occupant = find_user_by_nick(Nick#jid.lresource, ParticipantRoomState),
                    send_json_msg(ParticipantRoomJid, Occupant#user.jid, JsonMesage)
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

on_join_room(_ServerHost, Room, Host, From) ->
    MainMuc = gen_mod:get_module_opt(global, mod_muc, host),

    if MainMuc == Host ->
        RoomJid = jid:make(Room, Host),

        % ?INFO_MSG("breakout_rooms:on_join_room: ~ts, ~ts", [jid:encode(RoomJid), jid:encode(From)]),
        case From#jid.user /= <<"focus">> of
        true ->
            broadcast_breakout_rooms(RoomJid);
        _ ->
            ok
        end,

        case get_main_room(RoomJid) of
        {Data, MainJid} when Data /= undefined ->
            Key = jid:tolower(MainJid),
            if Data#data.is_close_all_scheduled == true ->
                % Prevent closing all rooms if a participant has joined (see on_occupant_left).
                ets:insert(vm_breakout_rooms, {
                    Key, Data#data{ is_close_all_scheduled = false }
                });
            true ->
                ok
            end;
        % {_, MainJid} when RoomJid == MainJid ->
        %     ets:insert(vm_breakout_rooms, {
        %         Key, #data{ breakout_rooms = #{} }
        %     }),
        %     ok;
        _ ->
            ok
        end;
    true ->
        ok
    end.

exist_occupants_in_room(RoomJid) ->
    {LUser, LServer, _} = jid:tolower(RoomJid),
    Count = ets:select_count(muc_online_users, ets:fun2ms(
        fun(#muc_online_users{resource=Res, room=Room, host=Host}) ->
            Room == LUser andalso Host == LServer andalso Res /= <<"focus">>
        end)
    ),
    ?INFO_MSG("exist_occupants_in_room: ~p, ~p", [jid:encode(RoomJid), Count]),
    Count > 0.


exist_occupants_in_rooms(RoomJid, Data) ->
    exist_occupants_in_room(RoomJid) orelse lists:any(
        fun({K, _}) ->
            exist_occupants_in_room(jid:decode(K))
        end,
        maps:to_list(Data#data.breakout_rooms)
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
        case ets:lookup(vm_breakout_rooms, jid:tolower(RoomJid)) of
        [{_, Data}] ->
            if Data#data.is_close_all_scheduled ->
                ?INFO_MSG("Destroy main room ~ts as all left for good.", [jid:encode(RoomJid)]),
                Pid = vm_util:get_room_pid_from_jid(RoomJid),
                mod_muc_admin:change_room_option(Pid, persistent, false),
                mod_muc_room:destroy(Pid, <<"All occupants left.">>);
            true ->
                ok
            end;
        _ ->
            ok
        end;
    _ ->
        ?INFO_MSG("Unknown message received", [])
    end.

on_leave_room(_ServerHost, Room, Host, JID) ->
    ?INFO_MSG("breakout_rooms:on_leave_room: ~ts@~ts, ~ts", [Room, Host, jid:encode(JID)]),
    RoomJid = jid:make(Room, Host),

    (JID#jid.user /= <<"focus">>)
        andalso broadcast_breakout_rooms(RoomJid),

    case get_main_room(RoomJid) of
    { undefined, _ } ->
        ok;
    { Data, MainRoomJid } ->
        % Close the conference if all left for good.
        ExistOccupantsInRooms = exist_occupants_in_rooms(MainRoomJid, Data),
        if not Data#data.is_close_all_scheduled and not ExistOccupantsInRooms ->
            ets:insert(vm_breakout_rooms, {
                jid:tolower(MainRoomJid),
                Data#data{ is_close_all_scheduled = true }
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
    ?INFO_MSG("breakout_rooms:on_check_create_room: ~ts@~ts", [Room, Host]),
    if ServerHost == Host ->
        RoomJid = jid:make(Room, Host),

        { Data, MainRoomJid } = get_main_room(RoomJid),
        case (Data /= undefined)
            andalso maps:get(jid:encode(RoomJid), Data#data.breakout_rooms, null) of
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
        { Data, _ } when Data /= undefined ->
            Subject = maps:get(jid:encode(RoomJid), Data#data.breakout_rooms, null),
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

on_room_destroyed(_State, _ServerHost, Room, Host) ->
    ?INFO_MSG("breakout_rooms:on_room_destory", []),
    Message = <<"Conference ended.">>,
    RoomJid = jid:make(Room, Host),
    case ets:lookup(vm_breakout_rooms, jid:tolower(RoomJid)) of
    [{_LJID, Data}] ->
        lists:foreach(
            fun({K, _}) -> destroy_breakout_room(jid:decode(K), Message) end,
            maps:to_list(Data#data.breakout_rooms)
        );
    _ ->
        ok
    end.
