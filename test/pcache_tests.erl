-module(pcache_tests).
-include_lib("eunit/include/eunit.hrl").

-export([tester/1, memoize_tester/1]).

-define(E(A, B), ?assertEqual(A, B)).
-define(_E(A, B), ?_assertEqual(A, B)).

pcache_setup() ->
  % start cache server tc (test cache)
  % 6 MB cache
  % 5 minute TTL per entry (300 seconds)
  {ok, Pid} = pcache_server:start_link(tc, pcache_tests, tester, 6, 300000),
  Pid.

pcache_cleanup(Cache) ->
  exit(Cache, normal).

tester(Key) when is_binary(Key) orelse is_list(Key) ->
  erlang:md5(Key).

memoize_tester(Key) when is_binary(Key) orelse is_list(Key) ->
  erlang:crc32(Key).

pcache_test_() ->
  {setup,
    fun pcache_setup/0,
    fun pcache_cleanup/1,
    fun(_C) ->
      [
        ?_E(erlang:md5("bob"),  pcache:get(tc, "bob")),
        ?_E(erlang:md5("bob2"), pcache:get(tc, "bob2")),
        ?_E(ok,   pcache:dirty(tc, "bob2")),
        ?_E(ok,   pcache:dirty(tc, "bob2")),
        ?_E(erlang:crc32("bob2"),
            pcache:memoize(tc, ?MODULE, memoize_tester, "bob2")),
        ?_E(ok, pcache:dirty_memoize(tc, ?MODULE, memoize_tester, "bob2")),
        ?_E(16, pcache:total_size(tc)),
        ?_E([{cache_name, tc}, {datum_count, 1}], pcache:stats(tc)),
        ?_E(ok, pcache:empty(tc)),
        ?_E(0, pcache:total_size(tc))
      ]
    end
  }.
  
