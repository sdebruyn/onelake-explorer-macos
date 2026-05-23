package telemetry

import "context"

// NoopSink is a Sink that silently discards every event. It is used
// whenever telemetry is disabled (env var, config flag, or missing
// connection string) so that callers can keep calling Client.Track
// without branching on the disabled state.
type NoopSink struct{}

// Send returns nil immediately.
func (NoopSink) Send(context.Context, []Event) error { return nil }
