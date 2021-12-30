-module(mod_av_moderation).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/6,
    process_message/1, disco_local_identity/5, occupant_affiliation_changed/5,
    send_json_message/3, notify_occupants_enable/5, notify_jid_approved/4,
    notify_whitelist_change/5, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("av_moderation started ~n", []),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(filter_packet, ?MODULE, process_message, 100),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(vm_set_affiliation, Host, ?MODULE, occupant_affiliation_changed, 100).

stop(Host) ->
    ?INFO_MSG("av_moderation stoped ~n", []),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(filter_packet, ?MODULE, process_message, 100),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(vm_set_affiliation, Host, ?MODULE, occupant_affiliation_changed, 100).

avmoderation_room_muc() ->
    [ServerHost | _RestServers] = ejabberd_option:hosts(),
    jid:make(<<"avmoderation.", ServerHost/binary>>).

% -- Sends a json-message to the destination jid
% -- @param to_jid the destination jid
% -- @param json_message the message content to send
send_json_message(RoomJid, To, JsonMsg)
    when RoomJid /= undefined, To /= undefined ->
    ejabberd_router:route(#message{
        to = To,
        type = chat,
        from = avmoderation_room_muc(),
        sub_els = [#json_message{data = jiffy:encode(JsonMsg)}]
    }).

find_user_by_nick(Nick, StateData) ->
    try maps:get(Nick, StateData#state.nicks) of
	[User] -> maps:get(User, StateData#state.users);
	[FirstUser | _Users] -> maps:get(FirstUser, StateData#state.users)
    catch _:{badkey, _} ->
        ?INFO_MSG("find_user_by_nick is failed: ~p", [Nick]),
	    false
    end.

% -- Notifies that av moderation has been enabled or disabled
% -- @param jid the jid to notify, if missing will notify all occupants
% -- @param enable whether it is enabled or disabled
% -- @param room the room
% -- @param actorJid the jid that is performing the enable/disable operation (the muc jid)
% -- @param mediaType the media type for the moderation
notify_occupants_enable(State, To, Enable, ActorJid, Kind) ->
    ?INFO_MSG("notify_occupants_enabled: ~p, ~p, ~p, ~p", [To, Enable, ActorJid, Kind]),
    RoomJid = vm_util:internal_room_jid_match_rewrite(State#state.jid),
    JsonMsg = #{
        type => <<"av_moderation">>,
        enabled => Enable,
        room => jid:to_string(RoomJid),
        actor => ActorJid,
        kind => Kind
    },

    if To /= null ->
        send_json_message(State#state.jid, To, JsonMsg);
    true ->
        lists:foreach(fun ({Key, User}) ->
            if Key /= <<"focus">> ->
                send_json_message(State#state.jid, User#user.jid, JsonMsg);
            true -> ok end
        end, maps:to_list(State#state.users))
    end.

% -- Notifies about a change to the whitelist. Notifies all moderators and admin and the jid itself
% -- @param jid the jid to notify about the change
% -- @param moderators whether to notify all moderators in the room
% -- @param room the room where to send it
% -- @param mediaType used only when a participant is approved (not sent to moderators)
% -- @param removed whether the jid is removed or added
notify_whitelist_change(State, JID, Moderators, Kind, Removed) ->
    RoomJid = vm_util:internal_room_jid_match_rewrite(State#state.jid),
    ModeratorsJsonMsg = #{
        type => <<"av_moderation">>,
        room => jid:to_string(RoomJid),
        whitelists => State#state.av_moderation,
        removed => Removed,
        kind => Kind
    },
    LJID = jid:tolower(JID),
    lists:foreach(fun ({Key, User}) ->
        if Key == <<"focus">> ->
            ok;
        Moderators == true, User#user.role == moderator ->
            send_json_message(State#state.jid, Key, ModeratorsJsonMsg);
        Key == LJID ->
            % -- if the occupant is not moderator we send him that it is approved
            % -- if it is moderator we update him with the list, this is moderator joining or grant moderation was executed
            if User#user.role == moderator ->
                send_json_message(State#state.jid, Key, ModeratorsJsonMsg);
            true ->
                ParticipantJsonMsg = maps:merge(
                    ModeratorsJsonMsg,
                    #{ whitelists => null, approved => not Removed }),
                send_json_message(State#state.jid, Key, maps:merge(
                    ModeratorsJsonMsg,
                    #{ whitelists => null, approved => not Removed }))
            end;
        true ->
            ok
        end
    end, maps:to_list(State#state.users)).

% -- Notifies jid that is approved. This is a moderator to jid message to ask to unmute,
% -- @param jid the jid to notify about the change
% -- @param from the jid that triggered this
% -- @param room the room where to send it
% -- @param mediaType the mediaType it was approved for
notify_jid_approved(JID, From, RoomJid, Kind) ->
    Room = vm_util:internal_room_jid_match_rewrite(RoomJid),
    JsonMsg = #{
        type => <<"av_moderation">>,
        room => jid:to_string(Room),
        approved => true, % -- we want to send to participants only that they were approved to unmute
        kind => Kind,
        from => jid:to_string(From)
    },
    send_json_message(RoomJid, JID, JsonMsg).

process_message(#message{
    to = #jid{luser = <<"">>, lresource = <<"">>} = To,
    from = From
} = Packet) ->
    AvmoderationHost = avmoderation_room_muc(),
    case vm_util:get_subtag_value(Packet#message.sub_els, <<"json-message">>) of
    JsonMesage when JsonMesage /= null, To == AvmoderationHost ->
	    Message = jiffy:decode(JsonMesage, [return_maps]),
        ?INFO_MSG("decoded message: ~p", [Message]),

        Kind = maps:get(<<"kind">>, Message),
        Room = jid:decode(maps:get(<<"room">>, Message)),
        RoomJid = vm_util:room_jid_match_rewrite(Room),
        case vm_util:get_state_from_jid(RoomJid) of
        {ok, RoomState} ->
            LJID = jid:tolower(From),
            Occupant = maps:get(LJID, RoomState#state.users),
            Whitelist = maps:get(Kind, RoomState#state.av_moderation, []),
            IsEmpty = maps:size(RoomState#state.av_moderation) == 0,
            case Message of
            #{<<"enable">> := Enable} ->
                M = maps:get(Kind, RoomState#state.av_moderation, not_found),
                S = if Enable, M == not_found ->
                    RS1 = RoomState#state{
                        av_moderation = maps:put(Kind, [], RoomState#state.av_moderation),
                        av_moderation_actors = maps:put(Kind, Occupant#user.nick, RoomState#state.av_moderation_actors)
                    },
                    vm_util:set_room_state_from_jid(RoomJid, RS1),
                    RS1;
                not Enable, M /= not_found ->
                    RS2 = RoomState#state{
                        av_moderation = maps:remove(Kind, RoomState#state.av_moderation),
                        av_moderation_actors = maps:remove(Kind, RoomState#state.av_moderation_actors)
                    },
                    vm_util:set_room_state_from_jid(RoomJid, RS2),
                    RS2;
                true ->
                    ?WARNING_MSG("Concurrent moderator enable/disable request or something is out of sync", []),
                    RoomState
                end,
                notify_occupants_enable(S, null, Enable, Occupant#user.nick, Kind);
            #{<<"jidToWhitelist">> := JidToWhitelist} ->
                ?INFO_MSG("jidToWhitelist: ~p", [JidToWhitelist]),
                Jid = jid:decode(JidToWhitelist),
                case find_user_by_nick(Jid#jid.lresource, RoomState) of
                false ->
                    ?WARNING_MSG("No occupant ~ts found for ~ts", [JidToWhitelist, Room]),
                    ok;
                OccupantToAdd ->
                    if not IsEmpty ->
                        RS3 = RoomState#state{
                            av_moderation = [JidToWhitelist | Whitelist]
                        },
                        vm_util:set_room_state_from_jid(RoomJid, RS3),
                        notify_whitelist_change(RS3, OccupantToAdd#user.jid, true, Kind, false);
                    true ->
                        notify_jid_approved(OccupantToAdd#user.jid, From, RoomState#state.jid, Kind)
                    end
                end;
            #{<<"jidToBlacklist">> := JidToBlacklist} ->
                ?INFO_MSG("jidToBlacklist: ~p", [JidToBlacklist]),
                Jid = jid:encode(JidToBlacklist),
                case find_user_by_nick(Jid#jid.lresource, RoomState) of
                false -> 
                    ?WARNING_MSG("No occupant ~ts found for ~ts", [JidToBlacklist, Room]),
                    ok;
                OccupantToRemove ->
                    IsMember = lists:member(JidToBlacklist, Whitelist),
                    if not IsEmpty, IsMember ->
                        RS4 = RoomState#state{
                            av_moderation = lists:delete(JidToBlacklist, Whitelist)
                        },
                        vm_util:set_room_state_from_jid(RoomJid, RS4),
                        notify_whitelist_change(RS4, OccupantToRemove#user.jid, true, Kind, true);
                    true -> ok end
                end;
            _ -> ok end;
        _ -> ok end,
        drop;
    _ -> Packet end;
process_message(Packet) ->
    Packet.

on_join_room(State, ServerHost, Packet, JID, _Room, Nick) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),

    User = JID#jid.user,

    case {string:equal(Packet#presence.to#jid.server, MucHost), lists:member(User, ?WHITE_LIST_USERS)} of
    {true, false} when State#state.av_moderation /= #{} ->
        ?INFO_MSG("on_join_room: ~p", [State#state.av_moderation]),
        lists:foreach(fun ({K, V}) ->
            Actor = maps:get(K, State#state.av_moderation_actors),
            notify_occupants_enable(State, JID, true, Actor, K)
        end, maps:to_list(State#state.av_moderation)),

        % -- NOTE for some reason event.occupant.role is not reflecting the actual occupant role (when changed
        % -- from allowners module) but iterating over room occupants returns the correct role
        list:foreach(fun ({LJID, User}) ->
            % -- if moderator send the whitelist
            if User#user.nick == Nick, User#user.role == moderator ->
                notify_whitelist_change(State, User#user.jid, false, undefined, false);
            true -> ok
            end
        end, maps:to_list(State#state.users));
    {true, false} ->
        ?INFO_MSG("on_join_room: ~p", [State#state.av_moderation]);
    _ -> ok
    end,
    State.

% -- when a occupant was granted moderator we need to update him with the whitelist
occupant_affiliation_changed(State, Actor, JID, Affiliation, _Reason) ->
    % -- the actor can be nil if is coming from allowners or similar module we want to skip it here
    % -- as we will handle it in occupant_joined
    if Actor == true, Affiliation == owner, State#state.av_moderation /= #{} ->
        % -- event.jid is the bare jid of participant
        LJID = jid:tolower(JID),
        lists:foreach(fun ({Key, User}) ->
            if Key == LJID ->
                notify_whitelist_change(State, User#user.jid, false, undefined, false);
            true -> ok
            end
        end, maps:to_list(State#state.users));
    true -> ok
    end.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_av_moderation")}.

%% -------
%% disco hooks handling functions
%%

-spec disco_local_identity([identity()], jid(), jid(),
			   binary(), binary()) -> [identity()].
disco_local_identity(Acc, _From, To, <<>>, _Lang) ->
    ToServer = To#jid.server,
    [#identity{category = <<"component">>,
	       type = <<"av_moderation">>,
	       name = <<"avmoderation.", ToServer/binary>>}
    | Acc];
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.
