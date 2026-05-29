package engine_test

import (
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/engine"
)

// TestBuildNilStore verifies that a nil Store is rejected immediately
// rather than panicking deep inside a dependency.
func TestBuildNilStore(t *testing.T) {
	_, err := engine.Build(engine.Options{})
	if err == nil {
		t.Fatal("expected error for nil Store, got nil")
	}
}

// TestBuildAndClose verifies that Build assembles a working Components
// bundle and that Close releases the cache without panic. The test uses
// an in-memory Keychain and a sandboxed HOME so it never touches the
// user's real ~/Library.
func TestBuildAndClose(t *testing.T) {
	dir := t.TempDir()
	// Point HOME at the temp dir so config.Load and ResolvePaths resolve
	// into an isolated sandbox, exactly as handler tests do.
	t.Setenv("HOME", dir)

	store, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}

	// Build with an in-memory keychain to avoid real Keychain access.
	comps, err := engine.Build(engine.Options{
		Store:            store,
		KeychainOverride: auth.NewMemoryKeychain(),
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	t.Cleanup(comps.Close)

	if comps.Engine == nil {
		t.Error("Engine is nil")
	}
	if comps.Cache == nil {
		t.Error("Cache is nil")
	}
	if comps.Registry == nil {
		t.Error("Registry is nil")
	}
	if comps.Gates == nil {
		t.Error("Gates is nil")
	}
}
