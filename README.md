pcache: Erlang Process Based Cache
==================================

[![Build Status](https://secure.travis-ci.org/mattsta/pcache.png)](http://travis-ci.org/mattsta/pcache)

pcache uses erlang processes to auto-expire cache items.

pcache is an improved version of the cache described in http://duomark.com/erlang/publications/acm2006.pdf

Modern Era Update
-----------------
pcache was my first attempt at a generalized erlang caching framework (based around the paper above) and is still a good reference for one-item-per-process style caching.

For production use, [ecache](https://github.com/mattsta/ecache) is recommended instead.  ecache has more features, compression (because cache items are stored in ets), and helpful stack traces when your backing cache functions fail.

Usage
-----
The cache server is designed to memoize a specific Module:Fun. The key in
a cache is the Argument passed to Module:Fun/1.

Start a cache:

```erlang
CacheName = my_cache,
M = database,
F = get_result,
Size = 16,     % 16 MB cache
Time = 300000, % 300k ms = 300s = 5 minute TTL
Server = pcache_server:start_link(CacheName, M, F, Size, Time).
```

The TTL is an idle timer TTL.  Each entry resets to the TTL when accessed.
A cache with a five minute TTL will expire an entry when nothing touches it for five minutes.
The entry timer resets to the TTL every time an item is read.  You need to dirty a key when 
the result of M:F(Key) will change from what is in the cache.

Use a cache:

```erlang
Result = pcache:get(my_cache, <<"bob">>).
pcache:dirty(my_cache, <<"bob">>, <<"newvalue">>).  % replace entry for <<"bob">>
pcache:dirty(my_cache, <<"bob">>).  % remove entry from cache
pcache:empty(my_cache).  % remove all entries from cache
RandomValues = pcache:rand(my_cache, 12).
RandomKeys = pcache:rand_keys(my_cache, 12).
```

Bonus feature: use arbitrary M:F/1 calls in a cache:

```erlang
Result = pcache:memoize(my_cache, OtherMod, OtherFun, Arg).
pcache:dirty_memoize(my_cache, OtherMod, OtherFun, Arg).  % remove entry from cache
```

`pcache:memoize/4` helps us get around annoying issues of one-cache-per-mod-fun.
Your root cache Mod:Fun could be nonsense if you want to use `pcache:memoize/4` everywhere.

Short-hand to make a supervisor entry:

```erlang
SupervisorWorkerTuple = pcache:cache_sup(Name, M, F, Size).
```

Status
------
pcache was used in production for years, but has been replaced by [ecache](https://github.com/mattsta/ecache) for more modern usage.

History
-------
I originally wrote this in August 2007 and used it for my own projects over a few years before packaging it into a public release in 2010.

### Version 1.0

Initial basic release.  Supports Erlang versions before 18.0 (uses `erlang:now()` for TTL math).

### Version 2.0

Modern release.  Uses `os:timestamp()` instead of `now()` for TTL math.

No future improvements are planned.  For production use, see [ecache](https://github.com/mattsta/ecache) instead.

Building
--------
        rebar compile

Testing
-------
        rebar eunit suite=pcache
