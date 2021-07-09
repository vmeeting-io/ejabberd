-module(mod_muc_meeting_id).

-behaviour(gen_mod).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%% Required by ?T macro
-include("translate.hrl").

-include("mod_muc_room.hrl").


%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1,
        on_start_room/4, mod_doc/0]).

start(Host, _Opts) ->
    % should start before other mod so that meeting id is available
    ?INFO_MSG("mod_muc_meeting_id started ~ts ~n", [Host]),
    ejabberd_hooks:add(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ok.

stop(Host) ->
    ?INFO_MSG("mod_muc_meeting_id stopped ~ts ~n", [Host]),
    ejabberd_hooks:delete(vm_start_room, Host, ?MODULE, on_start_room, 50),
    ok.

on_start_room(State, _ServerHost, _Room, _Host) ->
    % generate random UUID as a meetingId
    RandUUID = uuid:uuid_to_string(uuid:get_v4(), binary_nodash),
    Config = State#state.config#config{meeting_id = RandUUID},
    State1 = State#state{config = Config},
    State1.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
        ?T("mod_muc_meeting_id")}.
