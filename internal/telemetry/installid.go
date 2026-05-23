package telemetry

import (
	"fmt"

	"github.com/google/uuid"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// EnsureInstallID returns the install ID stored in config, generating
// and persisting a UUIDv4 on first use. The generated ID is written to
// disk via store.Save so the next process sees the same value.
func EnsureInstallID(store *config.Store) (string, error) {
	if store == nil {
		return "", fmt.Errorf("telemetry: nil config store")
	}
	if id := store.Snapshot().InstallID; id != "" {
		return id, nil
	}

	newID := uuid.NewString()
	store.Update(func(f *config.File) {
		// Re-check inside the lock to avoid clobbering a value written
		// by a concurrent EnsureInstallID call.
		if f.InstallID == "" {
			f.InstallID = newID
		}
	})

	// Persist whatever ended up in the file (ours or a racer's).
	if err := store.Save(); err != nil {
		return "", fmt.Errorf("telemetry: persist install id: %w", err)
	}
	return store.Snapshot().InstallID, nil
}
