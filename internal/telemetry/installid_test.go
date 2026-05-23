package telemetry

import (
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// newTestStore constructs a config.Store rooted at a tempdir without
// touching the user's real ~/Library paths.
func newTestStore(t *testing.T) *config.Store {
	t.Helper()
	dir := t.TempDir()
	// config.Load reads $HOME — point it at a tempdir so the test
	// never touches the real user config.
	t.Setenv("HOME", dir)
	s, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load with tempdir HOME: %v", err)
	}
	return s
}

func TestEnsureInstallID_GeneratesAndPersists(t *testing.T) {
	s := newTestStore(t)
	id, err := EnsureInstallID(s)
	if err != nil {
		t.Fatalf("EnsureInstallID: %v", err)
	}
	if id == "" {
		t.Fatal("install id is empty")
	}
	// Confirm persisted to disk.
	if s.Snapshot().InstallID != id {
		t.Errorf("snapshot install id = %q, want %q", s.Snapshot().InstallID, id)
	}
}

func TestEnsureInstallID_StableAcrossCalls(t *testing.T) {
	s := newTestStore(t)
	id1, err := EnsureInstallID(s)
	if err != nil {
		t.Fatalf("first call: %v", err)
	}
	id2, err := EnsureInstallID(s)
	if err != nil {
		t.Fatalf("second call: %v", err)
	}
	if id1 != id2 {
		t.Errorf("install id changed between calls: %q vs %q", id1, id2)
	}
}

func TestEnsureInstallID_SurvivesReload(t *testing.T) {
	s := newTestStore(t)
	id, err := EnsureInstallID(s)
	if err != nil {
		t.Fatalf("EnsureInstallID: %v", err)
	}
	// Reload from disk and expect the same id.
	s2, err := config.Load()
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got := s2.Snapshot().InstallID; got != id {
		t.Errorf("after reload install id = %q, want %q", got, id)
	}
}

func TestEnsureInstallID_NilStoreErrors(t *testing.T) {
	if _, err := EnsureInstallID(nil); err == nil {
		t.Error("expected error for nil store")
	}
}
