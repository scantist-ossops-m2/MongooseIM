%% @doc Provide an interface for frontends (like graphql or ctl) to manage accounts.
-module(mongoose_account_api).

-export([list_users/1,
         count_users/1,
         list_old_users/1,
         list_old_users_for_domain/2,
         register_user/3,
         register_generated_user/2,
         unregister_user/1,
         unregister_user/2,
         delete_old_users/1,
         delete_old_users_for_domain/2,
         ban_account/2,
         ban_account/3,
         change_password/2,
         change_password/3,
         check_account/1,
         check_account/2,
         check_password/2,
         check_password/3,
         check_password_hash/3,
         check_password_hash/4,
         num_active_users/2]).

-include("mongoose.hrl").

-type register_result() :: {ok | exists | invalid_jid | cannot_register, iolist()}.

-type unregister_result() :: {ok | not_allowed | invalid_jid, string()}.

-type change_password_result() :: {ok | empty_password | not_allowed | invalid_jid, string()}.

-type check_password_result() :: {ok | incorrect | user_does_not_exist, string()}.

-type check_password_hash_result() :: {ok | incorrect | wrong_user | wrong_method, string()}.

-type check_account_result() :: {ok | user_does_not_exist, string()}.

-type num_active_users_result() :: {ok, non_neg_integer()} | {cannot_count, string()}.

-type delete_old_users_result() :: {ok, iolist()}.

-export_type([register_result/0,
              unregister_result/0,
              change_password_result/0,
              check_password_result/0,
              check_password_hash_result/0,
              check_account_result/0,
              num_active_users_result/0,
              delete_old_users_result/0]).

%% API

-spec list_users(jid:server()) -> [jid:literal_jid()].
list_users(Domain) ->
    Users = ejabberd_auth:get_vh_registered_users(Domain),
    SUsers = lists:sort(Users),
    [jid:to_binary(US) || US <- SUsers].

-spec count_users(jid:server()) -> integer().
count_users(Domain) ->
    ejabberd_auth:get_vh_registered_users_number(Domain).

-spec register_generated_user(jid:server(), binary()) -> {register_result(), jid:literal_jid()}.
register_generated_user(Host, Password) ->
    Username = generate_username(),
    JID = jid:to_binary({Username, Host}),
    {register_user(Username, Host, Password), JID}.

-spec register_user(jid:user(), jid:server(), binary()) -> register_result().
register_user(User, Host, Password) ->
    JID = jid:make(User, Host, <<>>),
    case ejabberd_auth:try_register(JID, Password) of
        {error, exists} ->
            String =
                io_lib:format("User ~s already registered at node ~p",
                              [jid:to_binary(JID), node()]),
            {exists, String};
        {error, invalid_jid} ->
            String = io_lib:format("Invalid JID ~s@~s", [User, Host]),
            {invalid_jid, String};
        {error, Reason} ->
            String =
                io_lib:format("Can't register user ~s at node ~p: ~p",
                              [jid:to_binary(JID), node(), Reason]),
            {cannot_register, String};
        _ ->
            {ok, io_lib:format("User ~s successfully registered", [jid:to_binary(JID)])}
    end.

-spec unregister_user(jid:user(), jid:server()) -> unregister_result().
unregister_user(User, Host) ->
    JID = jid:make(User, Host, <<>>),
    unregister_user(JID).

-spec unregister_user(jid:jid()) -> unregister_result().
unregister_user(JID) ->
    case ejabberd_auth:remove_user(JID) of
        ok ->
            {ok, io_lib:format("User ~s successfully unregistered", [jid:to_binary(JID)])};
        error ->
            {invalid_jid, "Invalid JID"};
        {error, not_allowed} ->
            {not_allowed, "User does not exist or you are not authorised properly"}
    end.

-spec change_password(jid:user(), jid:server(), binary()) -> change_password_result().
change_password(User, Host, Password) ->
    JID = jid:make(User, Host, <<>>),
    change_password(JID, Password).

-spec change_password(jid:jid(), binary()) -> change_password_result().
change_password(JID, Password) ->
    Result = ejabberd_auth:set_password(JID, Password),
    format_change_password(Result).

-spec check_account(jid:user(), jid:server()) -> check_account_result().
check_account(User, Host) ->
    JID = jid:make(User, Host, <<>>),
    check_account(JID).

-spec check_account(jid:jid()) -> check_account_result().
check_account(JID) ->
    case ejabberd_auth:does_user_exist(JID) of
        true ->
            {ok, io_lib:format("User ~s exists", [jid:to_binary(JID)])};
        false ->
            {user_does_not_exist, io_lib:format("User ~s does not exist", [jid:to_binary(JID)])}
    end.

-spec check_password(jid:user(), jid:server(), binary()) -> check_password_result().
check_password(User, Host, Password) ->
    JID = jid:make(User, Host, <<>>),
    check_password(JID, Password).

-spec check_password(jid:jid(), binary()) -> check_password_result().
check_password(JID, Password) ->
    case ejabberd_auth:does_user_exist(JID) of
        true ->
            case ejabberd_auth:check_password(JID, Password) of
                true ->
                    {ok, io_lib:format("Password '~s' for user ~s is correct",
                                       [Password, jid:to_binary(JID)])};
                false ->
                    {incorrect, io_lib:format("Password '~s' for user ~s is incorrect",
                                              [Password, jid:to_binary(JID)])}
            end;
        false ->
            {user_does_not_exist,
            io_lib:format("Password ~s for user ~s is incorrect because this user does not"
                          " exist", [Password, jid:to_binary(JID)])}
    end.

-spec check_password_hash(jid:user(), jid:server(), string(), string()) ->
    check_password_hash_result().
check_password_hash(User, Host, PasswordHash, HashMethod) ->
    JID = jid:make(User, Host, <<>>),
    check_password_hash(JID, PasswordHash, HashMethod).

-spec check_password_hash(jid:jid(), string(), string()) -> check_password_hash_result().
check_password_hash(JID, PasswordHash, HashMethod) ->
    AccountPass = ejabberd_auth:get_password_s(JID),
    AccountPassHash = case HashMethod of
        "md5" -> get_md5(AccountPass);
        "sha" -> get_sha(AccountPass);
        _ -> undefined
    end,
    case {AccountPass, AccountPassHash} of
        {<<>>, _} ->
            {wrong_user, "User does not exist or using SCRAM password"};
        {_, undefined} ->
            Msg = io_lib:format("Given hash method `~s` is not supported. Try `md5` or `sha`",
                                [HashMethod]),
            {wrong_method, Msg};
        {_, PasswordHash} ->
            {ok, "Password hash is correct"};
        _->
            {incorrect, "Password hash is incorrect"}
    end.

-spec num_active_users(jid:lserver(), integer()) -> num_active_users_result().
num_active_users(Domain, Days) ->
    TimeStamp = erlang:system_time(second),
    TS = TimeStamp - Days * 86400,
    try
        {ok, HostType} = mongoose_domain_api:get_domain_host_type(Domain),
        Num = mod_last:count_active_users(HostType, Domain, TS),
        {ok, Num}
    catch
        _:_ ->
            Message = io_lib:format("Cannot count active users for domain ~s", [Domain]),
            {cannot_count, Message}
    end.

-spec ban_account(jid:user(), jid:server(), binary()) -> change_password_result().
ban_account(User, Host, ReasonText) ->
    JID = jid:make(User, Host, <<>>),
    ban_account(JID, ReasonText).

-spec ban_account(jid:jid(), binary()) -> change_password_result().
ban_account(JID, ReasonText) ->
    Reason = mongoose_session_api:prepare_reason(ReasonText),
    mongoose_session_api:kick_sessions(JID, Reason),
    case set_random_password(JID, Reason) of
        ok ->
            {ok, io_lib:format("User ~s successfully banned with reason: ~s",
                               [jid:to_binary(JID), ReasonText])};
        ErrResult ->
            format_change_password(ErrResult)
    end.

-spec delete_old_users(non_neg_integer()) -> {delete_old_users_result(), [jid:literal_jid()]}.
delete_old_users(Days) ->
    Users = list_old_users_raw(Days),
    DeletedUsers = delete_users(Users),
    {{ok, format_deleted_users(DeletedUsers)}, DeletedUsers}.

-spec delete_old_users_for_domain(binary(), non_neg_integer()) ->
    {delete_old_users_result(), [jid:literal_jid()]}.
delete_old_users_for_domain(Domain, Days) ->
    Users = list_old_users_raw(Domain, Days),
    DeletedUsers = delete_users(Users),
    {{ok, format_deleted_users(DeletedUsers)}, DeletedUsers}.

-spec list_old_users(non_neg_integer()) -> {ok, [jid:literal_jid()]}.
list_old_users(Days) ->
    Users = list_old_users_raw(Days),
    {ok, lists:map(fun jid:to_binary/1, Users)}.

-spec list_old_users_for_domain(binary(), non_neg_integer()) -> {ok, [jid:literal_jid()]}.
list_old_users_for_domain(Domain, Days) ->
    Users = list_old_users_raw(Domain, Days),
    {ok, lists:map(fun jid:to_binary/1, Users)}.

%% Internal

-spec delete_users([jid:simple_bare_jid()]) -> [jid:literal_jid()].
delete_users(Users) ->
    lists:map(fun({LUser, LServer}) ->
                      JID = jid:make(LUser, LServer, <<>>),
                      ok = ejabberd_auth:remove_user(JID),
                      jid:to_binary(JID)
              end, Users).

-spec list_old_users_raw(non_neg_integer()) -> [jid:simple_bare_jid()].
list_old_users_raw(Days) ->
    lists:append([list_old_users_raw(Domain, Days) ||
                     HostType <- ?ALL_HOST_TYPES,
                     Domain <- mongoose_domain_api:get_domains_by_host_type(HostType)]).

-spec list_old_users_raw(jid:lserver(), non_neg_integer()) -> [jid:simple_bare_jid()].
list_old_users_raw(Domain, Days) ->
    Users = ejabberd_auth:get_vh_registered_users(Domain),
    % Convert older time
    SecOlder = Days * 24 * 60 * 60,
    % Get current time
    TimeStampNow = erlang:system_time(second),
    % Filter old users
    lists:filter(fun(User) -> is_old_user(User, TimeStampNow, SecOlder) end, Users).

-spec is_old_user(jid:simple_bare_jid(), non_neg_integer(), non_neg_integer()) -> boolean().
is_old_user({LUser, LServer}, TimeStampNow, SecOlder) ->
    JID = jid:make(LUser, LServer, <<>>),
    % Check if the user is logged
    case ejabberd_sm:get_user_resources(JID) of
        [] -> is_user_nonactive_long_enough(JID, TimeStampNow, SecOlder);
        _ -> false
    end.

-spec is_user_nonactive_long_enough(jid:jid(), non_neg_integer(), non_neg_integer()) -> boolean().
is_user_nonactive_long_enough(JID, TimeStampNow, SecOlder) ->
    {LUser, LServer} = jid:to_lus(JID),
    {ok, HostType} = mongoose_domain_api:get_domain_host_type(LServer),
    case mod_last:get_last_info(HostType, LUser, LServer) of
        {ok, TimeStamp, _Status} ->
            % Get user age
            Sec = TimeStampNow - TimeStamp,
            case Sec < SecOlder of
                % Younger than SecOlder
                true ->
                    false;
                %% Older
                false ->
                    true
            end;
        not_found ->
            true
    end.

format_deleted_users(Users) ->
    io_lib:format("Deleted ~p users: ~p", [length(Users), Users]).

format_change_password(ok) ->
    {ok, "Password changed"};
format_change_password({error, empty_password}) ->
    {empty_password, "Empty password"};
format_change_password({error, not_allowed}) ->
    {not_allowed, "Password change not allowed"};
format_change_password({error, invalid_jid}) ->
    {invalid_jid, "Invalid JID"}.

-spec set_random_password(JID, Reason) -> Result when
      JID :: jid:jid(),
      Reason :: binary(),
      Result :: ok | {error, any()}.
set_random_password(JID, Reason) ->
    NewPass = build_random_password(Reason),
    ejabberd_auth:set_password(JID, NewPass).

-spec build_random_password(Reason :: binary()) -> binary().
build_random_password(Reason) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:universal_time(),
    Date = iolist_to_binary(io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ",
                                          [Year, Month, Day, Hour, Minute, Second])),
    RandomString = mongoose_bin:gen_from_crypto(),
    <<"BANNED_ACCOUNT--", Date/binary, "--", RandomString/binary, "--", Reason/binary>>.

-spec generate_username() -> binary().
generate_username() ->
    mongoose_bin:join([mongoose_bin:gen_from_timestamp(),
                       mongoose_bin:gen_from_crypto()], $-).

-spec get_md5(binary()) -> string().
get_md5(AccountPass) ->
    lists:flatten([io_lib:format("~.16B", [X])
                   || X <- binary_to_list(crypto:hash(md5, AccountPass))]).

-spec get_sha(binary()) -> string().
get_sha(AccountPass) ->
    lists:flatten([io_lib:format("~.16B", [X])
                   || X <- binary_to_list(crypto:hash(sha, AccountPass))]).
