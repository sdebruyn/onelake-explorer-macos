# Support

## Bug or feature request

[Open an issue.](https://github.com/sdebruyn/onelake-explorer-macos/issues) Templates available for both. Please search first.

## Security issues

Please do **not** open a public issue. Use [GitHub Private Security Advisories](https://github.com/sdebruyn/onelake-explorer-macos/security/advisories/new) instead.

## Questions

[GitHub Discussions](https://github.com/sdebruyn/onelake-explorer-macos/discussions) for anything that isn't a bug or feature request.

## When filing a bug, please include

1. `ofem --version` output.
2. `sw_vers` output (macOS version).
3. Steps to reproduce.

## Tenant admins

OFEM uses a multi-tenant Microsoft Entra public-client App Registration owned by the project maintainer ("OneLake File Explorer for macOS"). It asks for the `https://storage.azure.com/user_impersonation` scope — read and write OneLake files, nothing else.

To pre-consent for your tenant, an admin can visit:

```
https://login.microsoftonline.com/{tenantId}/adminconsent?client_id=939b4a06-cc18-49eb-9674-a1fc041489f6
```

## Sponsor

OFEM is volunteer-maintained. [GitHub Sponsors](https://github.com/sponsors/sdebruyn) helps cover the Apple Developer Program membership and Azure costs.
