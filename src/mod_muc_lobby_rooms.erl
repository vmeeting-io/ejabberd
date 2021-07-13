-module(mod_muc_lobby_rooms).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

-define(DISPLAY_NAME_REQUIRED_FEATURE, <<"http://jitsi.org/protocol/lobbyrooms#displayname_required">>).

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1,
    on_start_room/4, on_room_destroyed/4, on_join_room/6, on_leave_room/5,
    on_change_state/2, disco_local_identity/5, mod_doc/0,
    disco_features/5]).

start(Host, _Opts) ->
    ?INFO_MSG("muc_lobby_rooms started ~ts ~n", [Host]),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ejabberd_hooks:add(vm_room_destroyed, Host, ?MODULE, on_room_destroyed, 50),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(vm_leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:add(vm_change_state, Host, ?MODULE, on_change_state, 100),
    ejabberd_hooks:add(disco_local_features, Host, ?MODULE, disco_features, 50).

stop(Host) ->
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ejabberd_hooks:delete(vm_room_destroyed, Host, ?MODULE, on_room_destroyed, 50),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(vm_leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:add(vm_change_state, Host, ?MODULE, on_change_state, 100),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, disco_features, 50).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    ?INFO_MSG("mod_muc_lobby_rooms ~ts", [_Host]),
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_lobby_rooms")}.

on_start_room(State, ServerHost, Room, Host) ->
    case State#state.config#config.members_only of
    true ->
        LobbyRoom = <<Room/binary, "@", "lobby.", ServerHost/binary>>,
        State#state{lobbyroom = LobbyRoom};
    false ->
        State
    end.

on_room_destroyed(State, _ServerHost, Room, Host) ->
    case State#state.lobbyroom of
    <<>> ->
        State;
    LobbyRoom ->
        destroy_lobby_room(LobbyRoom, nil),
        State
    end.

on_change_state(State, Options) ->
    case lists:keyfind(membersonly, 1, Options) of
    {_, Value} ->
        case Value of
        true ->
            #state{room = Room, server_host = ServerHost} = State,
            LobbyRoom = <<Room/binary, "@", "lobby.", ServerHost/binary>>,
            % TODO:
            % lobby_created = attach_lobby_room(room)
            % if lobby_created then
            %   notify_lobby_enabled(room, actor, true)
            State#state{lobbyroom = LobbyRoom};
        false ->
            % TODO:
            % if state.lobbyroom then
            %   destroy_lobby_room(state.lobbyroom)
            %   notify_lobby_enabled(room, actor, false)
            State#state{lobbyroom = <<>>}
        end;
    false -> State
    end.

disco_features(empty, From, #jid{lserver = LServer} = _To, <<"lobbyrooms">>, Lang) ->
    ?INFO_MSG("muc_lobby_rooms disco_features ~ts ~n", [LServer]),
    % TODO: add features
    % {result, []}
    {result, []};
disco_features(Acc, _, _, Node, _Lang) ->
    ?INFO_MSG("muc_lobby_rooms disco_features ~p ~ts", [Acc, Node]),
    Acc.

%% -------
%% disco hooks handling functions
%%

-spec disco_local_identity([identity()], jid(), jid(),
			   binary(), binary()) -> [identity()].
disco_local_identity(Acc, _From, To, <<>>, _Lang) ->
    ToServer = To#jid.server,
    ?INFO_MSG("muc_lobby_rooms disco_local_identity ~ts", [ToServer]),
    [#identity{category = <<"component">>,
	       type = <<"lobbyrooms">>,
	       name = <<"lobby.", ToServer/binary>>}
    | Acc];
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

% Create muc_lobby_rooms object for the joined user
on_join_room(State, _ServerHost, Packet, JID, RoomID, Nick) ->
    State.

on_leave_room(State, _ServerHost, Room, Host, JID) ->
    State.

% -spec process_iq(iq()) -> iq() | ignore.
% process_iq(IQ) ->
%     RoomPID = mod_muc_admin:get_room_pid(Room, MucDomain),
%     mod_muc_admin:change_room_option(RoomPID, user_device_access_disabled, UDAD);

% destroys lobby room for the supplied main room
destroy_lobby_room(LobbyRoom, NewJid) ->
    destroy_lobby_room(LobbyRoom, NewJid, <<"Lobby room closed.">>).
destroy_lobby_room(LobbyRoom, NewJid, Message) when Message == <<>>; Message == undefined ->
    destroy_lobby_room(LobbyRoom, NewJid);
destroy_lobby_room(LobbyRoom, NewJid, Message) ->
    ?INFO_MSG("mod_muc_lobby_rooms:destroy_lobby_room '~ts'", [LobbyRoom]),
    case LobbyRoom of
    <<>> -> ok;
    _ ->
        RoomPID = case string:split(LobbyRoom, "@") of
        [Room, Domain] ->
            mod_muc_admin:get_room_pid(Room, Domain);
        [Room] ->
            invalid_service;
        _ ->
            room_not_found
        end,
        if RoomPID == room_not_found; RoomPID == invalid_service ->
            ok;
        true ->
            mod_muc_admin:change_room_option(RoomPID, persistent, false),
            mod_muc_room:destroy(RoomPID, Message)
        end
    end.
