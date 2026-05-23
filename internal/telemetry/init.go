package telemetry

import (
	"context"
	"log/slog"
	"os"

	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// Init returns a configured *Client. When telemetry is disabled — by env
// var OFE_TELEMETRY=0, by the config flag, or by an empty
// buildinfo.AppInsightsConnString — the returned client uses NoopSink
// and Track becomes a silent no-op.
//
// The caller is responsible for invoking Client.Close (with a short
// shutdown deadline) when the process exits.
func Init(ctx context.Context, store *config.Store, logger *slog.Logger) (*Client, error) {
	if logger == nil {
		logger = slog.Default()
	}

	disabled := os.Getenv("OFE_TELEMETRY") == "0"
	if !disabled && store != nil {
		if !store.Snapshot().Telemetry {
			disabled = true
		}
	}
	if buildinfo.AppInsightsConnString == "" {
		disabled = true
	}

	if disabled {
		c := New(Options{
			AppVersion: buildinfo.Version,
			Sink:       NoopSink{},
			Logger:     logger,
		})
		// No Start: NoopSink doesn't need a flusher.
		return c, nil
	}

	installID, err := EnsureInstallID(store)
	if err != nil {
		return nil, err
	}

	sink, err := NewAppInsightsSink(AppInsightsOptions{
		ConnectionString: buildinfo.AppInsightsConnString,
		InstallID:        installID,
		AppVersion:       buildinfo.Version,
	})
	if err != nil {
		return nil, err
	}

	client := New(Options{
		AppVersion: buildinfo.Version,
		InstallID:  installID,
		Sink:       sink,
		Logger:     logger,
	})
	client.Start(ctx)
	return client, nil
}
