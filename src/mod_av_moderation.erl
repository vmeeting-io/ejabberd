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
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, process_message, 100),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(vm_set_affiliation, Host, ?MODULE, occupant_affiliation_changed, 100).

stop(Host) ->
    ?INFO_MSG("av_moderation stoped ~n", []),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, process_message, 100),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(vm_set_affiliation, Host, ?MODULE, occupant_affiliation_changed, 100).

% -- Sends a json-message to the destination jid
% -- @param to_jid the destination jid
% -- @param json_message the message content to send
send_json_message(RoomJid, To, JsonMsg)
    when RoomJid /= undefined, To /= undefined ->
    ejabberd_router:route(#message{
        to = To,
        type = chat,
        from = RoomJid,
        sub_els = [#json_message{data=JsonMsg}]
    }).

% -- Notifies that av moderation has been enabled or disabled
% -- @param jid the jid to notify, if missing will notify all occupants
% -- @param enable whether it is enabled or disabled
% -- @param room the room
% -- @param actorJid the jid that is performing the enable/disable operation (the muc jid)
% -- @param mediaType the media type for the moderation
notify_occupants_enable(State, To, Enable, ActorJid, Kind) ->
    JsonMsg = #{
        type => <<"av_moderation">>,
        enabled => Enable,
        room => vm_util:internal_room_jid_match_rewrite(State#state.jid),
        actor => ActorJid,
        kind => Kind
    },

    if To /= null ->
        send_json_message(State#state.jid, To, JsonMsg);
    true ->
        maps:foreach(fun (LJID, _) ->
            send_json_message(State#state.jid, LJID, JsonMsg)
        end, State#state.users)
    end.

% -- Notifies about a change to the whitelist. Notifies all moderators and admin and the jid itself
% -- @param jid the jid to notify about the change
% -- @param moderators whether to notify all moderators in the room
% -- @param room the room where to send it
% -- @param mediaType used only when a participant is approved (not sent to moderators)
% -- @param removed whether the jid is removed or added
notify_whitelist_change(State, JID, Moderators, Kind, Removed) ->
    ModeratorsJsonMsg = #{
        type => <<"av_moderation">>,
        room => vm_util:internal_room_jid_match_rewrite(State#state.jid),
        whitelists => State#state.av_moderation,
        removed => Removed,
        kind => Kind
    },
    ParticipantJsonMsg = maps:merge(
        ModeratorsJsonMsg,
        #{ whitelists => null, approved => not Removed }),
    LJID = jid:tolower(JID),
    maps:foreach(fun (Key, User) ->
        if Moderators == true, User#user.role == moderator ->
            send_json_message(State#state.jid, Key, ModeratorsJsonMsg);
        Key == LJID ->
            % -- if the occupant is not moderator we send him that it is approved
            % -- if it is moderator we update him with the list, this is moderator joining or grant moderation was executed
            if User#user.role == moderator ->
                send_json_message(State#state.jid, Key, ModeratorsJsonMsg);
            true ->
                send_json_message(State#state.jid, Key, ParticipantJsonMsg)
            end;
        true ->
            ok
        end
    end, State#state.users).

% -- Notifies jid that is approved. This is a moderator to jid message to ask to unmute,
% -- @param jid the jid to notify about the change
% -- @param from the jid that triggered this
% -- @param room the room where to send it
% -- @param mediaType the mediaType it was approved for
notify_jid_approved(JID, From, RoomJid, Kind) ->
    JsonMsg = #{
        type => <<"av_moderation">>,
        room => vm_util:internal_room_jid_match_rewrite(RoomJid),
        approved => true, % -- we want to send to participants only that they were approved to unmute
        kind => Kind,
        from => From
    },
    send_json_message(RoomJid, JID, JsonMsg).

process_message({#message{
    to = #jid{luser = <<"">>, lresource = <<"">>} = To,
    from = From
} = Packet, State}) ->
    ?INFO_MSG("process_message: ~p", [Packet]),

    case vm_util:get_subtag_value(Packet#message.sub_els, <<"json-message">>) of
    JsonMesage when JsonMesage /= null ->
	    Message = jiffy:decode(JsonMesage, [return_maps]),
        Kind = maps:get(<<"kind">>, Message),
        Room = jid:decode(maps:get(<<"room">>, Message)),
        RoomJid = jid:decode(Room),
        ?INFO_MSG("decoded message: ~ts -> ~ts~n~p~n~p, ~p", [jid:encode(From), jid:encode(To), Message, Room, RoomJid]),
        RoomState = vm_util:get_state_from_jid(RoomJid),
        LJID = jid:tolower(From),
        Occupant = maps:get(LJID, RoomState#state.users),
        case Message of
        #{<<"enable">> := Enable} ->
            % local enabled;
            % if moderation_command.attr.enable == 'true' then
            %     enabled = true;
            %     if room.av_moderation and room.av_moderation[mediaType] then
            %         module:log('warn', 'Concurrent moderator enable/disable request or something is out of sync');
            %         return true;
            %     else
            %         if not room.av_moderation then
            %             room.av_moderation = {};
            %             room.av_moderation_actors = {};
            %         end
            %         room.av_moderation[mediaType] = array{};
            %         room.av_moderation_actors[mediaType] = occupant.nick;
            %     end
            % else
            %     enabled = false;
            %     if not room.av_moderation then
            %         module:log('warn', 'Concurrent moderator enable/disable request or something is out of sync');
            %         return true;
            %     else
            %         room.av_moderation[mediaType] = nil;
            %         room.av_moderation_actors[mediaType] = nil;

            %         -- clears room.av_moderation if empty
            %         local is_empty = true;
            %         for key,_ in pairs(room.av_moderation) do
            %             if room.av_moderation[key] then
            %                 is_empty = false;
            %             end
            %         end
            %         if is_empty then
            %             room.av_moderation = nil;
            %         end
            %     end
            % end

            % -- send message to all occupants
            % notify_occupants_enable(nil, enabled, room, occupant.nick, mediaType);
            % return true;
            M = maps:get(Kind, RoomState#state.av_moderation, not_found),
            S = if Enable, M /= true ->
                RS1 = RoomState#state{
                    av_moderation = maps:put(Kind, [], State#state.av_moderation),
                    av_moderation_actors = maps:put(Kind, Occupant#user.nick, State#state.av_moderation_actors)
                },
                vm_util:set_room_state_from_jid(RoomJid, RS1),
                RS1;
            not Enable, M /= not_found ->
                RS2 = RoomState#state{
                    av_moderation = maps:remove(Kind, State#state.av_moderation),
                    av_moderation_actors = maps:remove(Kind, State#state.av_moderation_actors)
                },
                vm_util:set_room_state_from_jid(RoomJid, RS2),
                RS2;
            true ->
                RoomState
            end,
            notify_occupants_enable(S, null, Enable, Occupant#user.nick, Kind);
        #{<<"jidToWhitelist">> := JidToWhitelist} ->
            % local occupant_jid = moderation_command.attr.jidToWhitelist;
            % -- check if jid is in the room, if so add it to whitelist
            % -- inform all moderators and admins and the jid
            % local occupant_to_add = room:get_occupant_by_nick(room_jid_match_rewrite(occupant_jid));
            % if not occupant_to_add then
            %     module:log('warn', 'No occupant %s found for %s', occupant_jid, room.jid);
            %     return false;
            % end

            % if room.av_moderation then
            %     local whitelist = room.av_moderation[mediaType];
            %     if not whitelist then
            %         whitelist = array{};
            %         room.av_moderation[mediaType] = whitelist;
            %     end
            %     whitelist:push(occupant_jid);

            %     notify_whitelist_change(occupant_to_add.jid, true, room, mediaType, false);

            %     return true;
            % else
            %     -- this is a moderator asking the jid to unmute without enabling av moderation
            %     -- let's just send the event
            %     notify_jid_approved(occupant_to_add.jid, occupant.nick, room, mediaType);
            % end
            State;
        #{<<"jidToBlacklist">> := JidToBlacklist} ->
            % local occupant_jid = moderation_command.attr.jidToBlacklist;
            % -- check if jid is in the room, if so remove it from the whitelist
            % -- inform all moderators and admins
            % local occupant_to_remove = room:get_occupant_by_nick(room_jid_match_rewrite(occupant_jid));
            % if not occupant_to_remove then
            %     module:log('warn', 'No occupant %s found for %s', occupant_jid, room.jid);
            %     return false;
            % end

            % if room.av_moderation then
            %     local whitelist = room.av_moderation[mediaType];
            %     if whitelist then
            %         local index = get_index_in_table(whitelist, occupant_jid)
            %         if(index) then
            %             whitelist:pop(index);
            %             notify_whitelist_change(occupant_to_remove.jid, true, room, mediaType, true);
            %         end
            %     end

            %     return true;
            % end
            State;
        _ -> State
        end,
        {drop, State};
    _ ->
        {Packet, State}
    end;
process_message({Packet, State}) ->
    {Packet, State}.

on_join_room(State, ServerHost, Packet, JID, _Room, Nick) ->
    MucHost = gen_mod:get_module_opt(global, mod_muc, host),

    User = JID#jid.user,

    case {string:equal(Packet#presence.to#jid.server, MucHost), lists:member(User, ?WHITE_LIST_USERS)} of
    {true, false} when State#state.av_moderation /= #{} ->
        ?INFO_MSG("on_join_room: ~p", [State#state.av_moderation]),
        maps:foreach(fun (K, V) ->
            Actor = maps:get(K, State#state.av_moderation_actors),
            notify_occupants_enable(State, JID, true, Actor, K)
        end, State#state.av_moderation),

        % -- NOTE for some reason event.occupant.role is not reflecting the actual occupant role (when changed
        % -- from allowners module) but iterating over room occupants returns the correct role
        maps:foreach(fun (LJID, User) ->
            % -- if moderator send the whitelist
            if User#user.nick == Nick, User#user.role == moderator ->
                notify_whitelist_change(State, User#user.jid, false, undefined, false);
            true -> ok
            end
        end, State#state.users);
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
        maps:foreach(fun (Key, User) ->
            if Key == LJID ->
                notify_whitelist_change(State, User#user.jid, false, undefined, false);
            true -> ok
            end
        end, State#state.users);
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
