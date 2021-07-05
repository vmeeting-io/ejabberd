-module(mod_conference_duration).
-behaviour(gen_mod).

-include_lib("xmpp/include/xmpp.hrl").

-include("logger.hrl").
-include("translate.hrl").
-include("mod_muc_room.hrl").
-include("vmeeting_common.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1, on_join_room/4,
    disco_local_identity/5, mod_doc/0]).

start(Host, _Opts) ->
    ?INFO_MSG("conference_duration started ~n", []),
    try ets:new(vm_room_data, [named_table, public])
    catch
        _:badarg -> ok
    end,

    ejabberd_hooks:add(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:add(join_room, Host, ?MODULE, on_join_room, 100).

stop(Host) ->
    ?INFO_MSG("conference_duration stoped ~n", []),
    ejabberd_hooks:delete(disco_local_identity, Host, ?MODULE, disco_local_identity, 75),
    ejabberd_hooks:delete(join_room, Host, ?MODULE, on_join_room, 100).

on_join_room(_ServerHost, Room, Host, JID) ->
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

    ?INFO_MSG("conference_duration:on_join_room ~ts ~ts ~ts", [Room, Host, jid:encode(JID)]),

    case lists:member(User, ?WHITE_LIST_USERS) of
    true -> ok;
    false ->
        case ets:lookup(vm_room_data, {Room, Host}) of
        [{{Room, Host}, #room_data{created_timestamp = CreatedTimeStamp}}] ->
            ?INFO_MSG("send message to=~ts, created_timestamp=~b", [jid:encode(JID), CreatedTimeStamp]),
            JsonMessage = #{<<"type">> => <<"conference_duration">>,
                <<"created_timestamp">> => CreatedTimeStamp},
            Msg = #message{
                from = jid:make(<<"conferenceduration.", _ServerHost/binary>>),
                to = JID,
                json_message = xmpp:mk_text(jiffy:encode(JsonMessage))},
            ejabberd_router:route(Msg);
        _ ->
            ?INFO_MSG("look up not found ~ts", []),
            ok
        end
    end.

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
