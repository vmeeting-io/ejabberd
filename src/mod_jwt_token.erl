-module(mod_jwt_token).
-behaviour(gen_mod).

-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1,
    mod_doc/0, enable_jwt/1, jwt_secret/1, check_jwt_token/3]).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include_lib("xmpp/include/xmpp.hrl").
-include("translate.hrl").

start(Host, _Opts) ->
    ejabberd_hooks:add(check_jwt_token, Host, ?MODULE, check_jwt_token, 50).


stop(Host) ->
    ejabberd_hooks:delete(check_jwt_token, Host, ?MODULE, check_jwt_token, 50).

depends(_Host, _Opts) ->
    [].

mod_options(_) ->
    [{enable_jwt, false},
     {jwt_secret, <<"">>}].

mod_doc() ->
    #{desc =>
          ?T("xmpp_sasl_anonymous with custom jitsi jwt verification.")}.

mod_opt_type(enable_jwt) ->
    econf:bool();

mod_opt_type(jwt_secret) ->
    econf:string().

-spec enable_jwt(gen_mod:opts() | global | binary()) -> boolean().
enable_jwt(Opts) when is_map(Opts) ->
    gen_mod:get_opt(enable_jwt, Opts);
enable_jwt(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, enable_jwt).

-spec jwt_secret(gen_mod:opts() | global | binary()) -> string().
jwt_secret(Opts) when is_map(Opts) ->
    gen_mod:get_opt(jwt_secret, Opts);
jwt_secret(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, jwt_secret).



check_jwt_token(_Result, Query, Host) ->
    EnableJWT = enable_jwt(Host),
    if EnableJWT == true ->
        JWTSecret = jwt_secret(Host),
        JWK = #{
            <<"kty">> => <<"oct">>,
            <<"k">> => JWTSecret
        },
        verify_jwt_token(Query, JWK);
    true ->
        false
    end.

verify_jwt_token(Query, JWK) ->
    case {extract_token(Query), extract_room(Query)} of
    {{ok, Token}, {ok, Room}} ->
        case decode_jwt_token(Token, JWK) of
        {ok, Fields} ->
            case {verify_exp(Fields), verify_room(Fields, Room)} of
            {ok, ok} ->
                ok;
            _ ->
                false
            end;
        _ ->
            false
        end;
    _ ->
        false
    end.

decode_jwt_token(Token, JWK) ->
    try jose_jwt:verify(JWK, Token) of
        {true, {jose_jwt, Fields}, _Signature} ->
	        {ok, Fields};
        {false, _, _} ->
            {false, nil}
    catch
        Class:Err ->
            ?WARNING_MSG("(~p) ERROR ~p:~p: decode jwt token failed", [?MODULE, Class, Err]),
            {false, nil}
    end.

extract_token(Query) ->
    case lists:keyfind(<<"token">>, 1, Query) of
    {<<"token">>, Token} ->
        {ok, Token};
    _ ->
        {false, nil}
    end.

extract_room(Query) ->
    case lists:keyfind(<<"room">>, 1, Query) of
    {<<"room">>, Room} ->
        {ok, Room};
    _ ->
        {false, nil}
    end.

verify_exp(Fields) ->
    case maps:find(<<"exp">>, Fields) of
    error ->
        false;
    {ok, Exp} ->
        Now = erlang:system_time(second),
        if
            Exp > Now ->
                ok;
            true ->
                false
        end
    end.

verify_room(Fields, RequestRoom) ->
    case maps:find(<<"room">>, Fields) of
    error ->
        false;
    {ok, Room} ->
        case Room of
            <<"*">> ->
                ok;
            RequestRoom ->
                ok;
            _ ->
                false
        end
    end.


