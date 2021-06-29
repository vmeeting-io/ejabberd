-module(mod_site_license).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").
-include("ejabberd_http.hrl").

-record(room_data,
{
    start_time = -1 :: integer(),
    max_durations = -1 :: integer()
}).

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1, process/2,
        on_start_room/3, on_room_destroyed/3, on_vm_pre_disco_info/1, mod_doc/0]).

start(Host, _Opts) ->
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(vm_room_data, [named_table, public])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
    ejabberd_hooks:add(vm_pre_disco_info, Host, ?MODULE, on_vm_pre_disco_info, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:delete(room_destroyed, Host, ?MODULE, on_room_destroyed, 100),
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


on_start_room(_ServerHost, Room, Host) ->
    RoomData = #room_data{start_time = erlang:system_time(second)},
    ets:insert(vm_room_data, {{Room, Host}, RoomData}),
    ok.

on_room_destroyed(_ServerHost, Room, Host) ->
    ets:delete(vm_room_data, {Room, Host}),
    ok.

on_vm_pre_disco_info(#state{room = Room, host = Host} = StateData) ->
    case ets:lookup(vm_room_data, {Room, Host}) of
    [{{Room, Host}, #room_data{start_time = StartTime, max_durations = MaxDurations}}] ->
        TimeElapsed = erlang:system_time(second) - StartTime,
        TimeRemained = MaxDurations - TimeElapsed,
        Config = StateData#state.config#config{time_remained = TimeRemained},
        StateData1 = StateData#state{config = Config},
        StateData1;
    _ ->
        StateData
    end;
on_vm_pre_disco_info(StateData) ->
    StateData.


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
    %% TODO: this is just placeholder, current notice function works without
    %% the need of ejabberd.
    ?INFO_MSG("mod_site_license notice", []),
    ok.

process_event(Data) ->
    DataJSON = jiffy:decode(Data, [return_maps]),
    {Room, Host} = split_room_and_host(maps:get(<<"room_name">>, DataJSON)),
    RoomPID = mod_muc_admin:get_room_pid(Room, Host),

    case maps:find(<<"delete_yn">>, DataJSON) of
    {ok, true} ->
        destroy_room(RoomPID, <<"destroyed_by_host">>);
    _ ->
        case maps:find(<<"userDeviceAccessDisabled">>, DataJSON) of
        {ok, UDAD} ->
            mod_muc_admin:change_room_option(RoomPID, user_device_access_disabled, UDAD);
        _ ->
            ok
        end,

        case maps:find(<<"max_durations">>, DataJSON) of
        {ok, MaxDuration} ->
            {ok, RoomConfig} = mod_muc_room:get_config(RoomPID),
            if RoomConfig#config.time_remained < 0 andalso MaxDuration > 0 ->
                destroy_room_after_secs(RoomPID, <<"duration_expired">>, MaxDuration+100),
                mod_muc_admin:change_room_option(RoomPID, time_remained, MaxDuration),

                [{_, RoomData}] = ets:lookup(vm_room_data, {Room, Host}),
                RoomData1 = RoomData#room_data{max_durations = MaxDuration},
                ets:insert(vm_room_data, {{Room, Host}, RoomData1});

            true ->
                ok
            end;
        _ ->
            ok
        end,

        case maps:find(<<"max_occupants">>, DataJSON) of
        {ok, MaxOccupants} ->
            mod_muc_admin:change_room_option(RoomPID, max_users, MaxOccupants);
        _ ->
            ok
        end
    end,

    {200, [], []}.

destroy_room(RoomPID, Message) ->
        Mes = binary:list_to_bin(io_lib:format(Message, [])),
        mod_muc_room:destroy(RoomPID, Mes).

destroy_room_after_secs(RoomPID, Message, After) ->
        Mes = binary:list_to_bin(io_lib:format(Message, [])),
        timer:apply_after(After * 1000, mod_muc_room, destroy, [RoomPID, Mes]).


split_room_and_host(Room) ->
    {match, [SiteID, RoomName]} = re:run(Room,
                                        "\\[(?<site>\\w+)\\](?<room>.+)",
                                        [{capture, [site, room], binary}]),
    Host = binary:list_to_bin("muc." ++ binary:bin_to_list(SiteID) ++ "." ++
            xmpp_domain(global)),
    {RoomName, Host}.

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
