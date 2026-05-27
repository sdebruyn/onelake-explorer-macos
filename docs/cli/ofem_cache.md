---
title: ofem cache
---

## ofem cache

Inspect and manage the local OneLake blob cache

### Synopsis

Inspect and manage the local OneLake blob cache.

The cache lives under ~/Library/Group Containers/group.dev.debruyn.ofem/cache
and is shared with the background daemon and the File Provider Extension.
Use 'ofem cache size' to see how much disk the cached blobs occupy,
'ofem cache clear' to drop them all, and 'ofem cache evict' to run a
manual LRU eviction down to the configured limit (see 'ofem config get
cache.max_size').

### Options

```
  -h, --help   help for cache
```

### SEE ALSO

* [ofem](ofem.md)	 - OneLake Explorer for macOS
* [ofem cache clear](ofem_cache_clear.md)	 - Delete every blob from the local cache
* [ofem cache evict](ofem_cache_evict.md)	 - Run LRU eviction down to the configured cache.max_size
* [ofem cache size](ofem_cache_size.md)	 - Show current cache usage and the configured limit

