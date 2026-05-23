# Support

## Bug or feature request

Open an issue: [github.com/sdebruyn/onelake-explorer-macos/issues](https://github.com/sdebruyn/onelake-explorer-macos/issues).

There are templates for bugs and feature requests. Please search first — chances are someone else has hit the same thing.

## Security issues

Please do **not** open a public issue. Use [GitHub Private Security Advisories](https://github.com/sdebruyn/onelake-explorer-macos/security/advisories/new) instead. The full security policy is in [SECURITY.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/SECURITY.md).

## Questions or discussion

[GitHub Discussions](https://github.com/sdebruyn/onelake-explorer-macos/discussions) for anything that isn't a bug or feature request — usage questions, design feedback, "how would I…?".

## Logs to attach

When filing a bug, please include:

1. `ofem --version` output.
2. `sw_vers` output.
3. The relevant slice of `~/Library/Logs/dev.debruyn.ofem/ofem.log` — please redact any sensitive content (workspace names, file paths, tokens).
4. Steps to reproduce.

## Tenant admins

OFEM uses standard Microsoft Entra public-client flows and asks for the `https://storage.azure.com/user_impersonation` scope. If your tenant has a "Block third-party app consent" policy, OFEM requires admin consent the first time a user signs in. The consent screen identifies the app as **OneLake File Explorer for macOS** (Microsoft Entra App Registration is owned by Sam Debruyn).

To pre-consent for your whole tenant, an admin can visit `https://login.microsoftonline.com/{tenantId}/adminconsent?client_id={OFEM_CLIENT_ID}` and approve. The exact `OFEM_CLIENT_ID` will be published in the changelog with the first signed release.

## SLA and support level

This is a volunteer-maintained open-source project. Best-effort response time on issues is typically within a few days. Critical security issues are prioritised — see [SECURITY.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/SECURITY.md) for the SLA on those.

If you'd like to sponsor OFEM so maintenance can scale, [GitHub Sponsors](https://github.com/sponsors/sdebruyn) is the right channel.
