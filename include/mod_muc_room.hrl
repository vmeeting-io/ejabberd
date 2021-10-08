%%%----------------------------------------------------------------------
%%%
%%% ejabberd, Copyright (C) 2002-2021   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-define(MAX_USERS_DEFAULT, 200).

-define(SETS, gb_sets).

-record(lqueue,
{
    queue = p1_queue:new()  :: p1_queue:queue(lqueue_elem()),
    max   = 0               :: integer()
}).

-type lqueue() :: #lqueue{}.
-type lqueue_elem() :: {binary(), message(), boolean(),
			erlang:timestamp(), non_neg_integer()}.

-record(config,
{
    title                                = <<"">> :: binary(),
    description                          = <<"">> :: binary(),
    allow_change_subj                    = true :: boolean(),
    allow_query_users                    = true :: boolean(),
    allow_private_messages               = true :: boolean(),
    allow_private_messages_from_visitors = anyone :: anyone | moderators | nobody ,
    allow_visitor_status                 = true :: boolean(),
    allow_visitor_nickchange             = true :: boolean(),
    public                               = true :: boolean(),
    public_list                          = true :: boolean(),
    persistent                           = false :: boolean(),
    moderated                            = true :: boolean(),
    captcha_protected                    = false :: boolean(),
    members_by_default                   = true :: boolean(),
    members_only                         = false :: boolean(),
    allow_user_invites                   = false :: boolean(),
    allow_subscription                   = false :: boolean(),
    password_protected                   = false :: boolean(),
    password                             = <<"">> :: binary(),
    anonymous                            = true :: boolean(),
    presence_broadcast                   = [moderator, participant, visitor] ::
          [moderator | participant | visitor],
    allow_voice_requests                 = true :: boolean(),
    voice_request_min_interval           = 1800 :: non_neg_integer(),
    max_users                            = ?MAX_USERS_DEFAULT :: non_neg_integer() | none,
    logging                              = false :: boolean(),
    vcard                                = <<"">> :: binary(),
    vcard_xupdate                        = undefined :: undefined | external | binary(),
    captcha_whitelist                    = (?SETS):empty() :: gb_sets:set(),
    mam                                  = false :: boolean(),
    pubsub                               = <<"">> :: binary(),
    lang                                 = ejabberd_option:language() :: binary(),
    meeting_id                           = <<"">> :: binary(),
    user_device_access_disabled          = false :: boolean(),
    time_remained                        = -1 :: integer()
}).

-type config() :: #config{}.

-type role() :: moderator | participant | visitor | none.
-type affiliation() :: admin | member | outcast | owner | none.

-record(user,
{
    jid :: jid(),
    nick :: binary(),
    role :: role(),
    %%is_subscriber = false :: boolean(),
    %%subscriptions = [] :: [binary()],
    last_presence :: presence() | undefined
}).

-record(subscriber, {jid :: jid(),
		     nick = <<>> :: binary(),
		     nodes = [] :: [binary()]}).

-record(activity,
{
    message_time    = 0 :: integer(),
    presence_time   = 0 :: integer(),
    message_shaper  = none :: ejabberd_shaper:shaper(),
    presence_shaper = none :: ejabberd_shaper:shaper(),
    message :: message() | undefined,
    presence :: {binary(), presence()} | undefined
}).

-record(answer, {
    name = <<"">> :: binary(),
    voters = #{} :: map()
}).

-record(poll, {
    id = <<"">> :: binary(),
    senderId = <<"">> :: binary(),
    senderName = <<"">> :: binary(),
    question = <<"">> :: binary(),
    answers = [] :: [#answer{}]
}).

-record(state,
{
    room                    = <<"">> :: binary(),
    host                    = <<"">> :: binary(),
    server_host             = <<"">> :: binary(),
    access                  = {none,none,none,none,none} :: {atom(), atom(), atom(), atom(), atom()},
    jid                     = #jid{} :: jid(),
    config                  = #config{} :: config(),
    users                   = #{} :: users(),
    subscribers             = #{} :: subscribers(),
    subscriber_nicks        = #{} :: subscriber_nicks(),
    last_voice_request_time = treap:empty() :: treap:treap(),
    robots                  = #{} :: robots(),
    nicks                   = #{} :: nicks(),
    affiliations            = #{} :: affiliations(),
    history                 = #lqueue{} :: lqueue(),
    subject                 = [] :: [text()],
    subject_author          = <<"">> :: binary(),
    just_created            = erlang:system_time(microsecond) :: true | integer(),
    activity                = treap:empty() :: treap:treap(),
    room_shaper             = none :: ejabberd_shaper:shaper(),
    room_queue              :: p1_queue:queue({message | presence, jid()}) | undefined,
    hibernate_timer         = none :: reference() | none | hibernating,
    room_id                 = <<"">> :: binary(),
    speakerstats            = #{} :: #{binary() => #{}},
    dominantSpeakerId       = <<"">> :: binary(),
    lobbyroom               = <<"">> :: binary(),
    % internal state that should be get/set directly from state value
    % i.e., get/set via intermediate functions are not implemented yet
    main_room_pid           = none :: pid() | none,
    max_durations           = -1 :: integer(),
    created_timestamp       = 0 :: non_neg_integer(),
    polls                   = [] :: [#poll{}],
    is_breakout             = false :: boolean(),
    breakout_main_room      = <<"">> :: binary(),
    timer_end_time          = 1 :: non_neg_integer()
}).

-type users() :: #{ljid() => #user{}}.
-type robots() :: #{jid() => {binary(), stanza()}}.
-type nicks() :: #{binary() => [ljid()]}.
-type affiliations() :: #{ljid() => affiliation() | {affiliation(), binary()}}.
-type subscribers() :: #{ljid() => #subscriber{}}.
-type subscriber_nicks() :: #{binary() => [ljid()]}.
