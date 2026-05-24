---
title: ofem cache evict
---

## ofem cache evict

Run LRU eviction down to the configured cache.max_size

### Synopsis

Run a one-shot LRU eviction pass. Drops the least-recently-used
cached blobs until the total bytes fall at or below cache.max_size_bytes.

When cache.max_size_bytes is 0 ("unlimited") eviction is a no-op.

```
ofem cache evict [flags]
```

### Options

```
  -h, --help   help for evict
```

### SEE ALSO

* [ofem cache](ofem_cache.md)	 - Inspect and manage the local OneLake blob cache

