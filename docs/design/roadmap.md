# Roadmap

Phase-by-phase milestones. The single source of truth is [PLAN.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/PLAN.md) in the repo; this page summarises and links into open issues.

## Phase 0 — internal core (in progress, ~90% done)

Build the Go core library and CLI plumbing so the File Provider Extension can sit on a solid foundation. Not released publicly.

| Milestone | Status |
|---|---|
| Repo scaffolding, CI/lint/release tooling | ✅ |
| Opt-out telemetry (App Insights free tier) | ✅ |
| Auth foundation (Account, Registry, Keychain wrapper) | ✅ |
| MSAL Go + interactive browser + device-code flows | ✅ |
| Fabric REST + OneLake DFS clients | ✅ |
| SQLite metadata + sharded LRU blob cache | ✅ |
| Sync engine (enumerate, open, put, delete, mkdir) | ✅ |
| Daemon + LaunchAgent + Unix-socket IPC | ✅ |
| Wire sync engine + telemetry into daemon | 🔄 in flight |
| Adaptive poller for recently-touched folders | 🔄 in flight |

Exit criteria: `ofe login → ofe daemon start → ofe debug ls work:/myws/lh.lakehouse/Files` works end-to-end with telemetry events flowing.

## Phase 1 — MVP (first public release)

Apple Developer Program enrolment, Xcode project, signed and notarized `OneLake.app` with File Provider Extension shipped via Homebrew cask. Real users.

| Milestone | Status |
|---|---|
| Xcode project skeleton + entitlements | ⏳ |
| cgo C-archive of the Go core | ⏳ |
| Swift host app | ⏳ |
| File Provider Extension implementation | ⏳ |
| Code-sign + notarytool + create-dmg in CI | ⏳ |
| `homebrew-ofe` tap with the cask | ⏳ |
| First-run disclosure for opt-out telemetry | ⏳ |
| Beta test with 2–3 willing volunteers | ⏳ |
| Tag `v2026.MM.1` — first public release | ⏳ |

Exit criteria: `brew install --cask ofe` on a clean Mac succeeds, `ofe login` and Finder show OneLake end-to-end.

## Phase 2 — host app GUI

Replace the CLI for account management for users who don't live in a terminal.

| Milestone | Status |
|---|---|
| SwiftUI account-management screen | ⏳ |
| Menu bar status icon | ⏳ |
| First-run guided flow | ⏳ |
| Settings screen | ⏳ |

## Phase 3 — polish

| Milestone | Status |
|---|---|
| Spotlight metadata | ⏳ |
| Quick Look extensions | ⏳ |
| Smart prefetch heuristics | ⏳ |
| Bandwidth throttling controls | ⏳ |
| Memory footprint audit (target <50 MB idle) | ⏳ |
| Accessibility audit | ⏳ |

## What is explicitly out of scope

- Windows or Linux ports.
- Sovereign clouds (US Gov, China, Germany) — unless a user files an issue.
- Service-principal authentication.
- Editing OneLake table metadata (Iceberg / Delta REST APIs).
- Permission management — those go through the Fabric portal.
- Workspace / item creation, rename, or deletion.
- Browser-based version.
- Mobile apps (iOS, iPadOS).

## How to influence the roadmap

File [issues](https://github.com/sdebruyn/onelake-explorer-macos/issues) for bugs and feature requests. Vote with 👍 reactions — they are checked weekly during triage.
