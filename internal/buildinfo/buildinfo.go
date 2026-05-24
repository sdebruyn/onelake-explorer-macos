// Package buildinfo holds build-time identity values: version, commit,
// build date, and the Application Insights connection string used for
// opt-out telemetry. Version, Commit and Date are populated at link
// time by goreleaser; AppInsightsConnString is a committed constant so
// every build — release, source, or fork — reports identically.
package buildinfo

// Version is the CalVer release string (e.g. "2026.05.1"). Set via
// -ldflags "-X github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo.Version=...".
// In a plain `go build` it stays "dev".
var Version = "dev"

// Commit is the short git commit SHA. Optional; set via ldflags.
var Commit = ""

// Date is the ISO-8601 build timestamp. Optional; set via ldflags.
var Date = ""

// AppInsightsConnString is the Application Insights connection string
// every OFEM build reports to.
//
// It is deliberately a committed constant rather than a build-time
// secret. Per Microsoft's design and documentation, an Application
// Insights connection string is write-only and is meant to be public —
// the same string ships in every browser-side JS app, mobile binary,
// or desktop app that uses Application Insights. Committing it here
// does not change the security posture (any user can already extract
// it from the official cask release with `strings`) and it has one
// concrete upside: source-built binaries and forks participate in the
// shared opt-out telemetry stream too, so the maintainer gets a
// representative signal instead of only the Homebrew users.
//
// Users disable telemetry per install with `ofem config set telemetry
// off` or `OFEM_TELEMETRY=0`. There is no opt-in path that requires
// editing this file.
const AppInsightsConnString = "InstrumentationKey=bb7c05e2-4616-4b8d-a18a-e32128034eb4;IngestionEndpoint=https://westeurope-5.in.applicationinsights.azure.com/;LiveEndpoint=https://westeurope.livediagnostics.monitor.azure.com/;ApplicationId=427c95d5-7252-4513-aed3-e1e5c3eece9d"
