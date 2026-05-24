---
title: ofem daemon install
---

## ofem daemon install

Install the LaunchAgent so OFEM starts at login

### Synopsis

Write the OFEM LaunchAgent plist to ~/Library/LaunchAgents/ and
bootstrap it under launchd. The plist points at the currently-running
ofem binary, so re-run this command after any move or upgrade that
relocates the executable.

Idempotent: re-running install when the agent is already loaded with
the same parameters is a no-op.

```
ofem daemon install [flags]
```

### Options

```
  -h, --help   help for install
```

### SEE ALSO

* [ofem daemon](ofem_daemon.md)	 - Manage the OFEM background service

