-module(pcache_server).

-behaviour(gen_server).

-export([start_link/3, start_link/4, start_link/5, start_link/6]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([datum_loop/1]). % quiet unused function warning

-record(cache, {name, datum_index, data_module, 
                reaper_pid, data_accessor, cache_size,
                cache_policy, default_ttl, cache_used = 0}).

% make 8 MB cache
start_link(Name, Mod, Fun) ->
  start_link(Name, Mod, Fun, 8).

% make 5 minute expiry cache
start_link(Name, Mod, Fun, CacheSize) ->
  start_link(Name, Mod, Fun, CacheSize, 300000).

% make MRU policy cache
start_link(Name, Mod, Fun, CacheSize, CacheTime) ->
  start_link(Name, Mod, Fun, CacheSize, CacheTime, mru).

start_link(Name, Mod, Fun, CacheSize, CacheTime, CachePolicy) ->
  gen_server:start_link({local, Name}, 
    ?MODULE, [Name, Mod, Fun, CacheSize, CacheTime, CachePolicy], []).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_server
%%%----------------------------------------------------------------------

init([Name, Mod, Fun, CacheSize, CacheTime, CachePolicy]) ->
  DatumIndex = ets:new(Name, [set, private]),
  CacheSizeBytes = CacheSize*1024*1024,

  {ok, ReaperPid} = pcache_reaper:start(Name, CacheSizeBytes),
  erlang:monitor(process, ReaperPid),

  State = #cache{name = Name,
                 datum_index = DatumIndex,
                 data_module = Mod,
                 data_accessor = Fun,
                 reaper_pid = ReaperPid,
                 default_ttl = CacheTime,
                 cache_policy = CachePolicy,
                 cache_size = CacheSizeBytes,
                 cache_used = 0},
  {ok, State}.

locate(DatumKey, #cache{datum_index = DatumIndex, data_module = DataModule,
                  default_ttl = DefaultTTL, cache_policy = Policy,
                  data_accessor = DataAccessor} = _State) ->
  Key = key(DatumKey),
  case ets:lookup(DatumIndex, Key) of 
    [{Key, Pid, _}] -> {found, Pid};
    []           -> Pid = launch_datum(DatumKey, DatumIndex, DataModule,
                                       DataAccessor, DefaultTTL, Policy),
                    {launched, Pid};
    Other        -> {failed, Other}
  end.

locate_memoize(DatumKey, DatumIndex, DataModule,
               DataAccessor, DefaultTTL, Policy) ->
  Key = key(DataModule, DataAccessor, DatumKey),
  case ets:lookup(DatumIndex, Key) of 
    [{Key, Pid, _}] -> {found, Pid};
    []           -> Pid = launch_memoize_datum(DatumKey,
                            DatumIndex, DataModule,
                            DataAccessor, DefaultTTL, Policy),
                    {launched, Pid};
    Other        -> {failed, Other}
  end.

handle_call({location, DatumKey}, _From, State) -> 
  Status = locate(DatumKey, State),
  {reply, Status, State};

handle_call({generic_get, M, F, Key}, _From, #cache{datum_index = DatumIndex,
    data_module = _DataModule,
    default_ttl = DefaultTTL,
    cache_policy = Policy,
    data_accessor = _DataAccessor} = State) ->
%    io:format("Requesting: ~p:~p(~p)~n", [M, F, Key]),
  Reply = 
  case locate_memoize(Key, DatumIndex, M, F, DefaultTTL, Policy) of
    {failed, Other} -> {failed, Other};
      {_, DatumPid} -> case get_data(DatumPid) of
                         {ok, Data} -> Data;
                         {no_data, timeout} -> no_data
                       end
  end,
  {reply, Reply, State};

handle_call({get, Key}, _From, #cache{datum_index = DatumIndex, cache_used = Used} = State) ->
%    io:format("Requesting: (~p)~n", [Key]),
  {Reply, New_Size} = 
  case locate(Key, State) of
    {failed, Other} -> {{failed, Other}, State};
    {Found_Or_Launch, DatumPid} -> 
      Used_New = case Found_Or_Launch of
        launched -> case ets:match_object(DatumIndex, {'_', DatumPid, '_'}) of
                      [{_, _, Size}] -> Used + Size; 
                      _ -> Used
                    end;
        _ -> Used
      end,
      case get_data(DatumPid) of
        {ok, Data} -> {Data, Used_New};
        {no_data, timeout} -> {no_data, Used_New}
      end
  end,
  {reply, Reply, State#cache{cache_used = New_Size}};

handle_call(total_size, _From, #cache{datum_index = _DatumIndex, cache_used = Used} = State) ->
  {reply, Used, State};

handle_call(stats, _From, #cache{datum_index = DatumIndex} = State) ->
  EtsInfo = ets:info(DatumIndex),
  CacheName = proplists:get_value(name, EtsInfo),
  DatumCount = proplists:get_value(size, EtsInfo),
  Stats = [{cache_name, CacheName},
           {datum_count, DatumCount}],
  {reply, Stats, State};

handle_call(empty, _From, #cache{datum_index = DatumIndex} = State) ->
  AllProcs = ets:tab2list(DatumIndex),
  Pids = [Pid || {_DatumId, Pid} <- AllProcs],
  [X ! {destroy, self()} || X <- Pids],
  {reply, ok, State};

handle_call(reap_oldest, _From, #cache{datum_index = DatumIndex} = State) ->
  GetOldest = fun({_Key, Pid, _Size}, {APid, Acc}) ->
                Pid ! {last_active, self()},
                receive
                  {last_active, Pid, LastActive} ->
                    if
                      Acc =< LastActive -> {APid, Acc};
                      true -> {Pid, LastActive}
                    end
                 after 200 -> {APid, Acc}
                 end
               end,
  {OldPid, _LActive} = ets:foldr(GetOldest, {false, {9999,0,0}}, DatumIndex),
  case OldPid of
    false -> no_datum;
    _ -> OldPid ! {destroy, self()}
  end,
  {reply, ok, State};

handle_call({rand, Type, Count}, _From, 
  #cache{datum_index = DatumIndex} = State) ->
  AllPids = case ets:match(DatumIndex, {'_', '$1', '_'}) of
              [] -> [];
              Found -> lists:flatten(Found)
            end, 
  Length = length(AllPids),
  FoundData = 
  case Length =< Count of
    true  -> case Type of
               data -> [get_data(P) || P <- AllPids];
               keys -> [get_key(P) || P <- AllPids]
             end;
    false ->  RandomSet  = [crypto:rand_uniform(1, Length) || 
                              _ <- lists:seq(1, Count)],
              RandomPids = [lists:nth(Q, AllPids) || Q <- RandomSet],
              case Type of
                data -> [get_data(P) || P <- RandomPids];
                keys -> [get_key(P) || P <- RandomPids]
              end
  end,
  {reply, FoundData, State};
  
handle_call(Arbitrary, _From, State) ->
  {reply, {arbitrary, Arbitrary}, State}.

handle_cast({dirty, Id, NewData}, #cache{datum_index = DatumIndex} = State) ->
  case ets:lookup(DatumIndex, Id) of
    [{Id, Pid, _}] -> Pid ! {new_data, self(), NewData},
                   receive 
                     {new_data, Pid, _OldData} -> ok
                   after 
                     100 -> fail
                   end;
             [] -> ok
  end,
  {noreply, State};

handle_cast({dirty, Id}, #cache{datum_index = DatumIndex, cache_used=Used} = State) ->
  New_Size = case ets:lookup(DatumIndex, Id) of
    [{Id, Pid, Size}] -> Pid ! {destroy, self()},
                   receive 
                     {destroy, Pid, ok} -> ets:delete(DatumIndex, Id), 
                                           Used - Size
                   after 
                     100 -> Used 
                   end;
    [] -> Used 
  end,
  {noreply, State#cache{cache_used = New_Size}};

handle_cast({generic_dirty, M, F, A}, 
    #cache{datum_index = DatumIndex} = State) ->
  case ets:lookup(DatumIndex, key(M, F, A)) of
    [{{M, F, A}, Pid, _}] -> Pid ! {destroy, self()},
                   receive 
                     {destroy, Pid, ok} -> ok
                   after 
                     100 -> fail
                   end;
    [] -> ok
  end,
  {noreply, State}.

terminate(_Reason, _State) ->
    ok.

handle_info({destroy,_DatumPid, ok}, State) ->
  {noreply, State};

handle_info({'DOWN', _Ref, process, ReaperPid, _Reason}, 
    #cache{reaper_pid = ReaperPid, name = Name, cache_size = Size} = State) ->
  {NewReaperPid, _Mon} = pcache_reaper:start_link(Name, Size),
  {noreply, State#cache{reaper_pid = NewReaperPid}};

handle_info({'DOWN', _Ref, process, Pid, _Reason}, 
    #cache{datum_index = DatumIndex, cache_used=Used} = State) ->
  New_State = case ets:match_object(DatumIndex, {'_', Pid, '_'}) of
    [{Key, _, Size}] -> ets:delete(DatumIndex, Key),
                        State#cache{cache_used = Used - Size};
    _ -> State 
  end,
  {noreply, New_State};

handle_info(Info, State) ->
  io:format("Other info of: ~p~n", [Info]),
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


key(Key) -> Key.
key(M, F, A) -> {M, F, A}.

%% ===================================================================
%% Private
%% ===================================================================
get_data(DatumPid) ->
  DatumPid ! {get, self()},
  receive
    {get, DatumPid, Data} -> {ok, Data}
  after
    100  -> {no_data, timeout}
  end.

get_key(DatumPid) ->
  DatumPid ! {getkey, self()},
  receive
    {getkey, DatumPid, Key} -> {ok, Key}
  after
    100 -> {no_data, timeout}
  end.

-record(datum, {key, mgr, data, started,
                last_active, ttl, type = mru, remaining_ttl}).

create_datum(Key, Data, TTL, Type) ->
  #datum{key = Key, mgr = self(), data = Data, started = now(),
         ttl = TTL, remaining_ttl = TTL, type = Type}.

launch_datum(Key, EtsIndex, Module, Accessor, TTL, CachePolicy) ->
  CacheData = Module:Accessor(Key),
  UseKey = key(Key),
  Datum = create_datum(UseKey, CacheData, TTL, CachePolicy),
  {Pid, _Monitor} = erlang:spawn_monitor(?MODULE, datum_loop, [Datum]),
  {_, Size} = process_info(Pid, memory),
  ets:insert(EtsIndex, {UseKey, Pid, Size}),
  Pid.

launch_memoize_datum(Key, EtsIndex, Module, Accessor, TTL, CachePolicy) ->
  CacheData = Module:Accessor(Key),
  UseKey = key(Module, Accessor, Key),
  Datum = create_datum(UseKey, CacheData, TTL, CachePolicy),
  {Pid, _Monitor} = erlang:spawn_monitor(?MODULE, datum_loop, [Datum]),
  {_, Size} = process_info(Pid, memory),
  ets:insert(EtsIndex, {UseKey, Pid, Size}),
  Pid.

update_ttl(#datum{started = Started, ttl = TTL,
                  type = actual_time} = Datum) ->
  % Get total time in seconds this datum has been running.  Convert to ms.
  StartedNowDiff = (calendar:time_to_seconds(now()) - 
                    calendar:time_to_seconds(Started)) * 1000,
  % If we are less than the TTL, update with TTL-used (TTL in ms too)
  % else, we ran out of time.  expire on next loop.
  TTLRemaining = if
                   StartedNowDiff < TTL -> TTL - StartedNowDiff;
                                   true -> 0
                 end,
  Datum#datum{last_active = now(), remaining_ttl = TTLRemaining};
update_ttl(Datum) ->
  Datum#datum{last_active = now()}.

update_data(Datum, NewData) ->
  Datum#datum{data = NewData}.

continue(Datum) ->
  ?MODULE:datum_loop(update_ttl(Datum)).

continue_noreset(Datum) ->
  ?MODULE:datum_loop(Datum).

datum_loop(#datum{key = Key, mgr = Mgr, last_active = LastActive,
            data = Data, remaining_ttl = TTL} = State) ->
  receive
    {new_data, Mgr, Replacement} ->
      Mgr ! {new_data, self(), Data},
      continue(update_data(Replacement, State));

    {InvalidMgrRequest, Mgr, _Other} ->
      Mgr ! {InvalidMgrRequest, self(), invalid_creator_request},
      continue(State);

    {get, From} ->
      From ! {get, self(), Data},
      continue(State);

    {getkey, From} ->
      From ! {getkey, self(), Key},
      continue(State);

    {memsize, From} ->
      Size = case is_binary(Data) of
               true -> {memory, size(Data)};
                  _ -> process_info(self(), memory)
             end,
      From ! {memsize, self(), Size},
      continue_noreset(State);

    {last_active, From} ->
      From ! {last_active, self(), LastActive},
      continue(State);

    {destroy, From} ->
      From ! {destroy, self(), ok},
      % io:format("destroying ~p with last access of ~p~n", [self(), LastActive]),
      exit(self(), destroy);

    {InvalidRequest, From} ->
      From ! {InvalidRequest, self(), invalid_request},
      continue(State);

    _ -> continue(State)

  after
    TTL ->
      cache_is_now_dead
        % INSERT STATS COLLECTION INFO HERE
        % io:format("Cache object ~p owned by ~p freed~n", [Key, self()])
  end.
