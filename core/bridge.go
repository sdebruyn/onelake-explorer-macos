// File-Provider Extension bridge: thin C-ABI wrappers that let the
// sandboxed .appex (and the host app) drive sync.Engine without spawning
// a subprocess. Every function below returns either a JSON envelope of
// the form {"...":...} on success or {"error":{"code":"...","message":"..."}}
// on failure; envelopes are NUL-terminated UTF-8 and the caller MUST
// release them with ofem_core_string_free.
//
// Lifecycle:
//
//	ofem_core_init(group_container_path)   // call once before anything else
//	ofem_core_list_accounts() / enumerate / item / fetch_contents
//	ofem_core_close()                      // tear everything down (idempotent)
//
// Re-init is a no-op (logged at warn). Any call before init returns the
// notAuthenticated envelope so the Swift side has a single recovery path.
package main

// #include <stdlib.h>
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"log/slog"
	"mime"
	"net"
	"os"
	"path"
	"path/filepath"
	"strings"
	gosync "sync"
	"sync/atomic"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	syncpkg "github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// Deadlines used by the bridge calls. Kept as constants so they can be
// tuned in one place; both are intentionally shorter than the daemon's
// equivalents because the File Provider Extension blocks Finder while a
// call is outstanding and macOS will kill the extension if it stays
// unresponsive for too long.
//
// enumerateDeadline is 10 s deliberately: macOS's total timeout budget
// for a File Provider enumerate call is roughly 30 s, and 10 s leaves
// ample room for the framework to retry and surface a degraded-state icon
// before the OS decides the extension is hung. For deeper folders with
// many children, cursor-based pagination will be added in Phase 2 so no
// single enumerate call needs to fetch an unbounded result set.
const (
	enumerateDeadline = 10 * time.Second
	fetchDeadline     = 60 * time.Second
	writeDeadline     = 60 * time.Second
	deleteDeadline    = 30 * time.Second
)

// Synthetic identifier constants used at the JSON boundary. These mirror
// NSFileProviderItemIdentifier.rootContainer ("NSFileProviderRootContainerItemIdentifier")
// but we use ".rootContainer" here because the C ABI is string-based and
// keeping it human-readable simplifies debugging.
const rootContainerID = ".rootContainer"

// bridge holds the package-level state the C-ABI functions share. It is
// initialised lazily by ofem_core_init and torn down by ofem_core_close.
//
// Concurrency model:
//   - bridgeInitMu serialises ofem_core_init / ofem_core_close against
//     each other (writer path).
//   - bridgeRWMu guards the globals during hot calls: callers take RLock
//     for the duration of a single bridge call; ofem_core_close takes the
//     full Lock so it cannot run while any call is in progress.
//   - bridgeReady is an atomic fast-path so enumerate/fetch can skip
//     the mutex when the bridge is not yet initialised.
var (
	bridgeInitMu gosync.Mutex
	bridgeRWMu   gosync.RWMutex
	bridgeReady  atomic.Bool
	bridgeStore  *config.Store
	bridgeCache  *cache.Cache
	bridgeReg    *auth.Registry
	bridgeEng    bridgeEngine
	bridgeLogger *slog.Logger
)

// bridgeEngine is a tiny interface around the subset of sync.Engine the
// bridge needs, so tests can inject a fake without spinning up a real
// engine + network stack. Production wires *syncpkg.Engine straight in.
type bridgeEngine interface {
	ListWorkspaces(ctx context.Context, alias string) ([]fabric.Workspace, error)
	ListItems(ctx context.Context, alias, workspaceID string) ([]fabric.Item, error)
	Enumerate(ctx context.Context, k cache.Key) ([]cache.Entry, error)
	Open(ctx context.Context, k cache.Key) (io.ReadCloser, error)
	Put(ctx context.Context, k cache.Key, content io.Reader, size int64) error
	Delete(ctx context.Context, k cache.Key) error
	Mkdir(ctx context.Context, k cache.Key) error
}

// ofem_core_init wires the cache, auth registry, and sync engine and
// stashes them on package-level globals so subsequent bridge calls can
// reach them. Re-init is a no-op (logged warn). On failure the function
// returns non-zero and leaves bridgeReady false so every other call
// returns a notAuthenticated envelope.
//
// groupContainerPath: absolute path the Swift side resolved via
// FileManager.containerURL(forSecurityApplicationGroupIdentifier:). If
// empty (""), fall back to config.ResolvePaths() so the daemon and CLI
// can call this function without resolving a Group Container themselves.
//
//export ofem_core_init
func ofem_core_init(groupContainerPath *C.char) C.int { //nolint:revive // C-ABI symbol name
	bridgeInitMu.Lock()
	defer bridgeInitMu.Unlock()

	if bridgeReady.Load() {
		// Re-init is a no-op; surface as a warning so a misbehaving
		// caller is debuggable but don't tear down working state.
		if bridgeLogger != nil {
			bridgeLogger.Warn("ofem_core_init called twice; ignoring")
		}
		return 0
	}

	logger := slog.With(slog.String("component", "bridge"))

	paths, err := resolveBridgePaths(groupContainerPath)
	if err != nil {
		logger.Error("bridge init: resolve paths failed", slog.Any("err", err))
		return 1
	}

	store, err := config.LoadFrom(paths)
	if err != nil {
		logger.Error("bridge init: load config failed", slog.Any("err", err))
		return 2
	}

	if err := os.MkdirAll(paths.CacheDir, 0o700); err != nil {
		logger.Error("bridge init: mkdir cache failed",
			slog.String("dir", paths.CacheDir), slog.Any("err", err))
		return 3
	}
	cfg := store.Snapshot()
	c, err := cache.Open(cache.Options{
		Root:         paths.CacheDir,
		MaxBlobBytes: cfg.Cache.MaxSizeBytes,
	})
	if err != nil {
		logger.Error("bridge init: open cache failed", slog.Any("err", err))
		return 4
	}

	kc, err := auth.NewKeychainAt(filepath.Join(paths.ConfigDir, "tokens"))
	if err != nil {
		_ = c.Close()
		logger.Error("bridge init: open keychain failed", slog.Any("err", err))
		return 5
	}
	registry := auth.NewRegistry(store, kc, auth.EntraClientID, nil)

	gates := httpgate.DefaultRegistry()
	fabricClient := fabric.New(fabric.Options{TokenProvider: registry, Registry: gates})
	onelakeClient := onelake.New(onelake.Options{TokenProvider: registry, Registry: gates})
	eng, err := syncpkg.New(syncpkg.Options{
		Cache:                  c,
		Fabric:                 fabricClient,
		OneLake:                onelakeClient,
		Tenants:                registry,
		Logger:                 logger,
		MaxConcurrentUploads:   cfg.Net.MaxConcurrentUploadsPerAccount,
		MaxConcurrentDownloads: cfg.Net.MaxConcurrentDownloadsPerAccount,
	})
	if err != nil {
		_ = c.Close()
		logger.Error("bridge init: build sync engine failed", slog.Any("err", err))
		return 6
	}

	bridgeStore = store
	bridgeCache = c
	bridgeReg = registry
	bridgeEng = eng
	bridgeLogger = logger
	bridgeReady.Store(true)

	logger.Info("bridge init complete",
		slog.String("version", buildinfo.Version),
		slog.String("config_dir", paths.ConfigDir))
	return 0
}

// resolveBridgePaths picks the App Group container from the Swift side
// when non-empty, otherwise falls back to config.ResolvePaths so the
// daemon and CLI can reuse this code path. The Swift-provided value wins
// because the .appex is sandboxed and cannot always resolve the
// container itself via os.UserHomeDir().
func resolveBridgePaths(groupContainerPath *C.char) (config.Paths, error) {
	provided := goString(groupContainerPath)
	if provided == "" {
		return config.ResolvePaths()
	}
	// Build a Paths from the Swift-provided root. We deliberately mirror
	// the layout that config.ResolvePaths produces so the daemon (which
	// uses ResolvePaths) and the .appex (which uses the value Swift
	// hands us) share the same files on disk.
	return config.Paths{
		ConfigDir:  provided,
		ConfigFile: filepath.Join(provided, "config.toml"),
		CacheDir:   filepath.Join(provided, "cache"),
		LogDir:     filepath.Join(provided, "log"),
		SocketPath: filepath.Join(provided, "ofem.sock"),
	}, nil
}

// ofem_core_close releases the cache handle and clears the package
// globals. Safe to call multiple times; safe to call without a prior
// successful init.
//
// This function acquires bridgeRWMu.Lock() which blocks until all
// in-flight enumerate / fetch calls (which hold RLock) finish. The
// Swift side must not call ofem_core_close while intentionally keeping
// other calls running; the guarantee is: once the last call returns,
// tearing down is safe.
//
//export ofem_core_close
func ofem_core_close() { //nolint:revive // C-ABI symbol name
	bridgeInitMu.Lock()
	defer bridgeInitMu.Unlock()
	if !bridgeReady.Load() {
		return
	}
	// Wait for all in-flight callers to finish before clearing globals.
	bridgeRWMu.Lock()
	defer bridgeRWMu.Unlock()
	if bridgeCache != nil {
		if err := bridgeCache.Close(); err != nil && bridgeLogger != nil {
			bridgeLogger.Warn("bridge close: cache close error", slog.Any("err", err))
		}
	}
	bridgeStore = nil
	bridgeCache = nil
	bridgeReg = nil
	bridgeEng = nil
	bridgeReady.Store(false)
	if bridgeLogger != nil {
		bridgeLogger.Info("bridge closed")
	}
}

// ofem_core_list_accounts returns the registered accounts as JSON. The
// envelope is always {"accounts":[...]}; an empty registry returns an
// empty array, not an error. The function never returns an error
// envelope on logical conditions.
//
//export ofem_core_list_accounts
func ofem_core_list_accounts() *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return marshalAccountsEnvelope(nil)
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()
	if !bridgeReady.Load() {
		return marshalAccountsEnvelope(nil)
	}
	accounts := bridgeReg.List()
	out := make([]bridgeAccount, 0, len(accounts))
	for _, a := range accounts {
		out = append(out, bridgeAccount{
			Alias:      a.Alias,
			Username:   a.Username,
			TenantID:   a.TenantID,
			TenantName: a.TenantName,
		})
	}
	return marshalAccountsEnvelope(out)
}

// marshalAccountsEnvelope emits {"accounts":[...]} unconditionally,
// even when the slice is empty. The default envelope marshaller treats
// empty slices as omitempty so it would emit "{}" which the Swift side
// would have to special-case — easier to keep the wire shape consistent
// here.
func marshalAccountsEnvelope(accounts []bridgeAccount) *C.char {
	if accounts == nil {
		accounts = []bridgeAccount{}
	}
	type wireAccountsEnvelope struct {
		Accounts []bridgeAccount `json:"accounts"`
	}
	data, err := json.Marshal(wireAccountsEnvelope{Accounts: accounts})
	if err != nil {
		return C.CString(`{"accounts":[]}`)
	}
	return C.CString(string(data))
}

// ofem_core_enumerate returns the children of a logical container.
//
//   - "" or ".rootContainer" -> list workspaces for alias.
//   - "<wsId>"               -> list items in workspace.
//   - "<wsId>/<itemId>"      -> list root contents of item.
//   - "<wsId>/<itemId>/<p>"  -> list contents of <p> inside item.
//
// The call has a 10-second deadline so an unresponsive backend never
// blocks Finder beyond what macOS tolerates from a File Provider
// Extension.
//
//export ofem_core_enumerate
func ofem_core_enumerate(alias, identifier *C.char) *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()
	// Re-check after acquiring the read lock; ofem_core_close could have
	// run between the atomic load and the RLock().
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	a := goString(alias)
	id := goString(identifier)

	ctx, cancel := context.WithTimeout(context.Background(), enumerateDeadline)
	defer cancel()

	scope, perr := parseIdentifier(id)
	if perr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(perr)})
	}

	items, err := enumerateScope(ctx, bridgeEng, a, scope)
	if err != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(err)})
	}
	return marshalEnvelope(envelope{Items: items})
}

// ofem_core_item returns the synthetic NSFileProviderItem for one
// identifier. For the root and workspace levels we synthesise from cache
// rows the engine wrote during prior enumerations; we deliberately do
// NOT issue a remote call here because Finder calls itemForIdentifier:
// extremely frequently and one HEAD per call would melt the backend.
//
//export ofem_core_item
func ofem_core_item(alias, identifier *C.char) *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	a := goString(alias)
	id := goString(identifier)

	ctx, cancel := context.WithTimeout(context.Background(), enumerateDeadline)
	defer cancel()

	scope, perr := parseIdentifier(id)
	if perr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(perr)})
	}

	item, err := itemForScope(ctx, a, scope)
	if err != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(err)})
	}
	return marshalEnvelope(envelope{Item: item})
}

// ofem_core_fetch_contents streams the file at identifier into destPath.
// Identifier must point at a file (i.e. it must include a /<itemId>/<path>
// suffix with a non-empty path). The function writes the file in
// streaming mode so the full content never sits in memory.
//
//export ofem_core_fetch_contents
func ofem_core_fetch_contents(alias, identifier, destPath *C.char) *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	a := goString(alias)
	id := goString(identifier)
	dest := goString(destPath)

	if dest == "" {
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code: "cannotSynchronize", Message: "destination path is empty",
		}})
	}

	scope, perr := parseIdentifier(id)
	if perr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(perr)})
	}
	if scope.kind != scopePath {
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code: "noSuchItem", Message: "fetch_contents requires a file identifier",
		}})
	}

	ctx, cancel := context.WithTimeout(context.Background(), fetchDeadline)
	defer cancel()

	key := cache.Key{
		AccountAlias: a,
		WorkspaceID:  scope.workspace,
		ItemID:       scope.item,
		Path:         scope.path,
	}
	rc, err := bridgeEng.Open(ctx, key)
	if err != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(err)})
	}
	defer func() { _ = rc.Close() }()

	// Stream directly into destPath. We rely on Swift to have prepared the
	// directory; we just write the file with 0600 because the .appex
	// sandbox confines the path anyway.
	f, ferr := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if ferr != nil {
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code: "cannotSynchronize", Message: ferr.Error(),
		}})
	}
	if _, cerr := io.Copy(f, rc); cerr != nil {
		_ = f.Close()
		_ = os.Remove(dest)
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code: "cannotSynchronize", Message: cerr.Error(),
		}})
	}
	if cerr := f.Close(); cerr != nil {
		// Close failure (e.g. ENOSPC during fsync) means the file was not
		// fully flushed. Remove the partial file so Finder never picks it
		// up as a "successful" partial download.
		_ = os.Remove(dest)
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code: "cannotSynchronize", Message: cerr.Error(),
		}})
	}

	// Build the post-fetch item from the cache row sync.Open just
	// populated. If the cache lookup fails we still return success with
	// a minimal item — the file is on disk, Finder can use it; the
	// metadata is "best effort" past this point.
	entry, gerr := bridgeCache.Get(ctx, key)
	var item bridgeItem
	if gerr == nil {
		item = entryToItem(a, entry)
	} else {
		// Synthesise something sane so contentVersion is at least stable.
		item = bridgeItem{
			Identifier:       buildPathID(scope.workspace, scope.item, scope.path),
			ParentIdentifier: buildPathParentID(scope.workspace, scope.item, scope.path),
			Filename:         path.Base(scope.path),
			IsDir:            false,
			ContentVersion:   fallbackVersion(scope.path, 0, time.Time{}),
			MetadataVersion:  fallbackVersion(scope.path, 0, time.Time{}),
			Capabilities:     []string{"read"},
		}
	}
	return marshalEnvelope(envelope{Item: &item})
}

// bridgeCreateItem is the shared implementation for ofem_core_create_item
// and the test shim. Using a single function body guarantees the macOS
// metadata short-circuit (including the isDir field) is tested through
// the same code path that runs in production.
//
// Callers must hold bridgeRWMu.RLock for the duration.
func bridgeCreateItem(alias, parentID, name string, isDir bool, srcPath string) (string, error) {
	parentScope, perr := parseIdentifier(parentID)
	if perr != nil {
		return "", perr
	}
	if parentScope.kind != scopeItem && parentScope.kind != scopePath {
		return "", &errorPayload{Code: "noSuchItem", Message: "create_item requires a parent inside a Fabric item"}
	}

	// Derive the new item's path by joining the parent path (may be empty
	// if the parent is the item root) with the filename.
	newPath := name
	if parentScope.path != "" {
		newPath = parentScope.path + "/" + name
	}
	ws := parentScope.workspace
	item := parentScope.item

	// macOS metadata short-circuit: accept but do not touch the engine.
	// Use the actual isDir parameter so a file-shaped request (isDir=false)
	// gets file capabilities even when it hits the metadata short-circuit.
	if syncpkg.IsMacOSMetadata(newPath) {
		synthetic := syntheticItem(ws, item, newPath, parentID, name, isDir)
		data, err := json.Marshal(envelope{Item: &synthetic})
		if err != nil {
			return "", err
		}
		return string(data), nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), writeDeadline)
	defer cancel()

	key := cache.Key{
		AccountAlias: alias,
		WorkspaceID:  ws,
		ItemID:       item,
		Path:         newPath,
	}

	if isDir {
		if err := bridgeEng.Mkdir(ctx, key); err != nil {
			return "", err
		}
		synthetic := syntheticItem(ws, item, newPath, parentID, name, true)
		data, err := json.Marshal(envelope{Item: &synthetic})
		if err != nil {
			return "", err
		}
		return string(data), nil
	}

	// File upload: open the source, stat for size, then put.
	f, ferr := os.Open(srcPath)
	if ferr != nil {
		return "", ferr
	}
	defer func() { _ = f.Close() }()

	fi, serr := f.Stat()
	if serr != nil {
		return "", serr
	}
	size := fi.Size()

	if err := bridgeEng.Put(ctx, key, f, size); err != nil {
		return "", err
	}

	// Attempt a cache lookup for the freshly uploaded file so the returned
	// item carries the server-assigned etag/mtime. Fall back to synthetic
	// if the cache row isn't there yet.
	entry, gerr := bridgeCache.Get(ctx, key)
	if gerr == nil {
		it := entryToItem(alias, entry)
		data, err := json.Marshal(envelope{Item: &it})
		if err != nil {
			return "", err
		}
		return string(data), nil
	}
	synthetic := syntheticItem(ws, item, newPath, parentID, name, false)
	synthetic.Size = size
	data, err := json.Marshal(envelope{Item: &synthetic})
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// ofem_core_create_item uploads a new file or creates a new directory.
//
// parentIdentifier is "<wsId>/<itemId>[/<parentPath>]". filename is the
// leaf name. isDir must be 1 to create a directory (srcPath ignored), or
// 0 to upload the file at srcPath.
//
// macOS metadata files (matching sync.IsMacOSMetadata) are accepted
// without contacting the engine: a synthetic item is returned immediately
// so Finder treats the write as successful while the lake stays clean.
//
//export ofem_core_create_item
func ofem_core_create_item(alias, parentIdentifier, filename *C.char, isDir C.int, srcPath *C.char) *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()

	a := goString(alias)
	parentID := goString(parentIdentifier)
	name := goString(filename)
	dir := isDir != 0
	src := goString(srcPath)

	result, err := bridgeCreateItem(a, parentID, name, dir, src)
	if err != nil {
		var ep *errorPayload
		if errors.As(err, &ep) {
			return marshalEnvelope(envelope{Error: ep})
		}
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(err)})
	}
	return C.CString(result)
}

// ofem_core_modify_item replaces the content of an existing file.
//
// identifier must be "<wsId>/<itemId>/<path>". srcPath is the local
// file with new content. Engine.Put applies last-write-wins semantics
// and handles the macOS-metadata filter internally.
//
//export ofem_core_modify_item
func ofem_core_modify_item(alias, identifier, srcPath *C.char) *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()

	a := goString(alias)
	id := goString(identifier)
	src := goString(srcPath)

	sc, perr := parseIdentifier(id)
	if perr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(perr)})
	}
	if sc.kind != scopePath {
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code:    "noSuchItem",
			Message: "modify_item requires a file identifier",
		}})
	}

	f, ferr := os.Open(src)
	if ferr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(ferr)})
	}
	defer func() { _ = f.Close() }()

	fi, serr := f.Stat()
	if serr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(serr)})
	}
	size := fi.Size()

	ctx, cancel := context.WithTimeout(context.Background(), writeDeadline)
	defer cancel()

	key := cache.Key{
		AccountAlias: a,
		WorkspaceID:  sc.workspace,
		ItemID:       sc.item,
		Path:         sc.path,
	}
	if err := bridgeEng.Put(ctx, key, f, size); err != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(err)})
	}

	entry, gerr := bridgeCache.Get(ctx, key)
	if gerr == nil {
		it := entryToItem(a, entry)
		return marshalEnvelope(envelope{Item: &it})
	}
	parentID := buildPathParentID(sc.workspace, sc.item, sc.path)
	synthetic := syntheticItem(sc.workspace, sc.item, sc.path, parentID, path.Base(sc.path), false)
	synthetic.Size = size
	return marshalEnvelope(envelope{Item: &synthetic})
}

// ofem_core_delete_item removes a file or directory from OneLake.
//
// identifier must be a scopePath identifier: "<wsId>/<itemId>/<path>".
// Workspace-level ("<wsId>"), item-root ("<wsId>/<itemId>"), and the
// root container are NOT valid targets — deleting an entire Fabric
// workspace or item via the bridge is intentionally unsupported and
// returns noSuchItem. macOS metadata paths (e.g. ".DS_Store") are
// accepted without contacting the engine (success immediately). On
// success the function returns "{}"; errors are {"error":{...}}.
//
//export ofem_core_delete_item
func ofem_core_delete_item(alias, identifier *C.char) *C.char { //nolint:revive // C-ABI symbol name
	if !bridgeReady.Load() {
		return notReadyEnvelope()
	}
	bridgeRWMu.RLock()
	defer bridgeRWMu.RUnlock()

	a := goString(alias)
	id := goString(identifier)

	sc, perr := parseIdentifier(id)
	if perr != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(perr)})
	}
	// Only scopePath is valid: workspace-level and item-root deletions
	// are not supported via this bridge (would delete entire OneLake
	// items or workspaces). Returning noSuchItem causes macOS to stop
	// retrying rather than treating it as a transient failure.
	if sc.kind != scopePath {
		return marshalEnvelope(envelope{Error: &errorPayload{
			Code:    "noSuchItem",
			Message: "delete_item only supports path-scoped identifiers (workspace/item/path); cannot delete workspace or item roots",
		}})
	}

	// macOS metadata: Engine.Delete already handles this, but for
	// consistency we short-circuit here too so no engine call is made.
	if syncpkg.IsMacOSMetadata(sc.path) {
		return C.CString("{}")
	}

	ctx, cancel := context.WithTimeout(context.Background(), deleteDeadline)
	defer cancel()

	key := cache.Key{
		AccountAlias: a,
		WorkspaceID:  sc.workspace,
		ItemID:       sc.item,
		Path:         sc.path,
	}
	if err := bridgeEng.Delete(ctx, key); err != nil {
		return marshalEnvelope(envelope{Error: errorPayloadFromGo(err)})
	}
	return C.CString("{}")
}

// syntheticItem builds a bridgeItem for paths where no cache row is
// available (e.g. after mkdir, or after upload when the HEAD hasn't
// landed yet). Versions are deterministic so Finder gets stable
// identity without a remote round-trip.
func syntheticItem(ws, item, newPath, parentID, name string, isDir bool) bridgeItem {
	caps := []string{"read", "write", "delete"}
	if isDir {
		caps = []string{"read", "write", "delete", "enumerate", "add_subitems"}
	}
	return bridgeItem{
		Identifier:       buildPathID(ws, item, newPath),
		ParentIdentifier: parentID,
		Filename:         name,
		IsDir:            isDir,
		ContentVersion:   fallbackVersion(newPath, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(newPath, 0, time.Time{}),
		Capabilities:     caps,
	}
}

// --- identifier parsing -----------------------------------------------------

// scopeKind tags a parsed identifier so callers can switch on intent
// rather than inspecting which fields are populated.
type scopeKind int

const (
	scopeRoot      scopeKind = iota // "" / ".rootContainer" -> list workspaces
	scopeWorkspace                  // "<wsId>"              -> list items
	scopeItem                       // "<wsId>/<itemId>"     -> item root
	scopePath                       // "<wsId>/<itemId>/<p>" -> item subpath
)

// scope is the parsed identifier returned by parseIdentifier. The fields
// not relevant to the kind are left zero.
type scope struct {
	kind      scopeKind
	workspace string
	item      string
	path      string
}

// parseIdentifier splits the C-ABI identifier into its components. We
// keep the grammar deliberately strict: any identifier that contains an
// empty segment (double slash, leading slash, or trailing slash that
// produces an empty item/workspace field) is rejected with an error so
// the caller sees noSuchItem rather than a Fabric call with an empty ID.
//
// Valid forms:
//
//	""                  -> scopeRoot
//	".rootContainer"    -> scopeRoot
//	"<ws>"              -> scopeWorkspace  (non-empty)
//	"<ws>/<item>"       -> scopeItem       (both non-empty)
//	"<ws>/<item>/<p>"   -> scopePath       (ws, item non-empty; p may be empty for item root)
func parseIdentifier(id string) (scope, error) {
	switch id {
	case "", rootContainerID:
		return scope{kind: scopeRoot}, nil
	}
	// Reject leading slash — would produce an empty workspace segment.
	if strings.HasPrefix(id, "/") {
		return scope{}, fmt.Errorf("invalid identifier %q: leading slash", id)
	}
	parts := strings.SplitN(id, "/", 3)
	switch len(parts) {
	case 1:
		if parts[0] == "" {
			return scope{}, fmt.Errorf("invalid identifier %q: empty workspace", id)
		}
		return scope{kind: scopeWorkspace, workspace: parts[0]}, nil
	case 2:
		if parts[0] == "" || parts[1] == "" {
			return scope{}, fmt.Errorf("invalid identifier %q: empty workspace or item segment", id)
		}
		return scope{kind: scopeItem, workspace: parts[0], item: parts[1]}, nil
	case 3:
		if parts[0] == "" || parts[1] == "" {
			return scope{}, fmt.Errorf("invalid identifier %q: empty workspace or item segment", id)
		}
		return scope{
			kind:      scopePath,
			workspace: parts[0],
			item:      parts[1],
			path:      strings.TrimSuffix(parts[2], "/"),
		}, nil
	}
	// SplitN(_, "/", 3) returns at most 3 parts; the fallthrough is
	// defensive against future grammar changes.
	return scope{}, fmt.Errorf("invalid identifier %q", id)
}

// --- enumeration ------------------------------------------------------------

// enumerateScope dispatches the parsed identifier to the right engine
// method and converts the result to []bridgeItem. Errors are wrapped at
// the boundary so callers can call errorPayloadFromGo on them uniformly.
func enumerateScope(ctx context.Context, eng bridgeEngine, alias string, sc scope) ([]bridgeItem, error) {
	switch sc.kind {
	case scopeRoot:
		ws, err := eng.ListWorkspaces(ctx, alias)
		if err != nil {
			return nil, err
		}
		out := make([]bridgeItem, 0, len(ws))
		for _, w := range ws {
			out = append(out, workspaceToItem(w))
		}
		return out, nil
	case scopeWorkspace:
		items, err := eng.ListItems(ctx, alias, sc.workspace)
		if err != nil {
			return nil, err
		}
		out := make([]bridgeItem, 0, len(items))
		for _, it := range items {
			out = append(out, itemToBridgeItem(it))
		}
		return out, nil
	case scopeItem, scopePath:
		k := cache.Key{
			AccountAlias: alias,
			WorkspaceID:  sc.workspace,
			ItemID:       sc.item,
			Path:         sc.path,
		}
		entries, err := eng.Enumerate(ctx, k)
		if err != nil {
			return nil, err
		}
		out := make([]bridgeItem, 0, len(entries))
		for _, e := range entries {
			out = append(out, entryToItem(alias, e))
		}
		return out, nil
	}
	return nil, fmt.Errorf("unknown scope kind %v", sc.kind)
}

// itemForScope builds the synthetic NSFileProviderItem for one identifier
// without making remote calls. The cache is consulted opportunistically;
// when it is empty (the very first probe before any enumerate landed) we
// fall back to a minimal stub.
func itemForScope(ctx context.Context, alias string, sc scope) (*bridgeItem, error) {
	switch sc.kind {
	case scopeRoot:
		item := bridgeItem{
			Identifier:      rootContainerID,
			Filename:        "OneLake — " + alias,
			IsDir:           true,
			ContentVersion:  fallbackVersion(alias, 0, time.Time{}),
			MetadataVersion: fallbackVersion(alias, 0, time.Time{}),
			Capabilities:    []string{"read", "enumerate"},
		}
		return &item, nil
	case scopeWorkspace:
		// Lookup the synthetic workspace row sync.ListWorkspaces wrote.
		k := cache.Key{
			AccountAlias: alias,
			WorkspaceID:  syncpkg.VirtualWorkspaceID,
			ItemID:       syncpkg.VirtualWorkspaceID,
			Path:         sc.workspace,
		}
		entry, err := bridgeCache.Get(ctx, k)
		if err == nil {
			it := bridgeItem{
				Identifier:       sc.workspace,
				ParentIdentifier: rootContainerID,
				Filename:         entry.Name,
				IsDir:            true,
				ModificationDate: rfc3339OrEmpty(entry.LastModified),
				ContentVersion:   fallbackVersion(entry.Name, 0, entry.SyncedAt),
				MetadataVersion:  fallbackVersion(entry.Name, 0, entry.SyncedAt),
				Capabilities:     []string{"read", "enumerate"},
			}
			return &it, nil
		}
		// Cache miss: stub it so Finder doesn't see noSuchItem before the
		// first enumerate completes.
		return &bridgeItem{
			Identifier:       sc.workspace,
			ParentIdentifier: rootContainerID,
			Filename:         sc.workspace,
			IsDir:            true,
			ContentVersion:   fallbackVersion(sc.workspace, 0, time.Time{}),
			MetadataVersion:  fallbackVersion(sc.workspace, 0, time.Time{}),
			Capabilities:     []string{"read", "enumerate"},
		}, nil
	case scopeItem:
		// Items live under the workspace's virtual row written by sync.ListItems.
		k := cache.Key{
			AccountAlias: alias,
			WorkspaceID:  sc.workspace,
			ItemID:       syncpkg.VirtualItemID,
			Path:         sc.item,
		}
		entry, err := bridgeCache.Get(ctx, k)
		if err == nil {
			it := bridgeItem{
				Identifier:       sc.workspace + "/" + sc.item,
				ParentIdentifier: sc.workspace,
				Filename:         entry.Name,
				IsDir:            true,
				ModificationDate: rfc3339OrEmpty(entry.LastModified),
				ContentVersion:   fallbackVersion(entry.Name, 0, entry.SyncedAt),
				MetadataVersion:  fallbackVersion(entry.Name, 0, entry.SyncedAt),
				Capabilities:     []string{"read", "enumerate"},
			}
			return &it, nil
		}
		return &bridgeItem{
			Identifier:       sc.workspace + "/" + sc.item,
			ParentIdentifier: sc.workspace,
			Filename:         sc.item,
			IsDir:            true,
			ContentVersion:   fallbackVersion(sc.item, 0, time.Time{}),
			MetadataVersion:  fallbackVersion(sc.item, 0, time.Time{}),
			Capabilities:     []string{"read", "enumerate"},
		}, nil
	case scopePath:
		k := cache.Key{
			AccountAlias: alias,
			WorkspaceID:  sc.workspace,
			ItemID:       sc.item,
			Path:         sc.path,
		}
		entry, err := bridgeCache.Get(ctx, k)
		if err != nil {
			return nil, err
		}
		it := entryToItem(alias, entry)
		return &it, nil
	}
	return nil, fmt.Errorf("unknown scope kind %v", sc.kind)
}

// --- JSON envelope shapes ---------------------------------------------------

// envelope is the wire shape every bridge function marshals. Exactly one
// of the populated fields is set per call; omitempty keeps the JSON
// readable on the Swift side.
type envelope struct {
	Accounts []bridgeAccount `json:"accounts,omitempty"`
	Items    []bridgeItem    `json:"items,omitempty"`
	Item     *bridgeItem     `json:"item,omitempty"`
	Error    *errorPayload   `json:"error,omitempty"`
}

// bridgeAccount is what list_accounts returns per row. Username is
// display-only; we deliberately do not include the home_account_id
// because the Swift side never needs it.
//
// No omitempty: the Swift Account struct decodes these as non-optional
// strings, so an account with (say) an empty tenantName must still emit
// the key as "". Dropping the field would fail Swift's JSONDecoder with
// "data missing".
type bridgeAccount struct {
	Alias      string `json:"alias"`
	Username   string `json:"username"`
	TenantID   string `json:"tenantId"`
	TenantName string `json:"tenantName"`
}

// bridgeItem is the JSON shape Swift turns into an NSFileProviderItem.
// Field order mirrors the doc comment on the C-ABI surface so it is
// trivial to diff this struct against the spec.
type bridgeItem struct {
	Identifier       string   `json:"identifier"`
	ParentIdentifier string   `json:"parentIdentifier,omitempty"`
	Filename         string   `json:"filename"`
	IsDir            bool     `json:"isDir"`
	Size             int64    `json:"size,omitempty"`
	ContentType      string   `json:"contentType,omitempty"`
	ModificationDate string   `json:"modificationDate,omitempty"`
	ContentVersion   string   `json:"contentVersion"`
	MetadataVersion  string   `json:"metadataVersion"`
	Capabilities     []string `json:"capabilities"`
}

// errorPayload is the {"error": ...} envelope's value. Code is one of a
// fixed set so Swift can switch on it without parsing the message; the
// message is the unfiltered Go error string and is intended for logs,
// not for end-user display.
type errorPayload struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Error implements the error interface so *errorPayload can be returned
// from internal helpers that signal both Go errors and bridge error codes.
func (e *errorPayload) Error() string { return e.Code + ": " + e.Message }

// --- adapters: fabric/cache rows -> bridgeItem ------------------------------

// workspaceToItem maps a fabric.Workspace into the wire shape. We use the
// workspace ID as the identifier because workspace names are not unique
// across tenants and can be renamed.
func workspaceToItem(w fabric.Workspace) bridgeItem {
	return bridgeItem{
		Identifier:       w.ID,
		ParentIdentifier: rootContainerID,
		Filename:         w.DisplayName,
		IsDir:            true,
		ContentVersion:   fallbackVersion(w.ID, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(w.DisplayName, 0, time.Time{}),
		Capabilities:     []string{"read", "enumerate"},
	}
}

// itemToBridgeItem maps a fabric.Item (Lakehouse, Warehouse, …) into the
// wire shape. Same naming caveat as workspaceToItem.
func itemToBridgeItem(it fabric.Item) bridgeItem {
	return bridgeItem{
		Identifier:       it.WorkspaceID + "/" + it.ID,
		ParentIdentifier: it.WorkspaceID,
		Filename:         it.DisplayName,
		IsDir:            true,
		ContentVersion:   fallbackVersion(it.ID, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(it.DisplayName, 0, time.Time{}),
		Capabilities:     []string{"read", "enumerate"},
	}
}

// entryToItem maps a cache.Entry into the wire shape. The cache row
// holds everything we need: name, size, mtime, etag, content type. We
// route the contentVersion through the etag when present and fall back
// to a deterministic hash of (size, mtime) when it is not — Finder
// dedups identical contentVersions, so a stable value matters more than
// a "correct" one.
func entryToItem(alias string, e cache.Entry) bridgeItem {
	identifier := buildPathID(e.WorkspaceID, e.ItemID, e.Path)
	parent := buildPathParentID(e.WorkspaceID, e.ItemID, e.Path)

	ct := e.ContentType
	if ct == "" && !e.IsDir {
		ct = mime.TypeByExtension(path.Ext(e.Path))
	}

	caps := []string{"read", "write", "delete"}
	if e.IsDir {
		caps = []string{"read", "write", "delete", "enumerate", "add_subitems"}
	}

	return bridgeItem{
		Identifier:       identifier,
		ParentIdentifier: parent,
		Filename:         e.Name,
		IsDir:            e.IsDir,
		Size:             e.ContentLength,
		ContentType:      ct,
		ModificationDate: rfc3339OrEmpty(e.LastModified),
		ContentVersion:   contentVersionFor(e),
		MetadataVersion:  metadataVersionFor(e),
		Capabilities:     caps,
	}
}

// buildPathID assembles the identifier for an entry at <ws>/<item>/<path>.
// An empty path collapses to "<ws>/<item>" because Finder calls
// itemForIdentifier on that form and it must round-trip through
// parseIdentifier without changing meaning.
func buildPathID(ws, item, p string) string {
	if p == "" {
		return ws + "/" + item
	}
	return ws + "/" + item + "/" + p
}

// buildPathParentID derives the parent identifier from a (ws, item, path)
// triple. The rules:
//   - root-of-item (path == "")  -> "<ws>"
//   - depth-1 (no "/" in path)   -> "<ws>/<item>"
//   - deeper                     -> "<ws>/<item>/<dirname>"
func buildPathParentID(ws, item, p string) string {
	if p == "" {
		return ws
	}
	idx := strings.LastIndex(p, "/")
	if idx < 0 {
		return ws + "/" + item
	}
	return ws + "/" + item + "/" + p[:idx]
}

// contentVersionFor returns the per-content opaque version Finder uses
// to decide whether to re-fetch a file. We prefer the OneLake/ADLS etag
// (it changes on every byte change) and fall back to a stable hash of
// (mtime, size) when no etag is present yet — empty contentVersion
// would tell Finder "always stale" and trigger constant refetches.
func contentVersionFor(e cache.Entry) string {
	if e.Etag != "" {
		return base64.StdEncoding.EncodeToString([]byte(e.Etag))
	}
	return fallbackVersion(e.Path, e.ContentLength, e.LastModified)
}

// metadataVersionFor returns a hash of the metadata fields macOS treats
// as "shape" attributes (name, size, mtime, etag). It changes whenever
// the file is renamed or its modification timestamp shifts even though
// the bytes stayed the same.
func metadataVersionFor(e cache.Entry) string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(e.Name))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(e.Etag))
	_, _ = h.Write([]byte{0})
	_, _ = fmt.Fprintf(h, "%d", e.ContentLength)
	_, _ = h.Write([]byte{0})
	if !e.LastModified.IsZero() {
		_, _ = h.Write([]byte(e.LastModified.UTC().Format(time.RFC3339Nano)))
	}
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// fallbackVersion produces a non-empty deterministic version string when
// no etag is known. The seed combines path, size, and modification time;
// a fixed seed avoids cross-process variance. Encoded as base64 to keep
// the field tolerant of every Unicode byte the inputs might contain.
func fallbackVersion(seed string, size int64, mtime time.Time) string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	_, _ = h.Write([]byte{0})
	_, _ = fmt.Fprintf(h, "%d", size)
	_, _ = h.Write([]byte{0})
	if !mtime.IsZero() {
		_, _ = h.Write([]byte(mtime.UTC().Format(time.RFC3339Nano)))
	}
	raw := h.Sum(nil)
	return base64.StdEncoding.EncodeToString(raw)
}

// rfc3339OrEmpty formats t in RFC 3339 UTC, or returns "" for the zero
// time. The empty form makes the field's `omitempty` JSON tag work.
func rfc3339OrEmpty(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// --- error mapping ----------------------------------------------------------

// errorPayloadFromGo converts a Go error into the {code,message} envelope
// the Swift side switches on. The mapping mirrors NSFileProviderError
// codes loosely: noSuchItem for missing rows, notAuthenticated for 401
// and 403, serverBusy for 429 and paused capacity, serverUnreachable
// for offline / dial errors, cannotSynchronize for everything else.
func errorPayloadFromGo(err error) *errorPayload {
	if err == nil {
		return nil
	}
	code := classifyError(err)
	return &errorPayload{Code: code, Message: err.Error()}
}

// classifyError implements the error -> code mapping. Sentinel checks
// come first because they are cheap and unambiguous; string-based
// fallbacks come last so a server that adds a new sentinel later does
// not get silently miscategorised.
func classifyError(err error) string {
	switch {
	case errors.Is(err, os.ErrNotExist),
		errors.Is(err, httpretry.ErrNotFound),
		errors.Is(err, httpretry.ErrGone):
		return "noSuchItem"
	case errors.Is(err, syncpkg.ErrLastWriteWinsExhausted):
		return "cannotSynchronize"
	case errors.Is(err, syncpkg.ErrWorkspacePaused),
		errors.Is(err, httpretry.ErrThrottled),
		syncpkg.IsPausedCapacityError(err):
		return "serverBusy"
	case errors.Is(err, httpretry.ErrUnauthorized),
		errors.Is(err, httpretry.ErrForbidden):
		return "notAuthenticated"
	case syncpkg.IsOfflineError(err):
		return "serverUnreachable"
	}
	// Net.Error fallback: handles dial timeouts that don't surface as a
	// sentinel above.
	var nerr net.Error
	if errors.As(err, &nerr) {
		return "serverUnreachable"
	}
	// Last resort: pattern-match the message for HTTP status codes the
	// underlying client may have stringified before we wrapped it.
	msg := err.Error()
	switch {
	case strings.Contains(msg, "401"), strings.Contains(msg, "403"):
		return "notAuthenticated"
	case strings.Contains(msg, "404"):
		return "noSuchItem"
	case strings.Contains(msg, "429"):
		return "serverBusy"
	}
	return "cannotSynchronize"
}

// notReadyEnvelope is the JSON Swift gets back when a call lands before
// ofem_core_init succeeded. notAuthenticated is the closest
// NSFileProviderError code: the .appex's standard response is to surface
// the host app's sign-in flow, which is exactly what we want here.
func notReadyEnvelope() *C.char {
	return marshalEnvelope(envelope{Error: &errorPayload{
		Code:    "notAuthenticated",
		Message: "bridge not initialised",
	}})
}

// --- helpers ----------------------------------------------------------------

// goString converts a *C.char into a Go string, returning "" for NULL so
// the rest of the code can treat empty and NULL identically. C.GoString
// already does that; the helper exists so the call sites read as "this
// is a string from the C boundary".
func goString(p *C.char) string {
	if p == nil {
		return ""
	}
	return C.GoString(p)
}

// marshalEnvelope renders e as a C string. JSON marshaling cannot fail
// here because the struct has no map or interface fields the encoder
// could choke on; the guarded fallback exists only to keep the function
// total. The returned pointer must be freed by the caller via
// ofem_core_string_free.
func marshalEnvelope(e envelope) *C.char {
	data, err := json.Marshal(e)
	if err != nil {
		// Final safety net: a hand-rolled error envelope so we never
		// return NULL on a logical condition.
		fallback := []byte(fmt.Sprintf(`{"error":{"code":"cannotSynchronize","message":%q}}`, err.Error()))
		return C.CString(string(fallback))
	}
	return C.CString(string(data))
}
