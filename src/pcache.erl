-module(pcache).
-compile(export_all).

-export([get/2, empty/1, total_size/1, stats/1, dirty/2, dirty/3, 
         rand/2, rand_keys/2]).

-export([memoize/4, dirty_memoize/4]).

%% ===================================================================
%% Supervisory helpers
%% ===================================================================

cache_sup(Name, Mod, Fun, Size) ->
  {Name,
    {pcache_server, start_link, [Name, Mod, Fun, Size]},
     permanent, brutal_kill, worker, [pcache_server]}.

cache_ttl_sup(Name, Mod, Fun, Size, TTL) ->
  {Name,
    {pcache_server, start_link, [Name, Mod, Fun, Size, TTL]},
     permanent, brutal_kill, worker, [pcache_server]}.

%% ===================================================================
%% Calls into pcache_server
%% ===================================================================

get(ServerName, Key) ->
  gen_server:call(ServerName, {get, Key}).

memoize(MemoizeCacheServer, Module, Fun, Key) ->
  gen_server:call(MemoizeCacheServer, {generic_get, Module, Fun, Key}).

dirty_memoize(MemoizeCacheServer, Module, Fun, Key) ->
  gen_server:cast(MemoizeCacheServer, {generic_dirty, Module, Fun, Key}).

empty(RegisteredCacheServerName) ->
  gen_server:call(RegisteredCacheServerName, empty).

total_size(ServerName) ->
  gen_server:call(ServerName, total_size).

stats(ServerName) ->
  gen_server:call(ServerName, stats).

dirty(ServerName, Key, NewData) ->
  gen_server:cast(ServerName, {dirty, Key, NewData}).

dirty(ServerName, Key) ->
  gen_server:cast(ServerName, {dirty, Key}).

rand(ServerName, Count) ->
  gen_server:call(ServerName, {rand, data, Count}).

rand_keys(ServerName, Count) ->
  gen_server:call(ServerName, {rand, keys, Count}).
