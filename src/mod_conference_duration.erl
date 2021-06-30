-module(mod_conference_duration).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").

% TODO: get the whitelist value from config file
-define (WHITE_LIST_USERS, [<<"focus">>, <<"jvb">>, <<"jibri">>,
                    <<"jvbbrewery">>, <<"jibribrewery">>]).

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/5,
    on_start_room/4, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("mod_conference_duration started ~n", []),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 100).

stop(Host) ->
    ?INFO_MSG("mod_conference_duration stoped ~n", []),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100).

on_start_room(State, _ServerHost, Room, Host) ->
    ?INFO_MSG("room started ~p", [Room]),
    Config = State#state.config#config{created_timestamp = trunc(os:system_time() / 1000)},
    State1 = State#state{config = Config},
    State1.

on_join_room(_ServerHost, Packet, JID, RoomID, Nick) ->
    User = JID#jid.user,

    case lists:member(User, ?WHITE_LIST_USERS) of
    true -> ok;

    false ->
        SubEls = Packet#presence.sub_els,
        ElName = get_subtag(SubEls, <<"nick">>),
        Name = fxml:get_tag_cdata(ElName),
        % ElEmail = get_subtag(SubEls, <<"email">>),
        % Email = fxml:get_tag_cdata(ElEmail),
        ElStatsID = get_subtag(SubEls, <<"stats-id">>),
        StatsID = fxml:get_tag_cdata(ElStatsID),

        Body = #{
            type => <<"conference_duration">>,
            created_timestamp => trunc(os:system_time() / 1000)
        }

    end.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_conference_duration")}.

get_subtag( [El | Els], Name) ->
    case El of
      #xmlel{name = Name} -> El;
      _ -> get_subtag(Els, Name)
    end;
get_subtag([], _) -> false.
