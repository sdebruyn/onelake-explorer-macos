// Package engine exposes a single wire-up function for the daemon
// process: cache → auth registry → Fabric/OneLake clients → sync.Engine.
// It lives in its own package so unit tests can construct the components
// without booting the full daemon — [daemon.Run] owns signal handling,
// logging setup, telemetry init, and the IPC listener, all of which are
// orthogonal to wiring. [Build] is the only production caller's entry
// point; [Build] is also exercised directly in wire_test.go.
package engine

import (
	"fmt"
	"path/filepath"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// Components holds the fully-wired engine and its dependencies. Callers
// that only need the engine should call [Components.Close] when done;
// callers that also consume Cache, Registry, or Gates (e.g. the daemon's
// IPC handlers) may use those fields directly.
type Components struct {
	Engine   *sync.Engine
	Cache    *cache.Cache
	Registry *auth.Registry
	Gates    *httpgate.Registry
	// Keychain is the per-account secret store used by Registry. Exposed so
	// the daemon's auth.login IPC handler can pass it to LoginInteractive /
	// LoginDeviceCode without opening a second keychain instance.
	Keychain auth.Keychain
}

// Close releases resources owned by the engine. It is safe to call
// multiple times; subsequent calls are no-ops from the cache's
// perspective.
func (c *Components) Close() {
	_ = c.Cache.Close()
}

// Options parameterises [Build]. Callers fill only the fields they need
// to override; zero values are replaced with production defaults.
type Options struct {
	// Store is the loaded config. Required; Build returns an error when nil.
	Store *config.Store
	// KeychainOverride replaces the real macOS Keychain. Intended for tests.
	// When nil, Build calls auth.NewKeychain().
	KeychainOverride auth.Keychain
	// SyncOptions are forwarded verbatim to sync.New. Fields that callers
	// leave at their zero values (Telemetry, Logger, MaxConcurrent*) are
	// handled by sync.New's own defaults.
	SyncOptions sync.Options
}

// Build assembles the shared engine layer: it opens the SQLite cache,
// creates the auth registry, wires the Fabric REST and OneLake DFS
// clients to it, and constructs the sync.Engine. On failure any
// partially-opened resources are closed before the error is returned.
//
// Build always derives and overwrites [sync.Options].Cache, .Fabric,
// .OneLake, .Tenants, and .ScratchDir from the loaded config; callers
// must not set those fields in opts.SyncOptions.
//
// Callers that want additional sync.Options fields (Telemetry, Logger,
// MaxConcurrent*) should set them in opts.SyncOptions before calling.
func Build(opts Options) (*Components, error) {
	if opts.Store == nil {
		return nil, fmt.Errorf("engine.Build: Store is required")
	}
	paths := opts.Store.Paths()
	cfg := opts.Store.Snapshot()

	// Auth keychain: use caller-supplied override or open the real one.
	kc := opts.KeychainOverride
	if kc == nil {
		built, err := auth.NewKeychain()
		if err != nil {
			return nil, fmt.Errorf("open keychain: %w", err)
		}
		kc = built
	}
	// Auth registry. The registry implements [auth.TokenProvider]
	// directly, so the Fabric and OneLake clients can consume it
	// without an adapter.
	registry := auth.NewRegistry(opts.Store, kc, auth.EntraClientID, nil)

	// SQLite metadata cache. cache.Open creates the directory when it
	// does not yet exist; no pre-flight MkdirAll is needed here.
	c, err := cache.Open(cache.Options{
		Root: paths.CacheDir,
		// Cache wants bytes; CacheConfig speaks gigabytes. Convert at
		// the seam so the cache package stays unaware of the GB schema.
		MaxBlobBytes: cfg.Cache.MaxBytes(),
	})
	if err != nil {
		return nil, fmt.Errorf("open cache: %w", err)
	}

	// Per-host request gate. One process-wide registry is shared between
	// the Fabric and OneLake clients so a 429 on either upstream pauses
	// every in-flight retry on that host.
	gates := httpgate.DefaultRegistry()

	// Fabric REST needs a Power BI-audience token; OneLake DFS needs
	// the storage-audience token the registry serves by default.
	fabricClient := fabric.New(fabric.Options{TokenProvider: registry.ScopedProvider(auth.FabricScopes), Registry: gates})
	onelakeClient := onelake.New(onelake.Options{TokenProvider: registry, Registry: gates})

	// Merge caller-supplied sync.Options with the fields we always set:
	// Cache, Fabric, OneLake, Tenants, and ScratchDir. Callers may
	// additionally set Telemetry, Logger, and MaxConcurrent* in
	// opts.SyncOptions without those being overwritten here.
	syncOpts := opts.SyncOptions
	syncOpts.Cache = c
	syncOpts.Fabric = fabricClient
	syncOpts.OneLake = onelakeClient
	syncOpts.Tenants = registry
	// The daemon and the File Provider extension rendezvous on the same
	// partial-download spill files inside the App Group cache dir.
	syncOpts.ScratchDir = filepath.Join(paths.CacheDir, "partials")

	engine, err := sync.New(syncOpts)
	if err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("build sync engine: %w", err)
	}

	return &Components{
		Engine:   engine,
		Cache:    c,
		Registry: registry,
		Gates:    gates,
		Keychain: kc,
	}, nil
}
