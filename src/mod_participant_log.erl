-module(mod_participant_log).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

-define(SERVICE_REQUEST_TIMEOUT, 5000). % 5 seconds.
-define(VMAPI_BASE, "http://vmapi:5000/").
-define(CONTENT_TYPE, "application/json").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/6,
    on_broadcast_presence/4, on_leave_room/4, on_start_room/4,
    on_room_destroyed/4, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("muc_participant_log:start ~ts", [Host]),
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(vm_users, [set, named_table, public])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:add(vm_broadcast_presence, Host, ?MODULE, on_broadcast_presence, 100),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ejabberd_hooks:add(room_destroyed, Host, ?MODULE, on_room_destroyed, 100).

stop(Host) ->
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:delete(vm_broadcast_presence, Host, ?MODULE, on_broadcast_presence, 100),
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ejabberd_hooks:delete(room_destroyed, Host, ?MODULE, on_room_destroyed, 100).

is_valid_node(Room, Host) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),

    not vm_util:is_healthcheck_room(Room) andalso
    (Host == MucHost orelse Host == mod_muc_breakout_rooms:breakout_room_muc()).

on_join_room(State, _ServerHost, Packet, JID, _RoomID, Nick) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    % ?INFO_MSG("mod_participant_log:on_join_room ~ts ~ts", [_RoomID, Nick]),

    User = JID#jid.user,
    #jid{ lserver = Host, luser = Room } = Packet#presence.to,
    case is_valid_node(Room, Host) andalso not lists:member(User, ?WHITE_LIST_USERS) of
    true ->
        % ?INFO_MSG("mod_participant_log:joined ~ts", [jid:to_string(JID)]),
        {{Year, Month, Day}, {Hour, Min, Sec}} = erlang:localtime(),
        JoinTime = #{year => Year,
                month => Month,
                day => Day,
                hour => Hour,
                min => Min,
                sec => Sec
            },

        SubEls = Packet#presence.sub_els,
        Name = vm_util:get_subtag_value(SubEls, <<"nick">>),
        StatsID = vm_util:get_subtag_value(SubEls, <<"stats-id">>),
        Email = vm_util:get_subtag_value(SubEls, <<"email">>, null),
        { RoomName, SiteID } = vm_util:split_room_and_site(State#state.room),

        GetRequest = ?VMAPI_BASE ++ "sites/" 
                ++ binary:bin_to_list(SiteID)
                ++ "/conferences"
                ++ "?name=" ++ binary:bin_to_list(RoomName)
                ++ "&delete_yn=false",
        Options = [{body_format, binary}, {full_result, false}],
        HttpOptions = [{timeout, ?SERVICE_REQUEST_TIMEOUT}],

        S1 = if State#state.room_id /= <<>> ->
            State;
        true -> case httpc:request(get, {GetRequest, []}, HttpOptions, Options) of
            {ok, {Code, Resp}} when Code >= 200, Code =< 299 ->
                Conf = lists:nth(1, jiffy:decode(Resp)),
                RoomID = maps:get(<<"_id">>, Conf),
                State#state{ room_id = RoomID };
            _ -> State end
        end,

        % ?INFO_MSG("on_join_room: ~ts ~ts ~ts", [Name, StatsID, Email]),
        Body = #{
            conference => S1#state.room_id,
            joinTime => JoinTime,
            leaveTime => null,
            name => Name,
            email => Email,
            nick => Nick,
            jid => jid:encode(JID),
            stats_id => StatsID
        },

        Url = ?VMAPI_BASE ++ "plog/",
        ReqBody = jiffy:encode(Body),

        ReceiverFunc = fun(ReplyInfo) ->
            case ReplyInfo of
            {_, {{_, 201, _} , _Header, Rep}} ->
                RepJSON = jiffy:decode(Rep, [return_maps]),
                UserID = maps:get(<<"_id">>, RepJSON),
                Email = maps:get(<<"email">>, RepJSON, null),
                LJID = jid:tolower(JID),
                VMUser = #{id => UserID,
                    name => Name,
                    email => Email,
                    nick => Nick
                },

                ets:insert(vm_users, {LJID, VMUser});

            _ ->
                ?WARNING_MSG("[~p] ~p: recv http reply ~p~n", [?MODULE, ?FUNCTION_NAME, ReplyInfo])
            end
        end,
        httpc:request(post, {Url, [], ?CONTENT_TYPE, ReqBody}, [], [{sync, false}, {receiver, ReceiverFunc}]),
        S1;
    _ -> State end.

on_leave_room(_ServerHost, Room, Host, JID) ->
    LJID = jid:tolower(JID),
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    User = JID#jid.user,

    case is_valid_node(Room, Host) andalso not lists:member(User, ?WHITE_LIST_USERS) of
    true ->
        case ets:lookup(vm_users, LJID) of
        [{LJID, VMUser}] ->
            VMUserID = maps:get(id, VMUser),
            Url = "http://vmapi:5000/plog/" ++ binary:bin_to_list(VMUserID),
            httpc:request(delete, {Url, [], [], []}, [], [{sync, false}]),

            ets:delete(vm_users, LJID);
        _ -> ok
        end;
    _ ->
        ok
    end.

on_broadcast_presence(_ServerHost, State,
                        #presence{to = To, type = available, status = [], sub_els = SubEls},
                        #jid{user = User} = JID) ->

    #jid{lserver = Host, luser = Room} = To,
    case is_valid_node(Room, Host) andalso not lists:member(User, ?WHITE_LIST_USERS) of
    true ->
        LJID = jid:tolower(JID),

        case ets:lookup(vm_users, LJID) of
        [{LJID, VMUser}] ->
            VMUserID = maps:get(id, VMUser),
            VMUserName =  maps:get(name, VMUser),
            Name = vm_util:get_subtag_value(SubEls, <<"nick">>),
            % ?INFO_MSG("mod_participant_log:on_broadcast_presence ~p", [Presence]),

            if VMUserName /= Name ->
                httpc:request(patch, {
                    "http://vmapi:5000/plog/" ++ binary:bin_to_list(VMUserID),
                    [],
                    "application/json",
                    jiffy:encode(#{name => Name})
                }, [], [{sync, false}]),
                ets:insert(vm_users, {LJID, VMUser#{name => Name}});
            true ->
                ok
            end;
        _ -> ok
        end;

    _ -> ok
    end;
on_broadcast_presence(_ServerHost, State,
                        #presence{to = To, type = available, status = [Status], sub_els = SubEls},
                        #jid{user = User} = JID) ->

    #jid{lserver = Host, luser = Room} = To,
    case is_valid_node(Room, Host) andalso not lists:member(User, ?WHITE_LIST_USERS) of
    true ->
        LJID = jid:tolower(JID),

        case ets:lookup(vm_users, LJID) of
        [{LJID, VMUser}] ->
            VMUserEmail = maps:get(email, VMUser, null),
            VMUserStatus = maps:get(status, VMUser, null),
            VMUserNick = maps:get(nick, VMUser),
            StatsID = vm_util:get_subtag_value(SubEls, <<"stats-id">>),
            % ?INFO_MSG("mod_participant_log:on_broadcast_presence ~p, ~p", [VMUserStatus, Status#text.data]),

            if VMUserStatus /= Status#text.data ->
                MeetingID = State#state.config#config.meeting_id,
                NewStatus = Status#text.data,
                httpc:request(post, {
                    "http://vmapi:5000/attentions/",
                    [],
                    "application/json",
                    jiffy:encode(#{
                        conference => MeetingID,
                        nick => VMUserNick,
                        status => NewStatus,
                        email => VMUserEmail,
                        stats_id => StatsID})
                }, [], [{sync, false}]),

                ets:insert(vm_users, {LJID, VMUser#{status => NewStatus}});
            true -> ok
            end;

        _ -> ok
        end;

    _ -> ok
    end;
on_broadcast_presence(_ServerHost, _State, _Packet, _JID) ->
    ok.

on_start_room(State, _ServerHost, Room, Host) ->
    ?INFO_MSG("participant_log:on_start_room: ~ts, ~ts", [Room, Host]),

    case is_valid_node(Room, Host) of
    true ->
        MeetingID = State#state.config#config.meeting_id,
        {SiteID, Name} = vm_util:extract_subdomain(Room),

        Url = "http://vmapi:5000/sites/"
                ++ binary:bin_to_list(SiteID)
                ++ "/conferences",
        ContentType = "application/x-www-form-urlencoded",
        ReqBody = uri_string:compose_query(
                    [{"name", Name}, {"meeting_id", MeetingID}]),

        case httpc:request(patch, {Url, [], ContentType, ReqBody}, [], []) of
        {ok, {{_, 201, _} , _Header, Rep}} ->
            RepJSON = jiffy:decode(Rep, [return_maps]),
            RoomID = maps:get(<<"_id">>, RepJSON),
            State1 = State#state{room_id = RoomID},
            State1;

        {_, _Rep} -> State
        end;
    _ -> State
    end.

on_room_destroyed(State, _ServerHost, Room, Host) ->
    ?INFO_MSG("participant_log:on_room_destroyed: ~ts, ~ts", [Room, Host]),

    case is_valid_node(Room, Host) of
    true ->
        % TODO: check if the room name start with __jicofo-health-check
        {SiteID, _} = vm_util:extract_subdomain(Room),
        RoomID = State#state.room_id,

        Url = "http://vmapi:5000/sites/"
                ++ binary:bin_to_list(SiteID)
                ++ "/conferences/"
                ++ binary:bin_to_list(RoomID),
        ContentType = "application/x-www-form-urlencoded",

        httpc:request(delete, {Url, [], ContentType, []}, [], [{sync, false}]);
    _ ->
        ok
    end.


depends(_Host, _Opts) ->
    [{mod_muc, hard}].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_participant_log")}.
