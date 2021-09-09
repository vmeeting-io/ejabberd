-module(mod_conference_duration).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/6,
    disco_local_identity/5, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("conference_duration started ~n", []),
    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(vm_join_room, Host, ?MODULE, on_join_room, 100).

stop(Host) ->
    ?INFO_MSG("conference_duration stoped ~n", []),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(vm_join_room, Host, ?MODULE, on_join_room, 100).

on_join_room(State, ServerHost, _Packet, JID, _Room, _Nick) ->
    User = JID#jid.user,

    % <message
    %   from='conferenceduration.vmeeting.io'
    %   xmlns='jabber:client'
    %   to='76f4a5db-95e1-40a5-b684-3b7b34a5f8ad@vmeeting.io/rq6DZ8Xr'>
    %   <json-message xmlns='http://jitsi.org/jitmeet'>
    %       {
    %           &quot;created_timestamp&quot;:1625050574000,
    %           &quot;type&quot;:&quot;conference_duration&quot;
    %       }
    %   </json-message>
    % </message>

    case lists:member(User, ?WHITE_LIST_USERS) of
    true -> ok;
    false ->
        State1 = case State of 
        #state{created_timestamp = TS} when TS == 0 ->
            TS1 = erlang:system_time(millisecond),
            State#state{ created_timestamp = TS1 };
        _ ->
            State
        end,
        #state{jid = RoomJid, created_timestamp = CreatedTimeStamp} = State1,
        % ?INFO_MSG("conference_duration:on_join_room ~ts ~ts ~b", [jid:encode(RoomJid), jid:encode(JID), CreatedTimeStamp]),
        JsonMessage = #{type => conference_duration,
            created_timestamp => CreatedTimeStamp},
        Msg = #message{
            from = jid:make(<<"conferenceduration.", ServerHost/binary>>),
            to = JID,
            sub_els = [#json_message{data = jiffy:encode(JsonMessage)}]
        },
        ejabberd_router:route(Msg)
    end,
    State.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_conference_duration")}.

%% -------
%% disco hooks handling functions
%%

-spec disco_local_identity([identity()], jid(), jid(),
			   binary(), binary()) -> [identity()].
disco_local_identity(Acc, _From, To, <<>>, _Lang) ->
    ToServer = To#jid.server,
    [#identity{category = <<"component">>,
	       type = <<"conference_duration">>,
	       name = <<"conferenceduration.", ToServer/binary>>}
    | Acc];
disco_local_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.
