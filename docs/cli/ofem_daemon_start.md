---
title: ofem daemon start
---

## ofem daemon start

Start the daemon

### Synopsis

Start the OFEM daemon now. If it is already running, it is
restarted in place. If launchd has forgotten the service (for example
after 'ofem daemon stop'), it is re-bootstrapped from the installed
plist.

```
ofem daemon start [flags]
```

### Options

```
  -h, --help   help for start
```

### SEE ALSO

* [ofem daemon](ofem_daemon.md)	 - Manage the OFEM background service

