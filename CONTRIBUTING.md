# Contributing to OFEM

Thanks for considering a contribution! This is a small, focused open-source project. We welcome bug reports, feature ideas, code, docs, and design feedback.

## Project communication

- All issues, PRs, code, comments, commit messages, and documentation are in **English** so anyone can contribute, regardless of where they are.
- Be kind. See [CODE_OF_CONDUCT.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/CODE_OF_CONDUCT.md).

## Reporting bugs and requesting features

Use [GitHub Issues](https://github.com/sdebruyn/onelake-explorer-macos/issues). There are templates for both. Search first to avoid duplicates.

For **security** issues, do NOT open a public issue. See [SECURITY.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/SECURITY.md).

## Setting up your dev environment

See [docs/prerequisites.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/docs/prerequisites.md) for the full list. TL;DR:

```bash
# clone
gh repo clone sdebruyn/onelake-explorer-macos
cd onelake-explorer-macos

# install dev tools
brew install commitlint xcodegen swiftformat swiftlint periphery

# generate the Xcode project
make gen

# compile the app + .appex unsigned — no Apple account needed, this is
# what CI runs on every PR
make build-ci

# run the unit tests (OfemKit engine + host app)
make test

# to build and run a signed app on your own Mac, you additionally need a
# paid Apple Developer Program membership (see prerequisites.md), then:
make build
```

You need Xcode for all work on this project. The entire codebase is Swift. `make build-ci` is enough to verify your change compiles — you don't need a paid Apple account to contribute code.

## Branching and pull requests

- Branch off `main`.
- Name your branch like `feat/<short-description>`, `fix/<short-description>`, `docs/<short-description>`.
- Keep PRs small and focused. If a change touches multiple areas, see if it can be split.
- All PRs need passing CI: Swift build, `commitlint`.
- All PRs need at least one approving review (the maintainer's, for now). If you are the maintainer, you can self-merge.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) and enforce it in CI:

```
<type>(<optional scope>): <short summary in imperative mood>

[optional body explaining WHY, not what — the diff shows what]

[optional footer: BREAKING CHANGE, Refs #123, Closes #456]
```

Valid types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.

Examples:

```
feat(auth): persist tenant hint per-account for silent refresh
fix(onelake): honor Retry-After header on 429 responses
docs(plan): clarify exit criteria for signed builds
refactor(cache): extract SQLite schema into separate file
```

The release workflow uses these to auto-generate the release notes on each GitHub Release, so please keep them clean.

## Code style

### Swift

- SwiftFormat (nicklockwood/SwiftFormat 0.61.1) enforced in CI. Run `make format` to reformat in place; `make format-lint` to check without modifying (mirrors the CI gate). The `.swiftformat` config at the repo root controls rules and excludes.
- SwiftLint (realm/SwiftLint 0.63.3) enforced in CI. Run `make lint` to check locally (mirrors the CI gate). The `.swiftlint.yml` config at the repo root controls rules and excludes. Error-level violations fail CI; warnings are informational.
- Periphery (peripheryapp/periphery 3.7.4) detects dead code in CI. Run `periphery scan` locally to check. The `.periphery.yml` config at the repo root controls targets and exclusions. Intentionally retained symbols (e.g. XPC protocol conformances, public API) are annotated with `// periphery:ignore`. The dead-code scan runs periphery in strict mode (any finding fails the job). It is not (yet) in the branch-protection required checks, so a finding surfaces as a red check rather than hard-blocking the merge button.
- Use `os.log` (unified logging) for everything that should land in Console.app.
- Avoid blocking the File Provider Extension's main queue; everything should be async via `Task { … }`.
- Tests live in `Tests/` in the OfemKit package and in `OneLakeHostTests/` for the host app.
- OfemKit tests use [swift-testing](https://github.com/swiftlang/swift-testing) (`@Test`); the host-app tests use `XCTest`. Prefer small, focused test functions with descriptive names.

## Testing

- Unit tests run on every PR and merge to main, host-less and unsigned. They don't touch the network — OneLake and Fabric HTTP calls are mocked.
- Run them with `make test` (OfemKit engine + host app), or `cd Packages/OfemKit && swift test` for the engine alone.
- Aim for >80% line coverage on `Packages/OfemKit/Sources/`.
- Integration tests run against a live Fabric workspace and exercise the real OneLake DFS data plane and Fabric REST discovery — no mocks. They are gated behind `OFEM_INTEGRATION=1` and skipped in the normal unit-test pass. Run them with `make test-integration`; this requires bearer tokens and workspace coordinates in the environment (`OFEM_TOKEN_ONELAKE`, `OFEM_TOKEN_FABRIC`, `OFEM_TEST_WORKSPACE_ID`, `OFEM_TEST_LAKEHOUSE_ID`) — see [docs/auth.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/docs/auth.md) for how CI provisions those. In CI they run on a schedule, on demand, and on any pull request that carries the `integration` label (via `.github/workflows/integration.yml`).
- The warehouse tests additionally read a prepared Delta table. Seed it first with `scripts/prep_warehouse.sql` via [go-sqlcmd](https://github.com/microsoft/go-sqlcmd) (`brew install sqlcmd`), which authenticates with your `az login` identity — no password or secret:

  ```bash
  sqlcmd -S "$OFEM_TEST_WH_SERVER" -d "$OFEM_TEST_WH_DATABASE" \
         --authentication-method ActiveDirectoryAzCli \
         -v table="$OFEM_TEST_WH_TABLE" -i scripts/prep_warehouse.sql -b
  ```

  Then set `OFEM_TEST_WAREHOUSE_ID` to enable the warehouse suite. CI runs the seed step automatically before the tests.

## Documentation

- Significant behavior changes go in `docs/` and link from README if user-facing.
- Markdown only. No images unless they show something not expressible in text.
- Use the doc per topic, not a giant README. See existing structure.

## Releasing (maintainer)

```bash
git tag v2026.05.1
git push origin v2026.05.1
```

GitHub Actions does the rest: build, sign, notarize, DMG, GitHub Release upload, cask bump.

See [docs/packaging-homebrew.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/docs/packaging-homebrew.md) for full pipeline details and [docs/prerequisites.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/docs/prerequisites.md) for the secrets that must be configured.

## Questions?

Open a [Discussion](https://github.com/sdebruyn/onelake-explorer-macos/discussions) (once enabled) or an Issue. Don't email — keep the conversation public so the next person can find it.
