pcache: Erlang Process Based Cache
==================================

pcache uses erlang processes to auto-expire cache items.

pcache is an improved version of the cache described in http://duomark.com/erlang/publications/acm2006.pdf

Usage
-----
The cache server is designed to memoize a specific Module:Fun. The key in
a cache is the Argument passed to Module:Fun/1.

Start a cache:

        CacheName = my_cache,
        M = database,
        F = get_result,
        Size = 16,     % 16 MB cache
        Time = 300000, % 300k ms = 300s = 5 minute TTL
        Server = pcache_server:start_link(CacheName, M, F, Size, Time).

The TTL is an idle timer TTL.  Each entry resets to the TTL when accessed.
A cache with a five minute TTL will expire an entry when nothing touches it for five minutes.
The entry timer resets to the TTL every time an item is read.  You need to dirty a key when 
the result of M:F(Key) will change from what is in the cache.

Use a cache:

        Result = pcache:get(my_cache, <<"bob">>).
        pcache:dirty(my_cache, <<"bob">>, <<"newvalue">>).  % replace entry for <<"bob">>
        pcache:dirty(my_cache, <<"bob">>).  % remove entry from cache
        pcache:empty(my_cache).  % remove all entries from cache
        RandomValues = pcache:rand(my_cache, 12).
        RandomKeys = pcache:rand_keys(my_cache, 12).

Bonus feature: use arbitrary M:F/1 calls in a cache:

        Result = pcache:memoize(my_cache, OtherMod, OtherFun, Arg).
        pcache:dirty_memoize(my_cache, OtherMod, OtherFun, Arg).  % remove entry from cache

`pcache:memoize/4` helps us get around annoying issues of one-cache-per-mod-fun.
Your root cache Mod:Fun could be nonsense if you want to use `pcache:memoize/4` everywhere.

Short-hand to make a supervisor entry:

       SupervisorWorkerTuple = pcache:cache_sup(Name, M, F, Size).

Status
------
pcache is production ready.  It has been used by some of the smallest sites on the Internet for years.

Building
--------
        rebar compile

Testing
-------
        rebar eunit suite=pcache

TODO
----
### Add tests for

* Other TTL variation
* Reaper
* Highly concurrent execution (guard against key collisions)

### Future features

* Add option for storing cache entries in a compressed ETS table
  * Countdown processes can handle ets lookups
  * When the key times out, it deletes its own data from ets
* Cache pools?  Cross-server awareness?
