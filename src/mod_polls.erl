-module(mod_polls).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").
-include("ejabberd_http.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, mod_doc/0,
    process_message/3, on_join_room/6]).

start(Host, _Opts) ->
    % This could run multiple times on different server host,
    % so need to wrap in try-catch, otherwise will get badarg error
    try ets:new(vm_poll_data, [named_table, public])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(muc_filter_message, Host, ?MODULE, process_message, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:delete(muc_filter_message, Host, ?MODULE, process_message, 50),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_polls")}.

% Sends the current poll state to new occupants after joining a room.
on_join_room(State, _ServerHost, _Packet, JID, _RoomID, _Nick) ->
    IsHealthCheck = vm_util:is_healthcheck_room((State#state.jid)#jid.luser),
    if not IsHealthCheck, State#state.polls /= [] ->
        JsonData = jiffy:encode(#{
            type => <<"old-polls">>,
            polls => [#{
                id => Poll#poll.id,
                senderId => Poll#poll.senderId,
                senderName => Poll#poll.senderName,
                question => Poll#poll.question,
                answers => [#{
                    name => Answer#answer.name,
                    voters => Answer#answer.voters
                } || Answer <- Poll#poll.answers]
            } || Poll <- lists:reverse(State#state.polls)]
        }),
        Msg = #message{
            from = State#state.jid,
            to = JID,
            sub_els = [#json_message{data = JsonData}]},
        ejabberd_router:route(Msg),
        ?INFO_MSG("poll message is sent: ~ts ~ts", [jid:encode(State#state.jid), jid:encode(JID)]),
        State;
    true ->
        State
    end.

% Keeps track of the current state of the polls in each room,
% by listening to "new-poll" and "answer-poll" messages,
% and updating the room poll data accordingly.
% This mirrors the client-side poll update logic.
process_message(#message{
    to = #jid{lresource = <<"">>},
    type = groupchat
} = Packet, State, _FromNick) ->
    case vm_util:get_subtag_value(Packet#message.sub_els, <<"json-message">>) of
    Data when Data /= null ->
        DecodedData = jiffy:decode(Data, [return_maps]),
        ?INFO_MSG("decoded data: ~p", [DecodedData]),
        case maps:get(<<"type">>, DecodedData) of
        <<"new-poll">> ->
            ?INFO_MSG("new-poll:", []),
            Answers = [#answer{name = Name, voters = #{}} || Name <- maps:get(<<"answers">>, DecodedData)],
            NewPoll = #poll{
                id = maps:get(<<"pollId">>, DecodedData),
                senderId = maps:get(<<"senderId">>, DecodedData),
                senderName = maps:get(<<"senderName">>, DecodedData),
                question = maps:get(<<"question">>, DecodedData),
                answers = Answers
            },
            {pass, State#state{
                polls = [NewPoll | State#state.polls]
            }};
        <<"answer-poll">> ->
            PollId = maps:get(<<"pollId">>, DecodedData),
            case lists:keyfind(PollId, 2, State#state.polls) of
            false ->
                ?INFO_MSG("anser-poll: ~ts is not found", [PollId]),
                drop;
            Poll ->
                ?INFO_MSG("answer-poll: found poll. ~n~p", [Poll]),
                VoterId = maps:get(<<"voterId">>, DecodedData),
                VoterName = maps:get(<<"voterName">>, DecodedData),
                AnswersZip = lists:zip(Poll#poll.answers, maps:get(<<"answers">>, DecodedData)),
                Poll2 = Poll#poll{
                    answers = lists:map(fun({Answer, Bool}) ->
                        Value = case Bool of true -> VoterName; false -> null end,
                        Answer#answer{ voters = maps:put(VoterId, Value, Answer#answer.voters) }
                    end, AnswersZip)
                },
                {pass, State#state{
                    polls = lists:keyreplace(PollId, 2, State#state.polls, Poll2)
                }}
            end;
        _ ->
            ?INFO_MSG("unknown poll type: ~ts", [maps:get(<<"type">>, DecodedData)]),
            drop
        end;
    _ ->
        Packet
    end;
process_message(Packet, _State, _FromNick) ->
    Packet.

