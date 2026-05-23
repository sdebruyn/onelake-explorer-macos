// Package buildinfo holds values populated at link time by goreleaser.
package buildinfo

// Version is the CalVer release string (e.g. "2026.05.1"). Set via
// -ldflags "-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Version=...".
// In a plain `go build` it stays "dev".
var Version = "dev"

// Commit is the short git commit SHA. Optional; set via ldflags.
var Commit = ""

// Date is the ISO-8601 build timestamp. Optional; set via ldflags.
var Date = ""

// AppInsightsConnString is the Application Insights connection string baked
// into official release builds. Empty in source builds, which disables
// telemetry transparently.
var AppInsightsConnString = ""
