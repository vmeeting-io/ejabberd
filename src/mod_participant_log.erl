-module(mod_participant_log).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/6,
    on_broadcast_presence/3, on_leave_room/5, on_start_room/4,
    on_room_destroyed/4, mod_doc/0]).

start(Host, _Opts) ->
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(vm_users, [named_table, public])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(vm_leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:add(vm_broadcast_presence, Host, ?MODULE, on_broadcast_presence, 100),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:add(vm_room_destroyed, Host, ?MODULE, on_room_destroyed, 100).

stop(Host) ->
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(vm_leave_room, Host, ?MODULE, on_leave_room, 100),
    ejabberd_hooks:delete(vm_broadcast_presence, Host, ?MODULE, on_broadcast_presence, 100),
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 100),
    ejabberd_hooks:delete(vm_room_destroyed, Host, ?MODULE, on_room_destroyed, 100).

on_join_room(State, _ServerHost, Packet, JID, RoomID, Nick) ->
    User = JID#jid.user,

    case lists:member(User, ?WHITE_LIST_USERS) of
    true -> ok;

    false ->
        {{Year, Month, Day}, {Hour, Min, Sec}} = erlang:localtime(),
        JoinTime = #{year => Year,
                month => Month,
                day => Day,
                hour => Hour,
                min => Min,
                sec => Sec
            },

        SubEls = Packet#presence.sub_els,
        ElName = get_subtag(SubEls, <<"nick">>),
        Name = fxml:get_tag_cdata(ElName),
        % ElEmail = get_subtag(SubEls, <<"email">>),
        % Email = fxml:get_tag_cdata(ElEmail),
        ElStatsID = get_subtag(SubEls, <<"stats-id">>),
        StatsID = fxml:get_tag_cdata(ElStatsID),

        Body = #{
                conference => State#state.room_id,
                joinTime => JoinTime,
                leaveTime => nil,
                name => Name,
                % email => Email,
                nick => Nick,
                jid => jid:encode(JID),
                stats_id => StatsID
            },

        Url = "http://vmapi:5000/plog/",
        ContentType = "application/json",
        ReqBody = jiffy:encode(Body),

        case httpc:request(post, {Url, [], ContentType, ReqBody}, [], []) of
        {ok, {{_, 201, _} , _Header, Rep}} ->
            RepJSON = jiffy:decode(Rep, [return_maps]),
            UserID = maps:get(<<"_id">>, RepJSON),

            LJID = jid:tolower(JID),
            VMUser = #{id => UserID,
                    name => Name,
                    % email => Email
                    email => nil
                },

            ets:insert(vm_users, {LJID, VMUser});

        {_, _Rep} -> ok
        end
    end,
    State.

on_leave_room(State, _ServerHost, _Room, _Host, JID) ->
    LJID = jid:tolower(JID),

    case ets:lookup(vm_users, LJID) of
    [{LJID, VMUser}] ->
        VMUserID = maps:get(id, VMUser),
        Url = "http://vmapi:5000/plog/" ++ binary:bin_to_list(VMUserID),
        httpc:request(delete, {Url, [], [], []}, [], []),

        ets:delete(vm_users, LJID);
    _ -> ok
    end,
    State.

on_broadcast_presence(_ServerHost,
                        #presence{type = PresenceType, sub_els = SubEls},
                        #jid{user = User} = JID) ->
    IsWhiteListUser = lists:member(User, ?WHITE_LIST_USERS),

    case {IsWhiteListUser, PresenceType} of
    {false, available} ->
        LJID = jid:tolower(JID),

        case ets:lookup(vm_users, LJID) of
        [{LJID, VMUser}] ->
            VMUserID = maps:get(id, VMUser),
            VMUserName =  maps:get(name, VMUser),

            ElName = get_subtag(SubEls, <<"nick">>),
            Name = fxml:get_tag_cdata(ElName),

            if VMUserName /= Name ->
                Url = "http://vmapi:5000/plog/" ++ binary:bin_to_list(VMUserID),
                ContentType = "application/json",
                Body = #{name => Name},
                ReqBody = jiffy:encode(Body),

                httpc:request(patch, {Url, [], ContentType, ReqBody}, [], []);

            true -> ok
            end;

        _ -> ok
        end;

    _ -> ok
    end.

on_start_room(State, _ServerHost, Room, Host) ->
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
    end.

on_room_destroyed(_ServerHost, _Room, Host, RoomID) ->
    % TODO: check if the room name start with __jicofo-health-check
    [_ , SiteID | _] = string:split(Host, ".", all),

    Url = "http://vmapi:5000/sites/"
            ++ binary:bin_to_list(SiteID)
            ++ "/conferences/"
            ++ binary:bin_to_list(RoomID),
    ContentType = "application/x-www-form-urlencoded",

    httpc:request(delete, {Url, [], ContentType, []}, [], []).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_participant_log")}.

get_subtag( [El | Els], Name) ->
    case El of
      #xmlel{name = Name} -> El;
      _ -> get_subtag(Els, Name)
    end;
get_subtag([], _) -> false.
