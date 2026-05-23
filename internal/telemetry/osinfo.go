//go:build !darwin

package telemetry

// OSVersion is the non-darwin fallback. The OFEM shipping binaries are
// macOS-only, but keeping the package cross-compilable is useful for
// developers running `go vet ./...` on Linux CI runners.
func OSVersion() string { return "" }
