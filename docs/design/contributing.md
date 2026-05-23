# How to contribute

This is open source under the MIT License. Code, tests, docs, and design are all welcome.

## TL;DR

```bash
gh repo clone sdebruyn/onelake-explorer-macos
cd onelake-explorer-macos
./scripts/check-prereqs.sh         # verify your toolchain
brew install go golangci-lint commitlint
go mod download
make ci                            # fmt + vet + lint + race tests + build + smoke
```

See [Prerequisites](../prerequisites.md) for the full split between local-dev and release tooling.

## Workflow

- **Branch off `main`.** Name your branch `feat/<short>`, `fix/<short>`, `docs/<short>`, `chore/<short>`.
- **Keep PRs small and focused.** If a change touches multiple areas, see whether it can be split.
- **Conventional Commits required** — enforced in CI by commitlint. Valid types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- **All PRs need passing CI** — `gofmt`, `golangci-lint`, `go test -race`, `commitlint`.
- **At least one approving review** required before merge. The maintainer can self-merge.

## Code style

### Go

- `gofmt` + `goimports` on save. Pre-commit hook recommended.
- Run `golangci-lint run --config .golangci.yml ./...` locally before pushing — same config CI runs.
- Prefer small packages with clear responsibilities. Avoid `util` and `helpers` packages.
- Tests live next to the code they test.
- Use `log/slog` for logging; never `fmt.Println` from non-CLI code.

### Swift (Phase 1+)

- SwiftLint config will land with the Xcode project.
- Use `os.log` (unified logging) for anything that should land in Console.app.
- Avoid blocking the File Provider Extension's main queue; everything async via `Task { … }`.

## Tests

- **Unit tests** run on every PR and merge to `main`. Should not require network — use `httpmock` for OneLake/Fabric responses.
- **Integration tests** run weekly on `main` and on PRs with a `/integration` comment from the maintainer. They hit a real Fabric workspace and are gated behind `OFE_INTEGRATION=1`.
- Aim for **>80% line coverage** on `internal/*`.

## Documentation

- Significant user-visible behaviour changes go in [docs/](../) and link from the README.
- Markdown only. Images sparingly.
- Use the doc per topic, not a giant README.

## Security

Please do not open a public issue for security problems. Use [GitHub Private Security Advisories](https://github.com/sdebruyn/onelake-explorer-macos/security/advisories/new) — full policy in [SECURITY.md](https://github.com/sdebruyn/onelake-explorer-macos/blob/main/SECURITY.md).

## Releasing (maintainers)

```bash
git tag v2026.05.1
git push origin v2026.05.1
```

GitHub Actions does the rest: build, sign, notarize, DMG, GoReleaser, cask bump in the `homebrew-ofe` tap. Full pipeline: [Packaging](../packaging-homebrew.md).
