---
title: ofem login
---

## ofem login

Sign in to OneLake (interactive browser by default)

### Synopsis

Sign in to a OneLake / Microsoft Fabric tenant.

By default ofem opens the system browser for an interactive sign-in. Use
--device-code on machines without a browser (SSH sessions, headless CI).
After authentication you are prompted for a short alias for the account
(e.g. "work", "client-a"); pick something memorable because you will use
it as the path prefix in Finder under ~/OneLake/<alias>/.

```
ofem login [flags]
```

### Options

```
      --account string   use this alias instead of prompting
      --device-code      use the device-code flow instead of the interactive browser
  -h, --help             help for login
      --tenant string    tenant GUID or domain to sign in to (default: prompt at sign-in time)
```

### SEE ALSO

* [ofem](ofem.md)	 - OneLake File Explorer for macOS

