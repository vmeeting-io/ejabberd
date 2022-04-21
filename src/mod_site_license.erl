-module(mod_site_license).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").
-include("ejabberd_http.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1, process/2, destroy_room/2,
        on_start_room/4, on_vm_pre_disco_info/1, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("mod_site_license:start ~ts", [Host]),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 90),
    ejabberd_hooks:add(vm_pre_disco_info, Host, ?MODULE, on_vm_pre_disco_info, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 90),
    ejabberd_hooks:delete(vm_pre_disco_info, Host, ?MODULE, on_vm_pre_disco_info, 100),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [{vmeeting_api_token, <<"">>},
    {xmpp_domain, <<"">>}].

mod_doc() ->
    #{desc =>
        ?T("mod_site_license")}.

mod_opt_type(vmeeting_api_token) ->
    econf:string();
mod_opt_type(xmpp_domain) ->
    econf:string().

-spec vmeeting_api_token(gen_mod:opts() | global | binary()) -> string().
vmeeting_api_token(Opts) when is_map(Opts) ->
    gen_mod:get_opt(vmeeting_api_token, Opts);
vmeeting_api_token(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, vmeeting_api_token).

-spec xmpp_domain(gen_mod:opts() | global | binary()) -> string().
xmpp_domain(Opts) when is_map(Opts) ->
    gen_mod:get_opt(xmpp_domain, Opts);
xmpp_domain(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, xmpp_domain).


on_start_room(State, _ServerHost, Room, Host) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    case Host == MucHost of
    true ->
        CreatedTimeStamp = erlang:system_time(millisecond),
        State1 = State#state{created_timestamp = CreatedTimeStamp},
        ?INFO_MSG("site_license:on_start_room ~p ~p", [{Room, Host}, CreatedTimeStamp]),
        State1;
    _ -> State
    end.

on_vm_pre_disco_info(State) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    case State#state.host == MucHost of
    true ->
        #state{max_durations = MaxDurations, created_timestamp = CreatedTimeStamp} = State,
        TimeElapsed = erlang:system_time(second) - CreatedTimeStamp div 1000,
        TimeRemained = MaxDurations - TimeElapsed,
        Config = State#state.config#config{time_remained = TimeRemained},
        State#state{config = Config};
    _ -> State
    end.


process(LocalPath, Request) ->
    case verify_auth_token(Request#request.auth) of
    false ->
        ejabberd_web:error(not_allowed);
    ok ->
        case LocalPath of
        [<<"events">>] ->
            process_event(Request#request.data);
        [<<"notice">>] ->
            process_notice(Request#request.data);
        _ ->
            ?INFO_MSG("mod_site_license not found ~p", [LocalPath]),
            ejabberd_web:error(not_found)
        end
    end.

process_notice(Data) ->
    DataJSON = jiffy:decode(Data, [return_maps]),
    {match, [SiteID, RoomName]} = re:run(maps:get(<<"room_name">>, DataJSON),
                                        "\\[(?<site>\\w+)\\](?<room>.+)",
                                        [{capture, [site, room], binary}]),
    RoomNameEnc = vm_util:percent_encode(RoomName),
    Room = <<"[", SiteID/binary, "]", RoomNameEnc/binary>>,
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),
    RoomPID = mod_muc_admin:get_room_pid(Room, MucDomain),
    mod_muc_room:service_notice(RoomPID, maps:get(<<"notice">>, DataJSON)),
    {200, [], []}.

process_event(Data) ->
    DataJSON = jiffy:decode(Data, [return_maps]),
    % ?INFO_MSG("decoded data: ~p", [DataJSON]),
    {match, [SiteID, RoomName]} = re:run(maps:get(<<"room_name">>, DataJSON),
                                        "\\[(?<site>\\w+)\\](?<room>.+)",
                                        [{capture, [site, room], binary}]),
    RoomNameEnc = vm_util:percent_encode(RoomName),
    Room = <<"[", SiteID/binary, "]", RoomNameEnc/binary>>,
    MucDomain = gen_mod:get_module_opt(global, mod_muc, host),
    RoomPID = mod_muc_admin:get_room_pid(Room, MucDomain),
    ?INFO_MSG("process_event: ~ts ~ts ~p", [Room, MucDomain, RoomPID]),

    case maps:find(<<"delete_yn">>, DataJSON) of
    {ok, true} when RoomPID /= room_not_found, RoomPID /= invalid_service ->
        ?INFO_MSG("process_event: delete_yn = true", []),
        mod_muc_admin:change_room_option(RoomPID, persistent, false),
        destroy_room(RoomPID, <<"destroyed_by_host">>);
    _ when RoomPID /= room_not_found, RoomPID /= invalid_service ->
        {ok, State} = vm_util:get_room_state(Room, MucDomain),

        State1 = case maps:find(<<"max_durations">>, DataJSON) of
        {ok, MaxDuration} when
            MaxDuration > 0 andalso
            State#state.config#config.time_remained < 0 ->
            ?INFO_MSG("process_event: max_durations = ~p", [MaxDuration]),
            CreatedTimeStamp = State#state.created_timestamp,

            TimeElapsed = erlang:system_time(second) - CreatedTimeStamp div 1000,
            TimeRemained = MaxDuration - TimeElapsed,

            mod_muc_admin:change_room_option(RoomPID, time_remained, TimeRemained),
            destroy_room_after_secs(RoomPID, <<"duration_expired">>, TimeRemained),
            State#state{max_durations = MaxDuration};
        _ ->
            State
        end,

        case maps:find(<<"max_occupants">>, DataJSON) of
        {ok, MaxOccupants} ->
            MaxUsers = if MaxOccupants < 0 -> ?MAX_USERS_DEFAULT;
                true -> MaxOccupants end,
            ?INFO_MSG("process_event: max_occupants = ~p", [MaxUsers]),
            mod_muc_admin:change_room_option(RoomPID, max_users, MaxUsers);
        _ ->
            ok
        end,
        
        State2 = case maps:find(<<"face_detect">>, DataJSON) of
        {ok, Enabled} when State1#state.face_detect /= Enabled ->
            ?INFO_MSG("process_event: face_detect = ~p", [Enabled]),
            JsonMsg = #{
                type => <<"features/face-detect/update">>,
                facedetect => Enabled
            },
            ?INFO_MSG("broadcast_json_msg: ~p", [JsonMsg]),
            mod_muc_room:broadcast_json_msg(State1, <<"">>, JsonMsg),
            State1#state{face_detect = Enabled};
        _ -> State1
        end,
        
        Keys = [<<"pinned_tiles">>, <<"tileview_max_columns">>],
        State3 = case maps:with(Keys, DataJSON) of
        #{ <<"pinned_tiles">> := Pinned, <<"tileview_max_columns">> := TileViewMaxColumns }
        when State2#state.pinned_tiles /= Pinned orelse 
             State2#state.tileview_max_columns /= TileViewMaxColumns ->
            ?INFO_MSG("process_event: pinned_tiles = ~p, tileview_max_columns", [Pinned, TileViewMaxColumns]),
            JsonMsg2 = #{
                type => <<"features/settings/tileview">>,
                pinned_tiles => Pinned,
                tileview_max_columns => TileViewMaxColumns
            },
            ?INFO_MSG("broadcast_json_msg: ~p", [JsonMsg2]),
            mod_muc_room:broadcast_json_msg(State2, <<"">>, JsonMsg2),
            State2#state{pinned_tiles = Pinned, tileview_max_columns = TileViewMaxColumns};
        _ -> State2
        end,

        State4 = case maps:find(<<"_id">>, DataJSON) of
        {ok, RoomID} when State3#state.room_id /= RoomID ->
            ?INFO_MSG("process_event: room_id = ~p", [RoomID]),
            State3#state{room_id = RoomID};
        _ -> State3
        end,

        State /= State4 andalso vm_util:set_room_state(Room, MucDomain, State4);
    _ ->
        ok
    end,

    {200, [], []}.

destroy_room(RoomPID, _Message)
    when RoomPID == room_not_found; RoomPID == invalid_service ->
    ?INFO_MSG("destroy_room ERROR: ~p", [RoomPID]),
    ok;
destroy_room(RoomPID, Message) ->
    Mes = binary:list_to_bin(io_lib:format(Message, [])),
    mod_muc_room:kick_all(RoomPID, Mes, [<<"focus">>]),
    % mod_muc_room:destroy(RoomPID),
    ?INFO_MSG("destroy_room success: ~p", [RoomPID]).

destroy_room_after_secs(RoomPID, Message, After) ->
    timer:apply_after(After * 1000, mod_site_license, destroy_room, [RoomPID, Message]).


% split_room_and_host(Room) ->
%     {match, [_SiteID, RoomName]} = re:run(Room,
%                                         "\\[(?<site>\\w+)\\](?<room>.+)",
%                                         [{capture, [site, room], binary}]),
%     MucDomain = gen_mod:get_module_opt(global, mod_muc, host),
%     {RoomName, MucDomain}.

verify_auth_token(Auth) ->
    case Auth of
    {oauth, Token, _} ->
        AuthToken = binary:list_to_bin(vmeeting_api_token(global)),
        if AuthToken == Token ->
            ok;
        true ->
            false
        end;
    _ ->
        false
    end.
