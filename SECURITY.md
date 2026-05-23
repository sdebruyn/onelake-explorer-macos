# Security policy

## Supported versions

We support the latest stable release. Older releases do not receive fixes — please upgrade via Homebrew.

## Reporting a vulnerability

Please report vulnerabilities privately through **GitHub Private Security Advisories**:

https://github.com/sdebruyn/onelake-explorer-macos/security/advisories/new

Do not file a public issue and do not discuss the problem in pull requests until it has been addressed and a release is out.

### What to include

- A description of the issue and its impact.
- Steps to reproduce (a minimal proof-of-concept is great if you have one).
- Affected OFE version (`ofe --version`) and macOS version (`sw_vers`).
- Your suggested fix, if you have one — optional.

### What to expect

- An acknowledgement within 72 hours.
- An assessment within 7 days.
- For confirmed issues, a fix and coordinated disclosure timeline. We aim for a fix within 30 days for high-severity issues.
- Credit in the release notes (unless you prefer to stay anonymous).

## Out of scope

- Vulnerabilities in dependencies that we cannot fix without upstream cooperation are reported upstream first; we will track and ship the fix as soon as upstream resolves them.
- Issues that require physical access to an unlocked Mac.
- Issues that require the user to manually run untrusted shell commands.
