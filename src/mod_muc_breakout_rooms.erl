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

-define(BROADCAST_ROOMS_INTERVAL, 300).
-define(ROOMS_TTL_IF_ALL_LEFT, 5000).
-define(BREAKOUT_ROOMS_IDENTITY_TYPE, <<"breakout_rooms">>).
-define(JSON_TYPE_ADD_BREAKOUT_ROOM, <<"features/breakout-rooms/add">>).
-define(JSON_TYPE_MOVE_TO_ROOM_REQUEST, <<"features/breakout-rooms/move-to-room">>).
-define(JSON_TYPE_REMOVE_BREAKOUT_ROOM, <<"features/breakout-rooms/remove">>).
-define(JSON_TYPE_UPDATE_BREAKOUT_ROOMS, <<"features/breakout-rooms/update">>).


%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_doc/0,
    process_message/1, on_start_room/4, on_room_destroyed/4, disco_local_identity/5,
    on_join_room/4, on_left_room/4, on_check_create_room/4,
    destroy_main_room/1, update_breakout_rooms/1]).

-record(data,
{
    is_close_all_scheduled  = false :: boolean(),
    is_broadcast_breakout_scheduled = false :: boolean(),
    breakout_rooms          = #{} :: #{binary() => binary()},
    breakout_rooms_active   = false :: boolean(),
    breakout_rooms_counter  = 0 :: non_neg_integer(),
    breakout_rooms_info     = #{} :: #{binary() => #{}}
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
    ejabberd_hooks:add(left_room, Host, ?MODULE, on_left_room, 100),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ejabberd_hooks:add(check_create_room, Host, ?MODULE, on_check_create_room, 100),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(filter_packet, ?MODULE, process_message, 100).

stop(Host) ->
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:delete(join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(left_room, Host, ?MODULE, on_left_room, 100),
    ejabberd_hooks:delete(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ejabberd_hooks:delete(check_create_room, Host, ?MODULE, on_check_create_room, 100),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(filter_packet, ?MODULE, process_message, 100).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_breakout_rooms")}.

breakout_room_muc() ->
    ServerHost = ejabberd_config:get_myname(),
    <<"breakout.", ServerHost/binary>>.

send_timeout(Time, Func, Args) ->
    Pid = spawn(?MODULE, Func, Args),
    erlang:send_after(Time, Pid, timeout).

% Utility functions
get_main_room_jid(#jid{luser = Room, lserver = Host} = RoomJid) ->
    {ok, Suffix} = re:compile("_[-0-9a-fA-F]+$"),
    case re:run(binary_to_list(Room), Suffix) of
    nomatch ->
        RoomJid;
    {match, _} ->
        MucHost = gen_mod:get_module_opt(global, mod_muc, host),
        RoomName = re:replace(binary_to_list(Room), Suffix, "", [{return, binary}]),
        jid:make(RoomName, MucHost)
    end.

get_main_room(RoomJid) when is_binary(RoomJid) ->
    get_main_room(jid:decode(RoomJid));
get_main_room(RoomJid) ->
    MainRoomJid = get_main_room_jid(RoomJid),
    case ets:lookup(vm_breakout_rooms, jid:to_string(MainRoomJid)) of
    [] ->
        ?INFO_MSG("get_main_room(~ts): not found", [jid:encode(MainRoomJid)]),
        {undefined, MainRoomJid};
    [{_, Data}] ->
        % ?INFO_MSG("get_main_room(~ts): found", [jid:encode(MainRoomJid)]),
        {Data, MainRoomJid}
    end.

send_json_msg(To, JsonMsg) when is_binary(To) ->
    send_json_msg(jid:decode(To), JsonMsg);
send_json_msg(To, JsonMsg) when To /= undefined ->
    ?INFO_MSG("send_json_msg: ~ts", [jid:to_string(To)]),
    ejabberd_router:route(#message{
        to = To,
        type = chat,
        from = jid:make(breakout_room_muc()),
        sub_els = [#json_message{data = JsonMsg}]
    }).

get_participants(RoomJid) when is_binary(RoomJid) ->
    get_participants(jid:decode(RoomJid));
get_participants(RoomJid) ->
    % ?INFO_MSG("get_participants: ~ts", [jid:to_string(RoomJid)]),
    case vm_util:get_state_from_jid(RoomJid) of
    {ok, State} ->
        maps:fold(fun(K, V, Acc) ->
            % Filter focus as we keep it as a hidden participant
            case K of
            {<<"focus">>, _, _} -> Acc;
            _ ->
                DisplayName = vm_util:get_subtag_value(
                    (V#user.last_presence)#presence.sub_els,
                    <<"nick">>),
                RealJid = jid:replace_resource(State#state.jid, V#user.nick),
                RealNick = vm_util:internal_room_jid_match_rewrite(RealJid),
                maps:put(jid:to_string(RealNick), #{
                    jid => jid:to_string(V#user.jid),
                    role => V#user.role,
                    displayName => DisplayName
                }, Acc)
            end
        end, #{}, State#state.users);
    _ ->
        ?WARNING_MSG("~ts state not found.", [jid:to_string(RoomJid)]),
        #{}
    end.

update_breakout_rooms(RoomJid) ->
    receive
    timeout ->
        case get_main_room(RoomJid) of
        {Data, MainRoomJid} when Data /= undefined ->
            [{JID, Data}] = ets:lookup(vm_breakout_rooms, jid:to_string(MainRoomJid)),
            Data2 = Data#data{ is_broadcast_breakout_scheduled = false },
            ets:insert(vm_breakout_rooms, { JID, Data2 }),

            RealJid = vm_util:internal_room_jid_match_rewrite(MainRoomJid),
            RealNode = RealJid#jid.luser,
            MainParticipants = get_participants(MainRoomJid),
            Rooms = #{ RealNode => #{
                isMainRoom => true,
                id => RealNode,
                jid => jid:to_string(RealJid),
                name => RealNode,
                participants => MainParticipants
            }},

            BreakoutParticipants = maps:fold(fun(BreakoutJid, _, Acc) ->
                Participants = get_participants(BreakoutJid),
                maps:put(BreakoutJid, Participants, Acc)
            end, #{}, Data2#data.breakout_rooms),
            Rooms2 = maps:fold(fun(BreakoutJid, V, Acc) ->
                BreakoutNode = (jid:decode(BreakoutJid))#jid.luser,
                Participants = maps:get(BreakoutJid, BreakoutParticipants),
                Info = #{
                    id => BreakoutNode,
                    jid => BreakoutJid,
                    name => V,
                    participants => Participants
                },
                maps:put(BreakoutNode, Info, Acc)
            end, Rooms, Data2#data.breakout_rooms),

            JsonMsg = jiffy:encode(#{
                type => ?BREAKOUT_ROOMS_IDENTITY_TYPE,
                event => ?JSON_TYPE_UPDATE_BREAKOUT_ROOMS,
                roomCounter => Data2#data.breakout_rooms_counter,
                rooms => Rooms2
            }),

            maps:fold(fun(_, #{ jid := To }, _) ->
                send_json_msg(jid:decode(To), JsonMsg)
            end, ok, MainParticipants),

            maps:fold(fun(K, _, _) ->
                maps:fold(fun(_, #{ jid := To }, _) -> 
                    send_json_msg(jid:decode(To), JsonMsg)
                end, ok, maps:get(K, BreakoutParticipants))
            end, ok, Data2#data.breakout_rooms);
        _ ->
            ?WARNING_MSG("~ts state not found.", [jid:to_string(RoomJid)]),
            error
        end;
    _ ->
        ?WARNING_MSG("Unknown message received.", [])
    end.

broadcast_breakout_rooms(RoomJid) ->
    case get_main_room(RoomJid) of
    { Data, MainRoomJid }
    when Data /= undefined andalso not Data#data.is_broadcast_breakout_scheduled ->
        % Only send each BROADCAST_ROOMS_INTERVAL seconds to prevent flooding of messages.
        MainRoomStr = jid:to_string(MainRoomJid),
        ?INFO_MSG("broadcast_breakout_rooms: ~ts", [MainRoomStr]),
        Data1 = Data#data{ is_broadcast_breakout_scheduled = true },
        ets:insert(vm_breakout_rooms, {MainRoomStr, Data1}),
        send_timeout(?BROADCAST_ROOMS_INTERVAL, update_breakout_rooms, [MainRoomJid]);
    _ ->
        ok
    end.


% Managing breakout rooms

create_breakout_room(RoomJid, Subject) ->
    ?INFO_MSG("create_breakout_room: ~ts, ~ts", [jid:encode(RoomJid), Subject]),
    % Breakout rooms are named like the main room with a random uuid suffix
    RoomName = RoomJid#jid.luser,
    RandUUID = list_to_binary(uuid:uuid_to_string(uuid:get_v4())),
    BreakoutRoom = <<RoomName/binary, "_", RandUUID/binary>>,
    BreakoutRoomJid = jid:make(BreakoutRoom, breakout_room_muc()),
    BreakoutRoomStr = jid:to_string(BreakoutRoomJid),
    [ServerHost | _RestServers] = ejabberd_option:hosts(),

    Key = jid:to_string(RoomJid),
    Data = case ets:lookup(vm_breakout_rooms, Key) of
        [] -> #data{
            breakout_rooms = #{},
            breakout_rooms_counter = 0,
            breakout_rooms_info = #{} };
        [{_, FoundData}] -> FoundData
    end,

    case mod_muc_admin:create_room(BreakoutRoom, breakout_room_muc(), ServerHost) of
    ok ->
        {Name, SiteID} = vm_util:split_room_and_site(BreakoutRoom),
        ?INFO_MSG("create_breakout_room: ~ts, ~ts", [Name, SiteID]),
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
            Result = jiffy:decode(Rep, [return_maps]),
            RepJSON = maps:get(<<"conference">>, Result),
            % ?INFO_MSG("breakout_rooms_info[~ts]: ~p", [BreakoutRoomStr, RepJSON]),
            #data{
                breakout_rooms = Rooms,
                breakout_rooms_counter = Counter,
                breakout_rooms_info = Info} = Data,
            ets:insert(vm_breakout_rooms, {
                Key,
                Data#data{
                    breakout_rooms_counter = Counter + 1,
                    breakout_rooms = maps:put(BreakoutRoomStr, Subject, Rooms),
                    breakout_rooms_active = true,
                    breakout_rooms_info = maps:put(BreakoutRoomStr, RepJSON, Info)
                }
            }),
            % Make room persistent - not to be destroyed - if all participants join breakout rooms.
            RoomPid = vm_util:get_room_pid_from_jid(RoomJid),
            mod_muc_admin:change_room_option(RoomPid, persistent, true),
            broadcast_breakout_rooms(RoomJid);
        Err ->
            ?INFO_MSG("create_breakout_room: failed ~p", [Err]),
            ok
        end;
    _ ->
        ?INFO_MSG("create_breakout_room: failed ~p", [BreakoutRoomStr])
    end.

destroy_breakout_room(RoomJid, Message) ->
    RoomStr = jid:to_string(RoomJid),
    ?INFO_MSG("destory_breakout_room: ~p", [RoomStr]),

    case get_main_room(RoomJid) of
    { Data, MainJid } when MainJid /= RoomJid andalso Data /= undefined ->
        #data{breakout_rooms = Rooms, breakout_rooms_info = Info} = Data,
        case maps:get(RoomStr, Info, not_found) of
        not_found -> ok;
        #{ <<"_id">> := RoomID } ->
            ets:insert(vm_breakout_rooms, {
                jid:to_string(MainJid),
                Data#data{
                    breakout_rooms = maps:remove(RoomStr, Rooms),
                    breakout_rooms_info = maps:remove(RoomStr, Info)
                }
            }),

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
            RoomPid when RoomPid /= room_not_found andalso RoomPid /= invalid_service ->
                % mod_muc_admin:change_room_option(RoomPid, persistent, false),
                mod_muc_room:destroy(RoomPid, Message);
            _ ->
                ok
            end;
        _ ->
            ?INFO_MSG("no matching: ~p", Info)
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
        ?INFO_MSG("find_user_by_nick is failed: ~p", [Nick]),
	    false
    end.

% Handling events
process_message(#message{
    type = Type,
    to = To,
    from = From
} = Packet) when Type /= error ->
    BreakoutHost = jid:make(breakout_room_muc()),
    case vm_util:get_subtag_value(Packet#message.sub_els, <<"json-message">>) of
    JsonMesage when JsonMesage /= null ->
        Message = jiffy:decode(JsonMesage, [return_maps]),
        ?INFO_MSG("decoded message: ~p, from: ~ts, to: ~ts", [Message, jid:encode(From), jid:encode(To)]),

        DType = maps:get(<<"type">>, Message),
        MainRoom = jid:decode(maps:get(<<"mainRoomJid">>, Message)),
        MainRoomJid = vm_util:room_jid_match_rewrite(MainRoom),
        Occupant = case vm_util:get_state_from_jid(MainRoomJid) of
        {ok, RoomState} ->
            LJID = jid:tolower(From),
            % find occupant in main room
            case maps:get(LJID, RoomState#state.users, not_found) of
            not_found ->
                % find occupant in breakout rooms
                MainRoomStr = jid:to_string(MainRoomJid),
                case ets:lookup(vm_breakout_rooms, MainRoomStr) of
                [{_, Data}] ->
                    maps:fold(fun (K, not_found, Acc) ->
                        case {Acc, vm_util:get_state_from_jid(jid:decode(K))} of
                        {not_found, {ok, BRS}} ->
                            map:get(LJID, BRS#state.users, not_found);
                        _ -> Acc end
                    end, not_found, Data#data.breakout_rooms);
                _ -> not_found end;
            Result ->
                Result
            end;
        _ ->
            ?WARNING_MSG("~ts state not found", [jid:to_string(MainRoomJid)]),
            not_found
        end,

        IsModerator = Occupant /= not_found andalso Occupant#user.role == moderator,
        case {IsModerator, DType} of
        {true, ?JSON_TYPE_ADD_BREAKOUT_ROOM} ->
            Subject = maps:get(<<"subject">>, Message),
            create_breakout_room(MainRoomJid, Subject);
        {true, ?JSON_TYPE_REMOVE_BREAKOUT_ROOM} ->
            BreakoutRoomJid = maps:get(<<"breakoutRoomJid">>, Message),
            destroy_breakout_room(jid:decode(BreakoutRoomJid));
        {true, ?JSON_TYPE_MOVE_TO_ROOM_REQUEST} ->
            ParticipantRoomJid = maps:get(<<"participantJid">>, Message),
            TargetRoomJid = maps:get(<<"roomJid">>, Message),
            send_json_msg(ParticipantRoomJid, jiffy:encode(#{
                type => ?BREAKOUT_ROOMS_IDENTITY_TYPE,
                event => ?JSON_TYPE_MOVE_TO_ROOM_REQUEST,
                roomJid => TargetRoomJid }));
        _ -> ok end,
        drop;
    _ ->
        Packet
    end;
process_message(Packet) ->
    Packet.

on_join_room(_ServerHost, Room, Host, From) ->
    RoomJid = jid:make(Room, Host),
    ?INFO_MSG("breakout_rooms:on_join_room: ~ts, ~ts", [jid:encode(RoomJid), jid:encode(From)]),

    case {vm_util:is_healthcheck_room(Room), get_main_room(RoomJid)} of
    {false, {Data, MainJid}}
        when Data /= undefined
            andalso From#jid.user /= <<"focus">>
            andalso Data#data.breakout_rooms_active == true ->
        broadcast_breakout_rooms(RoomJid),

        % Prevent closing all rooms if a participant has joined (see on_occupant_left).
        if Data#data.is_close_all_scheduled == true ->
            Key = jid:to_string(MainJid),
            ets:insert(vm_breakout_rooms, {
                Key, Data#data{ is_close_all_scheduled = false }
            });
        true ->
            ok
        end;
    _ ->
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
        mod_muc_room:kick_all(RoomPID, Mes, [<<"focus">>]),
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
        case ets:lookup(vm_breakout_rooms, jid:to_string(RoomJid)) of
        [{_, Data}] ->
            if Data#data.is_close_all_scheduled ->
                ?INFO_MSG("Closing conference ~ts as all left for good.", [jid:encode(RoomJid)]),
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

on_left_room(_ServerHost, Room, Host, JID) ->
    ?INFO_MSG("breakout_rooms:on_left_room: ~ts@~ts, ~ts", [Room, Host, jid:encode(JID)]),
    RoomJid = jid:make(Room, Host),

    case {vm_util:is_healthcheck_room(Room), get_main_room(RoomJid)} of
    {false, {Data, MainRoomJid}} when Data /= undefined ->
        if Data#data.breakout_rooms_active and JID#jid.user /= <<"focus">> ->
            broadcast_breakout_rooms(RoomJid);
        true -> ok end,

        % Close the conference if all left for good.
        ExistOccupantsInRooms = exist_occupants_in_rooms(MainRoomJid, Data),
        if Data#data.breakout_rooms_active and not Data#data.is_close_all_scheduled and not ExistOccupantsInRooms ->
            ets:insert(vm_breakout_rooms, {
                jid:to_string(MainRoomJid),
                Data#data{ is_close_all_scheduled = true }
            }),
            send_timeout(
                ?ROOMS_TTL_IF_ALL_LEFT,
                destroy_main_room,
                [MainRoomJid]);
        true ->
            ok
        end;
    _ ->
        ok
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
    BreakoutHost = breakout_room_muc(),
    if BreakoutHost == Host ->
        RoomJid = jid:make(Room, Host),
        case get_main_room(RoomJid) of
        { Data, MainRoomJid } when Data /= undefined ->
            Subject = maps:get(jid:to_string(RoomJid), Data#data.breakout_rooms, null),
            State1 = if Subject /= null -> State#state{subject = Subject};
                    true -> State end,
            State1#state{
                is_breakout = true,
                breakout_main_room = jid:to_string(MainRoomJid)
            };
        _ ->
            State
        end;
    true -> State
    end.

on_room_destroyed(_State, _ServerHost, Room, Host) ->
    RoomJid = <<Room/binary, "@", Host/binary>>,
    ?INFO_MSG("breakout_rooms:on_room_destroyed => ~ts", [RoomJid]),

    BreakoutHost = breakout_room_muc(),
    case {vm_util:is_healthcheck_room(Room),
          ets:lookup(vm_breakout_rooms, RoomJid)} of
    {false, [{_, Data}]} ->
        Message = <<"Conference ended.">>,
        maps:fold(fun(K, _, _) ->
            destroy_breakout_room(jid:decode(K), Message)
        end, ok, Data#data.breakout_rooms);
    _ when Host == BreakoutHost ->
        destroy_breakout_room(jid:decode(RoomJid));
    _ ->
        ?INFO_MSG("~ts breakout_rooms not found.", [RoomJid]),
        ok
    end.