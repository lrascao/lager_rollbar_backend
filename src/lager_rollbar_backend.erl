%% @doc Rollbar lager backend.

%% Notifies Rollbar of error (or more critical) log messages from lager.
%%
%% More info on Lager see: https://github.com/basho/lager/
%% More info on Rollbar see: https://rollbar.com
%%
-module(lager_rollbar_backend).

-behaviour(gen_event).

-export([init/1,
         handle_call/2,
         handle_event/2,
         handle_info/2,
         terminate/2,
         code_change/3
        ]).

%% exported only to prevent (Warning: function http_client/1 is unused)
-export([http_client/1, all_pass_filter/2]).

-define(DEFAULT_HTTP_ENDPOINT, <<"https://api.rollbar.com/api/1">>).

-type filter_state() :: term().

-record(state, {level :: pos_integer(),
                access_token :: binary(),
                environment :: binary(),
                platform :: binary(),
                host :: binary(),
                branch :: binary(),
                transport :: tuple(atom(), atom()),
                filter :: tuple(atom(), atom()),
                filter_state = undefined :: filter_state()}).
-type state() :: #state{}.

%% @private
-spec init([{atom(), term()}]) -> {ok, #state{}}.
init(Args) when is_list(Args) ->
  Level = proplists:get_value(level, Args, error),
  AccessToken = proplists:get_value(access_token, Args, <<"">>),
  Environment = to_binary(proplists:get_value(environment, Args, undefined)),
  Platform = to_binary(proplists:get_value(platform, Args, undefined)),
  Host = to_binary(proplists:get_value(host, Args, undefined)),
  Branch = to_binary(proplists:get_value(branch, Args, undefined)),
  {ok, #state{level = lager_util:level_to_num(Level),
              access_token = AccessToken,
              environment = Environment,
              platform = Platform,
              host = Host,
              branch = Branch,
              transport = proplists:get_value(transport, Args,
                                              {lager_rollbar_backend, http_client}),
              filter = proplists:get_value(filter, Args,
                                              {lager_rollbar_backend, all_pass_filter})}}.

%% @private
handle_call(get_loglevel, #state{level = Level} = State) ->
  {ok, Level, State};
handle_call({set_loglevel, Level}, State) ->
  {ok, ok, State#state{level = Level}};
handle_call(_Request, State) ->
  {ok, ok, State}.

-spec to_binary(atom()) -> binary().
%% @private
to_binary(undefined) -> <<"">>;
to_binary(A) when is_atom(A)  -> list_to_binary(atom_to_list(A)).

-spec http_client(binary()) -> ok.
http_client(Data) ->
    Resource = <<?DEFAULT_HTTP_ENDPOINT/binary, "/item/">>,
    {ok, _} = hackney:request(post, Resource,
                                      [{<<"content-type">>, <<"application/json">>}],
                                      Data,
                                      [{timeout, 5000}, async]),
    ok.

-spec all_pass_filter(list(), filter_state()) -> {pass | drop, filter_state()}.
all_pass_filter(_Data, FilterState) ->
  {pass, FilterState}.

-spec send_message(erollbar_message:msg(), state()) -> ok.
send_message(Message, #state{access_token = AccessToken,
                             environment = Environment,
                             platform = Platform,
                             host = Host,
                             branch = Branch,
                             transport = {Module, Function}}) ->
    %% encode the rollbar request
    Details = erollbar_encoder:create([{platform, Platform},
                                       {environment, Environment},
                                       {host, Host},
                                       {branch, Branch}]),
    Data0 = erollbar_encoder:encode(Message, AccessToken, Details),
    Data = jsx:encode(Data0),
    %% invoke the transport method that will move the data
    ok = Module:Function(Data),
    ok.

%% @private
filter_message(ErollbarMessage, #state{filter = {FilterModule, FilterMethod},
                                       filter_state = FilterState0} = State) ->

    MessagePropList = erollbar_message:get_proplist(ErollbarMessage),
    Message = case erollbar_message:type(ErollbarMessage) of
                message -> proplists:get_value(body, MessagePropList);
                trace -> proplists:get_value(message, MessagePropList)
              end,
    %% invoke the filter method
    {FilterDecision, NewFilterState} =
      FilterModule:FilterMethod(Message, FilterState0),
    %% now handle the message or not depending on the filter decision
    case FilterDecision of
        drop ->
          State#state{filter_state = NewFilterState};
        pass ->
          send_message(ErollbarMessage, State),
          State#state{filter_state = NewFilterState}
    end.

%% @private
%% Process crash report messages are handled and reported as simple messages
-spec handle_lager_message(list(), lager_msg:lager_msg(), state()) -> state().
handle_lager_message("CRASH REPORT "++_ = Message0, _LogMsg, State) ->
    Message = lists:flatten(Message0),
    {ok, [_Pid, _Neighbours, _Type, Reason], Rest} =
      io_lib:fread("CRASH REPORT Process ~s with ~s neighbours ~s with reason: ~s", Message),

    R0 = erollbar_message:message("Crash: " ++ Reason ++ Rest),
    R = erollbar_message:level(error, R0),
    filter_message(R, State);
%% Supervisors relaunching worker messages are ignored
handle_lager_message("Supervisor "++_, _LogMsg, State) -> State;
%% as well as specific gen_ process crashes, they are already being reported
%% as generic process crashes
handle_lager_message("gen_server "++_, _LogMsg, State) -> State;
handle_lager_message("gen_fsm "++_, _LogMsg, State) -> State;
handle_lager_message("gen_event  "++_, _LogMsg, State) -> State;
%% also drop ranch listener errors
handle_lager_message("Ranch listener "++_, _LogMsg, State) -> State;
%% however user reported error messages are to be logged
handle_lager_message(Message0, LogMsg, State) ->
    Message = lists:flatten(Message0),
    Metadata = lager_msg:metadata(LogMsg),

    %% build a rollbar frame from the metadata provided
    Frame0 = erollbar_message:frame(proplists:get_value(module, Metadata,
                                                        "unknown module")),
    Frame1 = erollbar_message:lineno(proplists:get_value(line, Metadata, 0),
                                     Frame0),
    Frame2 = erollbar_message:method(proplists:get_value(function, Metadata,
                                                         "unknown method"),
                                     Frame1),
    Pid = case proplists:get_value(pid, Metadata) of
            P when is_pid(P) -> pid_to_list(P);
            _ -> "unknown_pid"
          end,
    CodeLocation = Pid ++
                   "/" ++
                   atom_to_list(proplists:get_value(application, Metadata, unknown_app)) ++
                   "/" ++
                   atom_to_list(proplists:get_value(node, Metadata, unknown_node)),
    Frame = erollbar_message:code(CodeLocation, Frame2),

    R0 = erollbar_message:trace(atom_to_list(lager_msg:severity(LogMsg))),
    R1 = erollbar_message:message(Message, R0),
    R2 = erollbar_message:description(Message, R1),
    R3 = erollbar_message:frames([Frame], R2),
    R = erollbar_message:level(lager_msg:severity(LogMsg), R3),
    filter_message(R, State).

%% @private
handle_event({log, LogMsg}, #state{level = Level} = State)  ->
  NewState = case lager_util:is_loggable(LogMsg, Level, rollbar) of
              true ->
                  handle_lager_message(lager_msg:message(LogMsg), LogMsg, State);
              _ -> State
             end,
  {ok, NewState};
handle_event(_Event, State) ->
  {ok, State}.

%% @private
handle_info(_Info, State) ->
  {ok, State}.

%% @private
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% @private
terminate(_Reason, _State) ->
  ok.
