-module(mod_participant_log).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/6,
    on_broadcast_presence/3, on_leave_room/4, on_start_room/4,
    on_room_destroyed/4, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("muc_participant_log:start ~ts", [Host]),
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(vm_users, [named_table, public])
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

on_join_room(State, _ServerHost, Packet, JID, _RoomID, Nick) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),
    % ?INFO_MSG("mod_participant_log:on_join_room ~ts ~ts", [_RoomID, Nick]),

    User = JID#jid.user,

    case {string:equal(Packet#presence.to#jid.server, MucHost), lists:member(User, ?WHITE_LIST_USERS)} of
    {true, false} ->
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

        % ?INFO_MSG("on_join_room: ~ts ~ts ~ts", [Name, StatsID, Email]),
        Body = #{
            conference => State#state.room_id,
            joinTime => JoinTime,
            leaveTime => null,
            name => Name,
            email => Email,
            nick => Nick,
            jid => jid:encode(JID),
            stats_id => StatsID
        },

        Url = "http://vmapi:5000/plog/",
        ContentType = "application/json",
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
                    email => Email
                },

                ets:insert(vm_users, {LJID, VMUser});

            _ ->
                ?WARNING_MSG("[~p] ~p: recv http reply ~p~n", [?MODULE, ?FUNCTION_NAME, ReplyInfo])
            end
        end,
        httpc:request(post, {Url, [], ContentType, ReqBody}, [], [{sync, false}, {receiver, ReceiverFunc}]);

    _ -> ok
    end,

    State.

on_leave_room(_ServerHost, _Room, _Host, JID) ->
    LJID = jid:tolower(JID),

    case ets:lookup(vm_users, LJID) of
    [{LJID, VMUser}] ->
        VMUserID = maps:get(id, VMUser),
        Url = "http://vmapi:5000/plog/" ++ binary:bin_to_list(VMUserID),
        httpc:request(delete, {Url, [], [], []}, [], [{sync, false}]),

        ets:delete(vm_users, LJID);
    _ -> ok
    end.

on_broadcast_presence(_ServerHost,
                        #presence{to = To, type = PresenceType, sub_els = SubEls},
                        #jid{user = User} = JID) ->
    IsWhiteListUser = lists:member(User, ?WHITE_LIST_USERS),
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),

    case {IsWhiteListUser, PresenceType, string:equal(To#jid.server, MucHost)} of
    {false, available, true} ->
        LJID = jid:tolower(JID),

        case ets:lookup(vm_users, LJID) of
        [{LJID, VMUser}] ->
            VMUserID = maps:get(id, VMUser),
            VMUserName =  maps:get(name, VMUser),
            Name = vm_util:get_subtag_value(SubEls, <<"nick">>),

            if VMUserName /= Name ->
                Url = "http://vmapi:5000/plog/" ++ binary:bin_to_list(VMUserID),
                ContentType = "application/json",
                Body = #{name => Name},
                ReqBody = jiffy:encode(Body),

                httpc:request(patch, {Url, [], ContentType, ReqBody}, [], [{sync, false}]);

            true -> ok
            end;

        _ -> ok
        end;

    _ -> ok
    end.

on_start_room(State, _ServerHost, Room, Host) ->
    ?INFO_MSG("participant_log:on_start_room: ~ts, ~ts", [Room, Host]),
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),

    case string:equal(Host, MucHost) of
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
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),

    case string:equal(Host, MucHost) of
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
