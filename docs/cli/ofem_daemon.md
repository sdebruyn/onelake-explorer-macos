---
title: ofem daemon
---

## ofem daemon

Manage the OFEM background service

### Synopsis

Manage the OFEM background service that keeps OneLake visible in Finder.

Installed once per Mac, it starts at every login and runs in the background.
You rarely interact with it directly — use 'ofem daemon install' once after
your first 'ofem login' and the daemon takes care of the rest.

### Options

```
  -h, --help   help for daemon
```

### SEE ALSO

* [ofem](ofem.md)	 - OneLake Explorer for macOS
* [ofem daemon install](ofem_daemon_install.md)	 - Install the LaunchAgent so OFEM starts at login
* [ofem daemon run](ofem_daemon_run.md)	 - Run the daemon in the foreground (used by LaunchAgent and for debugging)
* [ofem daemon start](ofem_daemon_start.md)	 - Start the daemon
* [ofem daemon stop](ofem_daemon_stop.md)	 - Stop the daemon
* [ofem daemon uninstall](ofem_daemon_uninstall.md)	 - Unload and remove the LaunchAgent

