---
title: ofem daemon run
---

## ofem daemon run

Run the daemon in the foreground (used by LaunchAgent and for debugging)

### Synopsis

Run the daemon process in the foreground. The LaunchAgent invokes
this entry point under launchd; developers can also run it manually to
tail the log via stdout.

```
ofem daemon run [flags]
```

### Options

```
  -h, --help   help for run
```

### SEE ALSO

* [ofem daemon](ofem_daemon.md)	 - Manage the OFEM background service

