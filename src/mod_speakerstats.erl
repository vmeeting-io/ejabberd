-module(mod_speakerstats).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

-record(vm_speakerstats, {displayName = <<>> :: binary(),
                          dominantSpeakerStart = 0 :: non_neg_integer(),
                          nick = <<>> :: binary(),
                          totalDominantSpeakerTime = 0 :: non_neg_integer()}).
-type vm_speakerstats() :: #vm_speakerstats{}.

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1,
    on_join_room/6, on_leave_room/5,
    process_message/1, disco_local_identity/5, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("speakerstats started ~ts ~n", [Host]),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(local_send_to_resource_hook, Host, ?MODULE, process_message, 50),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(vm_leave_room, Host, ?MODULE, on_leave_room, 100).

stop(Host) ->
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(local_send_to_resource_hook, Host, ?MODULE, process_message, 50),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(vm_leave_room, Host, ?MODULE, on_leave_room, 100),
    ?INFO_MSG("speakerstats stoped ~n", []).

-spec process_message(stanza()) -> stop | ok.
process_message(#message{from = From, to = #jid{luser = <<"">>, lresource = <<"">>}, type = normal, sub_els = [#xmlel{name = <<"speakerstats">>} = SpeakerStats]})
    when SpeakerStats /= undefined ->
        % ?INFO_MSG("speakerstats: process_message ~ts ~p", [jid:to_string(From), SpeakerStats]),

        #speakerstats{room = RoomAddress} = xmpp:decode(SpeakerStats),
        [Room, Host] = string:split(RoomAddress, "@"),
        case vm_util:is_healthcheck_room(RoomAddress) of 
        true ->
            stop;
        % false -> case vm_util:get_state_from_jid(vm_util:room_jid_match_rewrite(RoomAddress)) of
        false -> case vm_util:get_state_from_jid(jid:make(Room, Host)) of
            error -> 
                stop;
            {ok, State} -> 
                Nick = vm_util:find_nick_by_jid(From, State),
                DominantSpeakerId = State#state.dominantSpeakerId,
                NewDominantSpeaker = try maps:get(Nick, State#state.speakerstats)
                                     catch _:_ -> undefined end,
                OldDominantSpeaker = try maps:get(DominantSpeakerId, State#state.speakerstats)
                                     catch _:_ -> undefined end,
                NewState = State#state{dominantSpeakerId = Nick},
                NewState1 = setDominantSpeaker(OldDominantSpeaker, false, NewState),
                NewState2 = setDominantSpeaker(NewDominantSpeaker, true, NewState1),
                [Room, Host] = string:split(RoomAddress, "@"),
                vm_util:set_room_state(Room, Host, NewState2),
                stop
            end
        end.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    ?INFO_MSG("mod_speakerstats ~ts", [_Host]),
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_speakerstats")}.

%% -------
%% disco hooks handling functions
%%

-spec disco_local_identity([identity()], jid(), jid(),
			   binary(), binary()) -> [identity()].
disco_local_identity(Acc, _From, To, <<>>, _Lang) ->
    ToServer = To#jid.server,
    [#identity{category = <<"component">>,
	       type = <<"speakerstats">>,
	       name = <<"speakerstats.", ToServer/binary>>}
    | Acc];
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

% Changes the dominantSpeaker data for current occupant
% saves start time if it is new dominat speaker
% or calculates and accumulates time of speaking
setDominantSpeaker(SpeakerStats, Bool, State) ->
    case SpeakerStats of
    undefined -> State;
    _ -> 
        ?INFO_MSG("set isDominant ~ts for ~ts", [Bool, SpeakerStats#vm_speakerstats.nick]),
        Now = erlang:system_time(millisecond),
        Nick = SpeakerStats#vm_speakerstats.nick,
        DominantSpeakerStart = SpeakerStats#vm_speakerstats.dominantSpeakerStart,
        TotalDominantSpeakerTime = SpeakerStats#vm_speakerstats.totalDominantSpeakerTime,
        case {DominantSpeakerStart > 0, Bool} of
        {false, true} ->
            State#state{speakerstats = maps:put(Nick, SpeakerStats#vm_speakerstats{
                dominantSpeakerStart = Now}, State#state.speakerstats)};
        {true, false} ->
            TimeElapsed = Now - DominantSpeakerStart,
            State#state{speakerstats = maps:put(Nick, SpeakerStats#vm_speakerstats{
                totalDominantSpeakerTime = TotalDominantSpeakerTime + TimeElapsed,
                dominantSpeakerStart = 0}, State#state.speakerstats)};
        _ -> State
        end
    end.

% Create SpeakerStats object for the joined user
on_join_room(State, _ServerHost, Packet, JID, RoomID, Nick) ->
    case vm_util:is_healthcheck_room(RoomID) of
    true -> State;
    false ->
        Nick = vm_util:find_nick_by_jid(JID, State),
        case map_size(State#state.speakerstats) > 0 of
        true ->
            Users = maps:fold(fun(K, V, Acc) ->
                    case K of
                    <<"focus">> -> Acc;
                    <<"">> -> Acc;
                    _ ->
                        DisplayName = V#vm_speakerstats.displayName,
                        DominantSpeakerStart = V#vm_speakerstats.dominantSpeakerStart,
                        TotalDominantSpeakerTime = case DominantSpeakerStart > 0 of
                            true ->
                                TimeElapsed = erlang:system_time(millisecond) - DominantSpeakerStart,
                                V#vm_speakerstats.totalDominantSpeakerTime + TimeElapsed;
                            false ->
                                V#vm_speakerstats.totalDominantSpeakerTime
                        end,
                        maps:put(Nick, #{displayName => DisplayName,
                                         totalDominantSpeakerTime => TotalDominantSpeakerTime}, Acc)
                    end
                end, #{}, State#state.speakerstats),
            JsonMessage = #{type => speakerstats, users => Users},
            Msg = #message{
                from = jid:make(<<"speakerstats.", _ServerHost/binary>>),
                to = JID,
                sub_els = [#json_message{data = jiffy:encode(JsonMessage)}]},
            ejabberd_router:route(Msg);
        false -> ok
        end,
        SpeakerStats = maps:put(Nick, #vm_speakerstats{
            displayName = <<"">>,
            dominantSpeakerStart = 0,
            % context_user = context_user
            nick = Nick,
            totalDominantSpeakerTime = 0
        }, State#state.speakerstats),
        State#state{speakerstats = SpeakerStats}
    end.

% Occupant left set its dominant speaker to false and update the store the
% display name
on_leave_room(State, _ServerHost, Room, Host, JID) ->
    case vm_util:is_healthcheck_room(Room) of
    true -> State;
    false ->
        Nick = vm_util:find_nick_by_jid(JID, State),
        SpeakerStats = try maps:get(Nick, State#state.speakerstats)
                       catch _:_ -> undefined end,
        setDominantSpeaker(SpeakerStats, false, State)
    end.
