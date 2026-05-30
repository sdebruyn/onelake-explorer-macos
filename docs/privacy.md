# Privacy

OFEM sends a small amount of opt-out usage and crash data to help understand adoption and prioritise fixes.

## What we collect

- **Anonymous usage events**: which actions you take (sign in, list a workspace, open a file, sync changes), how long they take, and whether they succeeded.
- **Your Microsoft Entra tenant ID**: so we can see which tenants are using OFEM at aggregate level.
- **A pseudonymous install ID** generated locally on first run, so events from the same machine can be correlated. The ID changes if you do a full uninstall.
- **App and OS version**, so we can see whether bugs are version-specific.

## What we never collect

- Your name, email address, or UPN.
- Workspace names, item names, file names, file contents, or folder paths.
- Anything outside OFEM itself.

## How to turn it off

Open the OneLake menu bar icon and uncheck **Send Anonymous Telemetry**.

If you start the daemon yourself for development, you can also set `OFEM_TELEMETRY=0` in the environment to keep telemetry off for that process. The menu bar checkbox always reflects what the daemon is currently reporting.

## Questions

Open a [Discussion](https://github.com/sdebruyn/onelake-explorer-macos/discussions) or file an issue.
