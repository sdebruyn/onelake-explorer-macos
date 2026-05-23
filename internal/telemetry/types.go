// Package telemetry implements OFE's opt-out usage telemetry. It buffers
// custom events in memory and forwards them to an Azure Application
// Insights resource via the v2/track ingestion endpoint.
//
// The package is wired so that telemetry stays a silent no-op in three
// situations:
//
//   - the OFE_TELEMETRY environment variable is set to "0",
//   - the user disabled telemetry via the config flag, or
//   - the binary was built without baking an Application Insights
//     connection string into buildinfo.AppInsightsConnString (i.e. a
//     plain `go build` of the source tree).
//
// See docs/telemetry.md for the schema, opt-out flow, and threat model.
package telemetry

import (
	"context"
	"time"
)

// Event is a single telemetry data point. Optional fields use their zero
// value to mean "not applicable" — except Success, which uses a *bool so
// the absence of a success/failure dimension is distinguishable from an
// explicit false.
//
// The schema mirrors docs/telemetry.md. Common fields (installId,
// appVersion, platform, arch, osVersion) are merged in by Client and
// therefore live on the Client rather than on Event.
type Event struct {
	// Time is the wall-clock timestamp of the event. When zero, Client
	// fills it in with time.Now().UTC() at enqueue time.
	Time time.Time

	// Name is the App Insights custom event name (e.g. "file_download").
	Name string

	// TenantID is the Microsoft Entra tenant GUID associated with this
	// operation. Empty for app-lifecycle events.
	TenantID string

	// AccountAliasHash is the redacted account-alias correlator
	// (sha256(alias)[:8]). Use HashAlias to compute it.
	AccountAliasHash string

	// DurationMs is the operation duration in milliseconds. Zero means
	// "not applicable".
	DurationMs int64

	// Success records whether the operation completed successfully. nil
	// means "not applicable".
	Success *bool

	// ErrorCode is a short, PII-free backend/library error code. Use
	// SafeErrorCode to scrub free-form strings before storing them here.
	ErrorCode string

	// BytesTransferred records I/O volume for file_download / file_upload.
	// Zero means "not applicable".
	BytesTransferred int64

	// ItemsChanged is used by sync_pulled. Zero means "not applicable".
	ItemsChanged int

	// CommonProps holds the installId / appVersion / platform / arch /
	// osVersion metadata that Client.Track injects automatically. Sinks
	// see the merged map; callers should not write to it directly.
	CommonProps map[string]string
}

// Sink is the transport that ships a batch of events somewhere. It is
// implemented by AppInsightsSink (production), NoopSink (telemetry
// disabled), and MemorySink (tests).
type Sink interface {
	// Send delivers events. Implementations must honor ctx for
	// cancellation and return an error if the backend rejects part or
	// all of the batch.
	Send(ctx context.Context, events []Event) error
}
