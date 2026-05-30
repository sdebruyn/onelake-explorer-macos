# Contributing to OFEM

Thanks for considering a contribution! This is a small, focused open-source project. We welcome bug reports, feature ideas, code, docs, and design feedback.

## Project communication

- All issues, PRs, code, comments, commit messages, and documentation are in **English** so anyone can contribute, regardless of where they are.
- Be kind. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Reporting bugs and requesting features

Use [GitHub Issues](https://github.com/sdebruyn/onelake-explorer-macos/issues). There are templates for both. Search first to avoid duplicates.

For **security** issues, do NOT open a public issue. See [SECURITY.md](SECURITY.md).

## Setting up your dev environment

See [docs/prerequisites.md](docs/prerequisites.md) for the full list. TL;DR:

```bash
# clone
gh repo clone sdebruyn/onelake-explorer-macos
cd onelake-explorer-macos

# install dev tools
brew install go golangci-lint commitlint

# fetch deps
go mod download

# build the daemon binary (needed by the IPC integration test in apple/)
go build -o bin/ofem ./cmd/ofem
./bin/ofem --version

# shortcut — fmt + vet + lint + test + build (matches CI)
make ci

# individual targets
make build
make test
make lint
make fmt

# run integration tests (requires a Fabric workspace you can sign in to)
OFEM_INTEGRATION=1 go test ./...
```

You only need Xcode if you are working on the Swift host app or File Provider Extension. For pure Go work on `internal/*` you can stay in your shell of choice.

## Branching and pull requests

- Branch off `main`.
- Name your branch like `feat/<short-description>`, `fix/<short-description>`, `docs/<short-description>`.
- Keep PRs small and focused. If a change touches multiple areas, see if it can be split.
- All PRs need passing CI: `gofmt`, `golangci-lint`, `go test`, `commitlint`.
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
feat(auth): support device code flow as fallback when no browser available
fix(onelake): honor Retry-After header on 429 responses
docs(plan): clarify exit criteria for signed builds
refactor(cache): extract SQLite schema into separate file
```

The release workflow uses these to auto-generate the release notes on each GitHub Release, so please keep them clean.

## Code style

### Go

- `gofmt` and `goimports` on save. Pre-commit hook recommended.
- Run `golangci-lint run` locally before pushing — same config CI runs.
- Prefer small packages with clear responsibilities. Avoid `util` and `helpers` packages.
- Tests live next to the code they test (`foo_test.go` alongside `foo.go`).
- Use table-driven tests for anything with multiple input shapes.
- No `panic()` outside `main()`'s early-init unless a programmer error genuinely cannot happen; return errors instead.
- Use `slog` from stdlib for logging; never `fmt.Println` from non-CLI code.
- All shared logic lives in `internal/*`; `cmd/ofem/` is just the daemon entry point that calls `internal/daemon`.

### Swift

- SwiftLint with the included `.swiftlint.yml`.
- Use `os.log` (unified logging) for everything that should land in Console.app.
- Avoid blocking the File Provider Extension's main queue; everything should be async via `Task { … }`.

## Testing

- **Unit tests**: run on every PR and merge to main. Should not require network. Use `httpmock` for OneLake/Fabric responses.
- **Integration tests**: run weekly on `main` and on PRs with a `/integration` comment from the maintainer. Hit real Fabric. Gated behind `OFEM_INTEGRATION=1`.
- Aim for >80% line coverage on `internal/*`.

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

See [docs/packaging-homebrew.md](docs/packaging-homebrew.md) for full pipeline details and [docs/prerequisites.md](docs/prerequisites.md) for the secrets that must be configured.

## Questions?

Open a [Discussion](https://github.com/sdebruyn/onelake-explorer-macos/discussions) (once enabled) or an Issue. Don't email — keep the conversation public so the next person can find it.
