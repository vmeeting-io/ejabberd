-module(mod_muc_lobby_rooms).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

-define(VMAPI_BASE, "http://vmapi:5000/").
-define(CONTENT_TYPE, "application/json").
-define(DISPLAY_NAME_REQUIRED_FEATURE, <<"http://jitsi.org/protocol/lobbyrooms#displayname_required">>).
-define(NOTIFY_LOBBY_ENABLED, <<"LOBBY-ENABLED">>).
-define(NOTIFY_JSON_MESSAGE_TYPE, <<"lobby-notify">>).
-define(NOTIFY_LOBBY_ACCESS_GRANTED, <<"LOBBY-ACCESS-GRANTED">>).
-define(NOTIFY_LOBBY_ACCESS_DENIED, <<"LOBBY-ACCESS-DENIED">>).

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1,
    on_start_room/4, on_room_destroyed/4, on_pre_join_room/5,
    on_muc_invite/5, on_change_state/3, disco_local_identity/5,
    on_kick_participant/3, mod_doc/0]).

start(Host, _Opts) ->
    ejabberd_hooks:add(vm_kick_participant, Host, ?MODULE, on_kick_participant, 100),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 50),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(vm_pre_join_room, Host, ?MODULE, on_pre_join_room, 100),
    ejabberd_hooks:add(vm_change_state, Host, ?MODULE, on_change_state, 100),
    ejabberd_hooks:add(vm_muc_invite, Host, ?MODULE, on_muc_invite, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(vm_kick_participant, Host, ?MODULE, on_kick_participant, 100),
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ejabberd_hooks:delete(room_destroyed, Host, ?MODULE, on_room_destroyed, 50),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(vm_pre_join_room, Host, ?MODULE, on_pre_join_room, 100),
    ejabberd_hooks:delete(vm_change_state, Host, ?MODULE, on_change_state, 100),
    ejabberd_hooks:delete(vm_muc_invite, Host, ?MODULE, on_muc_invite, 100),
    ok.

depends(_Host, _Opts) ->
    [{mod_muc, hard}].

mod_options(_Host) ->
    [{whitelist_domains, []}].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_lobby_rooms")}.

mod_opt_type(whitelist_domains) ->
    econf:list(econf:binary(), [unique]).

lobby_host() ->
    ServerHost = ejabberd_config:get_myname(),
    <<"lobby.", ServerHost/binary>>.

-spec whitelist_domains(gen_mod:opts() | global | binary()) -> [binary()].
whitelist_domains(Opts) when is_map(Opts) ->
    gen_mod:get_opt(whitelist_domains, Opts);
whitelist_domains(Host) ->
    gen_mod:get_module_opt(Host, mod_muc_lobby_rooms, whitelist_domains).

on_start_room(State, _ServerHost, Room, Host) ->
    LobbyHost = lobby_host(),
    IsLobbyRoom = Host == LobbyHost,
    State1 = case IsLobbyRoom of
    true -> 
        Config = State#state.config#config{members_only = false, persistent = true},
        State#state{config = Config};
    _ -> State end,

    % ?INFO_MSG("mod_muc_lobby_rooms:on_start_room ~ts, ~ts, ~p, ~p", [Room, Host, IsLobbyRoom, State1#state.config#config.members_only]),
    case State1#state.config#config.members_only of
    true ->
        LobbyRoom = <<Room/binary, "@", LobbyHost/binary>>,
        State1#state{lobbyroom = LobbyRoom};
    false ->
        State1
    end.

on_room_destroyed(State, ServerHost, Room, _Host) ->
    % ?INFO_MSG("mod_muc_lobby_rooms:on_room_destroyed ~ts, ~ts", [ServerHost, Room]),
    case mod_muc:find_online_room(Room, lobby_host()) of
    error ->
        ok;
    _ ->
        destroy_lobby_room(State#state.lobbyroom, nil)
    end.

on_change_state(State, FromJid, Options) ->
    case lists:keyfind(membersonly, 1, Options) of
    {_, Value} ->
        ?INFO_MSG("mod_muc_lobby_rooms:on_change_state '~ts', ~ts, ~ts", [Value, State#state.room, State#state.room_id]),
        #state{room = Room} = State,
        LobbyHost = lobby_host(),
        LobbyRoom = <<Room/binary, "@", LobbyHost/binary>>,
        {ok, Inviter} = maps:find(jid:tolower(FromJid), State#state.users),

        {_, SiteID} = vm_util:split_room_and_site(State#state.room),
        Url = ?VMAPI_BASE ++ "sites/"
            ++ binary:bin_to_list(SiteID) ++ "/conferences/"
            ++ binary:bin_to_list(State#state.room_id),
        Token = gen_mod:get_module_opt(global, mod_site_license, vmeeting_api_token),
        Headers = [{"Authorization", "Bearer " ++ Token}],
        ReqBody = jiffy:encode(#{lobby => Value}),
        httpc:request(patch, {Url, Headers, ?CONTENT_TYPE, ReqBody}, [], [{sync, false}]),

        case Value of
        true ->
            case attach_lobby_room(State, Room, LobbyHost) of
            {ok, State1} ->
                notify_lobby_enabled(State1, Inviter#user.nick, true),
                State1;
            {error, State1} ->
                State1
            end;
        false ->
            case State#state.lobbyroom of
            <<>> ->
                ok;
            LobbyRoom ->
                notify_lobby_enabled(State, Inviter#user.nick, false),
                destroy_lobby_room(LobbyRoom, nil)
            end,
            State#state{lobbyroom = <<>>}
        end;
    false ->
        State
    end.

-spec disco_local_identity([identity()], jid(), jid(),
			   binary(), binary()) -> [identity()].
disco_local_identity(Acc, _From, To, <<>>, _Lang) ->
    ToServer = To#jid.server,
    [#identity{category = <<"component">>,
	       type = <<"lobbyrooms">>,
	       name = <<"lobby.", ToServer/binary>>}
    | Acc];
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

% Create muc_lobby_rooms object for the joined user
on_pre_join_room(#state{room = RoomName, host = Host, config = Config} = State,
        _ServerHost, Packet, FromJid, _Nick) ->
    MucSubTag = xmpp:get_subtag(Packet, #muc{}),
    EmailSubTag = xmpp:get_subtag(Packet, #email{}),
    IsJoin = MucSubTag /= false,
    IsHeathcheck = vm_util:is_healthcheck_room(RoomName),
    IsMemberOnly = Config#config.members_only,

    case {IsJoin, IsHeathcheck, IsMemberOnly} of
    {true, false, true} ->
        ?INFO_MSG("mod_muc_lobby_rooms:on_pre_join_room ~ts@~ts, ~ts", [RoomName, Host, jid:encode(FromJid)]),
        IsWhitelist = lists:member(FromJid#jid.server, whitelist_domains(global)),
        {_, _, Password} = MucSubTag,

        IsMailOwner = case ets:lookup(vm_rooms, <<RoomName/binary, "@", Host/binary>>) of
        [{ _, Data }] when EmailSubTag /= false ->
            {_, Email} = EmailSubTag,
            case maps:find(<<"mail_owner">>, Data) of
            {ok, MailOwner} when MailOwner == Email -> true;
            _ -> false
            end;
        _ ->
            false
        end,

        IsPasswordMatch = Config#config.password_protected == true
                        andalso Password == Config#config.password,

        % ?INFO_MSG("mod_muc_lobby_rooms:on_pre_join_room ~ts, ~ts, ~ts", [IsWhitelist, IsMailOwner, IsPasswordMatch]),
        case IsWhitelist orelse IsMailOwner orelse IsPasswordMatch of
        true ->
            BareLjid = jid:tolower(jid:remove_resource(FromJid)),
            Affiliations = State#state.affiliations,
            Affiliations1 = maps:put(BareLjid, {member, <<>>}, Affiliations),

            State#state{affiliations = Affiliations1};
        _ ->
            State
        end;
    _ ->
        State
    end;
on_pre_join_room(State, _ServerHost, _Packet, _FromJid, _Nick) ->
    State.

on_muc_invite(State, From, To, _Reason, _Pkt) ->
    % ?INFO_MSG("mod_muc_lobby_rooms:on_muc_invite ~ts, ~ts, ~ts", [State#state.room, jid:encode(From), jid:encode(To)]),
    Room = State#state.room,
    LobbyHost = lobby_host(),

    try
        {ok, LobbyRoomState} = vm_util:get_room_state(Room, LobbyHost),
        {ok, Inviter} = maps:find(jid:tolower(From), State#state.users),

        {ok, Invitee} = maps:find(jid:tolower(To), LobbyRoomState#state.users),
        InviteeName = vm_util:get_subtag_value(
                    Invitee#user.last_presence#presence.sub_els,
                    <<"nick">>),
        notify_lobby_access(State, Inviter#user.nick, Invitee#user.nick, InviteeName, true)
    catch
        ErrType:Err -> log_err_stacktrace(ErrType, Err)
    end.

on_kick_participant(Ujid, Jid, State) ->
    MainRoomPid = State#state.main_room_pid,
    if is_pid(MainRoomPid) ->
        try
            {ok, Kicked} = maps:find(jid:tolower(Jid), State#state.users),
            KickedName = vm_util:get_subtag_value(
                            Kicked#user.last_presence#presence.sub_els,
                            <<"nick">>),
            {ok, MainRoomState} = mod_muc_room:get_state(MainRoomPid),
            {ok, Kick} = maps:find(jid:tolower(Ujid), MainRoomState#state.users),

            notify_lobby_access(MainRoomPid, Kick#user.nick, Kicked#user.nick, KickedName, false)
        catch
            ErrType:Err -> log_err_stacktrace(ErrType, Err)
        end;
    true ->
        ok
    end.

% destroys lobby room for the supplied main room
destroy_lobby_room(LobbyRoom, NewJid) ->
    destroy_lobby_room(LobbyRoom, NewJid, <<"destroyed_by_host">>).
destroy_lobby_room(LobbyRoom, NewJid, Message) when Message == <<>>; Message == undefined ->
    destroy_lobby_room(LobbyRoom, NewJid);
destroy_lobby_room(LobbyRoom, _NewJid, Message) ->
    ?INFO_MSG("mod_muc_lobby_rooms:destroy_lobby_room '~ts'", [LobbyRoom]),
    case LobbyRoom of
    <<>> -> ok;
    _ ->
        RoomPID = case string:split(LobbyRoom, "@") of
        [Room, Domain] ->
            mod_muc_admin:get_room_pid(Room, Domain);
        [_] ->
            invalid_service;
        _ ->
            room_not_found
        end,
        if RoomPID == room_not_found; RoomPID == invalid_service ->
            ok;
        true ->
            % mod_muc_admin:change_room_option(RoomPID, persistent, false),
            mod_muc_room:destroy(RoomPID, Message)
        end
    end.

-spec notify_lobby_enabled(mod_muc_room:state() | pid(), jid(), boolean()) -> ok.
notify_lobby_enabled(Room, FromNick, Value) ->
    JsonMsg = #{
        type => ?NOTIFY_JSON_MESSAGE_TYPE,
        event => ?NOTIFY_LOBBY_ENABLED,
        value => Value
    },
    mod_muc_room:broadcast_json_msg(Room, FromNick, JsonMsg).

attach_lobby_room(State, Room, LobbyHost) ->
    LobbyRoom = <<Room/binary, "@", LobbyHost/binary>>,
    case mod_muc:find_online_room(Room, LobbyHost) of
    error ->
        case mod_muc_admin:create_room_with_opts(Room, LobbyHost,
                                        State#state.server_host,
                                        [{<<"persistent">>, <<"true">>}]) of
        ok ->
            MainRoomPid = vm_util:get_room_pid_from_jid(State#state.jid),
            {ok, LobbyRoomState} = vm_util:get_room_state(Room, LobbyHost),
            vm_util:set_room_state(Room, LobbyHost,
                                LobbyRoomState#state{main_room_pid = MainRoomPid}),
            {ok, State#state{lobbyroom = LobbyRoom}};
        _ ->
            {error, State#state{lobbyroom = <<>>}}
        end;
    _ ->
        {ok, State#state{lobbyroom = LobbyRoom}}
    end.

-spec notify_lobby_access(mod_muc_room:state() | pid(), jid(), jid(), binary(), boolean()) -> ok.
notify_lobby_access(Room, FromNick, ToNick, Name, Granted) ->
    Event = if Granted -> ?NOTIFY_LOBBY_ACCESS_GRANTED;
            true -> ?NOTIFY_LOBBY_ACCESS_DENIED
            end,

    JsonMsg = #{
        type => ?NOTIFY_JSON_MESSAGE_TYPE,
        name => Name,
        value => ToNick,
        event => Event
    },

    mod_muc_room:broadcast_json_msg(Room, FromNick, JsonMsg).

log_err_stacktrace(ErrType, Err) ->
    ?INFO_MSG("[~p:~p] ~p~n", [?MODULE, ?FUNCTION_NAME, {ErrType, Err}]).
