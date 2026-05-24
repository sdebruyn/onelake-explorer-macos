---
title: ofem cache clear
---

## ofem cache clear

Delete every blob from the local cache

### Synopsis

Delete every blob from the local cache.

Metadata rows survive (the sync engine still needs them to track what
exists remotely); only the cached file contents are removed. The next
access re-downloads the bytes from OneLake.

Prompts for confirmation unless --yes is given.

```
ofem cache clear [flags]
```

### Options

```
  -h, --help   help for clear
  -y, --yes    skip the interactive confirmation
```

### SEE ALSO

* [ofem cache](ofem_cache.md)	 - Inspect and manage the local OneLake blob cache

