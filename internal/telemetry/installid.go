package telemetry

import (
	"fmt"

	"github.com/google/uuid"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// EnsureInstallID returns the install ID stored in config, generating
// and persisting a UUIDv4 on first use. The generated ID is written to
// disk via UpdateAndSave so the mutate and persist steps are atomic
// within this process (M-1 fix). Two separate OFEM processes (e.g. host
// app + daemon) racing on first run can each generate a UUID; one will
// win the atomic rename and the other's events will carry a short-lived
// ID. That race is acceptable per docs/telemetry.md.
func EnsureInstallID(store *config.Store) (string, error) {
	if store == nil {
		return "", fmt.Errorf("telemetry: nil config store")
	}
	if id := store.Snapshot().InstallID; id != "" {
		return id, nil
	}

	newID := uuid.NewString()
	if err := store.UpdateAndSave(func(f *config.File) {
		if f.InstallID == "" {
			f.InstallID = newID
		}
	}); err != nil {
		return "", fmt.Errorf("telemetry: persist install id: %w", err)
	}
	return store.Snapshot().InstallID, nil
}
