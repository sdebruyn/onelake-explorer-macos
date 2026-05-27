// Bridge tests cover the parts of core/bridge.go that can be exercised
// without a real cgo entry point: identifier parsing, error
// classification, JSON envelope shapes, and the enumerate dispatch. The
// init/close lifecycle is covered separately by setting up the package
// globals manually, which keeps these tests free of MSAL and real
// network calls.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
	syncpkg "github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// fakeEngine satisfies bridgeEngine for the dispatch tests. Each method
// returns a canned value picked by the test, or an error if one was set.
// We do not embed sync.Engine because we want to keep these tests free
// of network and auth wiring.
type fakeEngine struct {
	workspaces []fabric.Workspace
	items      []fabric.Item
	entries    []cache.Entry
	openBody   string

	errWorkspaces error
	errItems      error
	errEnumerate  error
	errOpen       error
	errPut        error
	errDelete     error
	errMkdir      error

	lastEnumerateKey cache.Key
	lastOpenKey      cache.Key
	lastPutKey       cache.Key
	lastDeleteKey    cache.Key
	lastMkdirKey     cache.Key
	putCalled        bool
	deleteCalled     bool
	mkdirCalled      bool
}

func (f *fakeEngine) ListWorkspaces(ctx context.Context, alias string) ([]fabric.Workspace, error) {
	return f.workspaces, f.errWorkspaces
}
func (f *fakeEngine) ListItems(ctx context.Context, alias, workspaceID string) ([]fabric.Item, error) {
	return f.items, f.errItems
}
func (f *fakeEngine) Enumerate(ctx context.Context, k cache.Key) ([]cache.Entry, error) {
	f.lastEnumerateKey = k
	return f.entries, f.errEnumerate
}
func (f *fakeEngine) Open(ctx context.Context, k cache.Key) (io.ReadCloser, error) {
	f.lastOpenKey = k
	if f.errOpen != nil {
		return nil, f.errOpen
	}
	return io.NopCloser(strings.NewReader(f.openBody)), nil
}
func (f *fakeEngine) Put(ctx context.Context, k cache.Key, content io.Reader, size int64) error {
	f.putCalled = true
	f.lastPutKey = k
	if f.errPut != nil {
		return f.errPut
	}
	// Drain the reader so file handles are not left open in tests.
	_, _ = io.Copy(io.Discard, content)
	return nil
}
func (f *fakeEngine) Delete(ctx context.Context, k cache.Key) error {
	f.deleteCalled = true
	f.lastDeleteKey = k
	return f.errDelete
}
func (f *fakeEngine) Mkdir(ctx context.Context, k cache.Key) error {
	f.mkdirCalled = true
	f.lastMkdirKey = k
	return f.errMkdir
}

// TestParseIdentifier locks in the identifier grammar the Swift side
// relies on. Each row asserts the kind and the parsed segments.
func TestParseIdentifier(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		input  string
		want   scope
		hasErr bool
	}{
		{"empty -> root", "", scope{kind: scopeRoot}, false},
		{"rootContainer -> root", rootContainerID, scope{kind: scopeRoot}, false},
		{"workspace only", "ws-1", scope{kind: scopeWorkspace, workspace: "ws-1"}, false},
		{"workspace + item", "ws-1/it-1", scope{kind: scopeItem, workspace: "ws-1", item: "it-1"}, false},
		{"item root path", "ws-1/it-1/", scope{kind: scopePath, workspace: "ws-1", item: "it-1", path: ""}, false},
		{"deep path", "ws/it/Files/a/b.csv", scope{kind: scopePath, workspace: "ws", item: "it", path: "Files/a/b.csv"}, false},
		{"trailing slash trimmed", "ws/it/Files/a/", scope{kind: scopePath, workspace: "ws", item: "it", path: "Files/a"}, false},
		// Negative cases: malformed identifiers must return errors, not silently
		// route to a backend call with an empty workspace or item ID.
		{"leading slash", "/abc", scope{}, true},
		{"trailing slash workspace only", "ws-1/", scope{}, true},
		{"leading slash item form", "/it-1", scope{}, true},
		{"double slash", "ws//it", scope{}, true},
		{"single slash only", "/", scope{}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseIdentifier(c.input)
			if c.hasErr {
				if err == nil {
					t.Fatalf("parseIdentifier(%q) want err, got nil", c.input)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseIdentifier(%q) err: %v", c.input, err)
			}
			if got != c.want {
				t.Fatalf("parseIdentifier(%q) = %#v, want %#v", c.input, got, c.want)
			}
		})
	}
}

// TestEnumerateScope_Root verifies that ".rootContainer" delegates to
// ListWorkspaces and that the workspace->bridgeItem mapping is correct.
func TestEnumerateScope_Root(t *testing.T) {
	t.Parallel()
	eng := &fakeEngine{
		workspaces: []fabric.Workspace{
			{ID: "ws-1", DisplayName: "Sales"},
			{ID: "ws-2", DisplayName: "Marketing"},
		},
	}
	items, err := enumerateScope(context.Background(), eng, "work", scope{kind: scopeRoot})
	if err != nil {
		t.Fatalf("enumerateScope err: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("len(items) = %d, want 2", len(items))
	}
	if items[0].Identifier != "ws-1" || items[0].ParentIdentifier != rootContainerID {
		t.Fatalf("ws-1 identifier wrong: %#v", items[0])
	}
	if !items[0].IsDir || items[0].Capabilities[0] != "read" || items[0].Capabilities[1] != "enumerate" {
		t.Fatalf("ws-1 missing dir capabilities: %#v", items[0])
	}
	if items[0].ContentVersion == "" || items[0].MetadataVersion == "" {
		t.Fatalf("ws-1 missing versions: %#v", items[0])
	}
}

// TestEnumerateScope_WorkspaceAndItem verifies the workspace and item
// dispatches build the right cache.Key and bridgeItem shape.
func TestEnumerateScope_WorkspaceAndItem(t *testing.T) {
	t.Parallel()
	eng := &fakeEngine{
		items: []fabric.Item{
			{ID: "it-1", DisplayName: "Lakehouse A", WorkspaceID: "ws-1"},
		},
		entries: []cache.Entry{
			{
				Key:           cache.Key{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "it-1", Path: "Files/data.csv"},
				ParentPath:    "Files",
				Name:          "data.csv",
				IsDir:         false,
				ContentLength: 12345,
				Etag:          "0xabc",
				LastModified:  time.Date(2026, 4, 1, 12, 0, 0, 0, time.UTC),
			},
		},
	}

	// Workspace scope -> list items.
	got, err := enumerateScope(context.Background(), eng, "work", scope{kind: scopeWorkspace, workspace: "ws-1"})
	if err != nil {
		t.Fatalf("workspace enum err: %v", err)
	}
	if len(got) != 1 || got[0].Identifier != "ws-1/it-1" || got[0].ParentIdentifier != "ws-1" {
		t.Fatalf("workspace items wrong: %#v", got)
	}

	// Item scope -> enumerate cache.
	got, err = enumerateScope(context.Background(), eng, "work", scope{kind: scopeItem, workspace: "ws-1", item: "it-1"})
	if err != nil {
		t.Fatalf("item enum err: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("item items len = %d", len(got))
	}
	want := "ws-1/it-1/Files/data.csv"
	if got[0].Identifier != want {
		t.Fatalf("file identifier = %q, want %q", got[0].Identifier, want)
	}
	if got[0].ParentIdentifier != "ws-1/it-1/Files" {
		t.Fatalf("file parent = %q, want %q", got[0].ParentIdentifier, "ws-1/it-1/Files")
	}
	if got[0].Size != 12345 || got[0].Filename != "data.csv" {
		t.Fatalf("file size/name wrong: %#v", got[0])
	}
	if got[0].ContentVersion == "" {
		t.Fatalf("file contentVersion empty")
	}

	// And the cache.Key the engine received reflects the scope.
	if eng.lastEnumerateKey.WorkspaceID != "ws-1" || eng.lastEnumerateKey.ItemID != "it-1" || eng.lastEnumerateKey.Path != "" {
		t.Fatalf("enumerate key wrong: %#v", eng.lastEnumerateKey)
	}
}

// TestEnumerateScope_DeepPath confirms identifier construction for
// nested paths produces both parent and child identifiers that parse
// back into the original scope.
func TestEnumerateScope_DeepPath(t *testing.T) {
	t.Parallel()
	eng := &fakeEngine{
		entries: []cache.Entry{
			{
				Key:        cache.Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it", Path: "Files/sub/file.txt"},
				ParentPath: "Files/sub",
				Name:       "file.txt",
				IsDir:      false,
			},
		},
	}
	got, err := enumerateScope(context.Background(), eng, "work", scope{
		kind: scopePath, workspace: "ws", item: "it", path: "Files/sub",
	})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got[0].Identifier != "ws/it/Files/sub/file.txt" {
		t.Fatalf("id = %q", got[0].Identifier)
	}
	if got[0].ParentIdentifier != "ws/it/Files/sub" {
		t.Fatalf("parent = %q", got[0].ParentIdentifier)
	}
	// Round-trip: the identifier we just emitted must parse back.
	s, err := parseIdentifier(got[0].Identifier)
	if err != nil {
		t.Fatalf("round-trip parse: %v", err)
	}
	if s.workspace != "ws" || s.item != "it" || s.path != "Files/sub/file.txt" {
		t.Fatalf("round-trip mismatch: %#v", s)
	}
}

// TestClassifyError walks every branch of the error -> code mapping.
// We use the sentinel errors directly rather than fabricating HTTP
// responses; the goal is to verify the mapping, not the producers.
func TestClassifyError(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		err  error
		want string
	}{
		{"nil -> default", errors.New("boom"), "cannotSynchronize"},
		{"ErrNotExist -> noSuchItem", os.ErrNotExist, "noSuchItem"},
		{"ErrNotFound -> noSuchItem", httpretry.ErrNotFound, "noSuchItem"},
		{"ErrGone -> noSuchItem", httpretry.ErrGone, "noSuchItem"},
		{"LWW exhausted", syncpkg.ErrLastWriteWinsExhausted, "cannotSynchronize"},
		{"paused workspace", syncpkg.ErrWorkspacePaused, "serverBusy"},
		{"throttled", httpretry.ErrThrottled, "serverBusy"},
		{"unauthorized", httpretry.ErrUnauthorized, "notAuthenticated"},
		{"forbidden", httpretry.ErrForbidden, "notAuthenticated"},
		{"401 in message", errors.New("got 401 from server"), "notAuthenticated"},
		{"403 in message", errors.New("got 403 from server"), "notAuthenticated"},
		{"404 in message", errors.New("got 404 from server"), "noSuchItem"},
		{"429 in message", errors.New("got 429 from server"), "serverBusy"},
		{"net.OpError -> unreachable", &net.OpError{Op: "dial", Err: errors.New("connection refused")}, "serverUnreachable"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := classifyError(c.err)
			if got != c.want {
				t.Fatalf("classifyError(%v) = %q, want %q", c.err, got, c.want)
			}
		})
	}
}

// TestEntryToItem locks in the JSON shape for the cache row -> bridgeItem
// conversion: identifier, parent, capabilities, content/metadata
// versions and content-type sniffing.
func TestEntryToItem(t *testing.T) {
	t.Parallel()
	mtime := time.Date(2026, 4, 1, 12, 0, 0, 0, time.UTC)

	// File at depth 2 inside an item.
	file := cache.Entry{
		Key:           cache.Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it", Path: "Files/a.csv"},
		ParentPath:    "Files",
		Name:          "a.csv",
		IsDir:         false,
		ContentLength: 42,
		Etag:          "0xetag",
		LastModified:  mtime,
	}
	got := entryToItem("work", file)
	if got.Identifier != "ws/it/Files/a.csv" {
		t.Fatalf("file id = %q", got.Identifier)
	}
	if got.ParentIdentifier != "ws/it/Files" {
		t.Fatalf("file parent = %q", got.ParentIdentifier)
	}
	wantFileCaps := []string{"read", "write", "delete"}
	if len(got.Capabilities) != len(wantFileCaps) {
		t.Fatalf("file caps = %v, want %v", got.Capabilities, wantFileCaps)
	}
	for i, c := range wantFileCaps {
		if got.Capabilities[i] != c {
			t.Fatalf("file caps[%d] = %q, want %q", i, got.Capabilities[i], c)
		}
	}
	if got.ContentVersion == "" || got.MetadataVersion == "" {
		t.Fatalf("file missing version fields")
	}
	if got.ContentType == "" {
		t.Fatalf("file ContentType not sniffed for .csv")
	}

	// Directory at item root.
	dir := cache.Entry{
		Key:        cache.Key{AccountAlias: "work", WorkspaceID: "ws", ItemID: "it", Path: "Files"},
		ParentPath: "",
		Name:       "Files",
		IsDir:      true,
	}
	got = entryToItem("work", dir)
	if got.Identifier != "ws/it/Files" {
		t.Fatalf("dir id = %q", got.Identifier)
	}
	if got.ParentIdentifier != "ws/it" {
		t.Fatalf("dir parent = %q, want ws/it", got.ParentIdentifier)
	}
	wantDirCaps := []string{"read", "write", "delete", "enumerate", "add_subitems"}
	if !got.IsDir || len(got.Capabilities) != len(wantDirCaps) {
		t.Fatalf("dir caps wrong: %#v, want %v", got.Capabilities, wantDirCaps)
	}
	for i, c := range wantDirCaps {
		if got.Capabilities[i] != c {
			t.Fatalf("dir caps[%d] = %q, want %q", i, got.Capabilities[i], c)
		}
	}
}

// TestEnvelopeJSON verifies the on-wire JSON shape so a Swift Codable
// counterpart can be specced against this output.
func TestEnvelopeJSON(t *testing.T) {
	t.Parallel()
	env := envelope{Items: []bridgeItem{{
		Identifier:       "ws/it/foo.csv",
		ParentIdentifier: "ws/it",
		Filename:         "foo.csv",
		IsDir:            false,
		Size:             100,
		ContentType:      "text/csv",
		ContentVersion:   "Y29udGVudA==",
		MetadataVersion:  "bWV0YQ==",
		Capabilities:     []string{"read"},
	}}}
	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(data), `"items":[{`) {
		t.Fatalf("missing items key: %s", data)
	}
	if !strings.Contains(string(data), `"capabilities":["read"]`) {
		t.Fatalf("missing caps: %s", data)
	}
	// Re-decode to check field tags round-trip cleanly.
	var back envelope
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.Items[0].Filename != "foo.csv" {
		t.Fatalf("round-trip filename = %q", back.Items[0].Filename)
	}
}

// TestErrorEnvelope verifies the error envelope renders as
// {"error":{"code":"...","message":"..."}}.
func TestErrorEnvelope(t *testing.T) {
	t.Parallel()
	env := envelope{Error: errorPayloadFromGo(httpretry.ErrThrottled)}
	data, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(data), `"code":"serverBusy"`) {
		t.Fatalf("missing code: %s", data)
	}
	if !strings.Contains(string(data), `"message":`) {
		t.Fatalf("missing message: %s", data)
	}
}

// TestBridgeLifecycle exercises init/close round-trip using a temp App
// Group container directory and a memory keychain. It does not call the
// C exports (those require a c-archive); it drives the underlying
// helpers via direct setup so the test stays in pure Go.
func TestBridgeLifecycle(t *testing.T) {
	// Pin HOME to a temp dir so config.ResolvePaths picks our sandbox.
	dir := t.TempDir()
	t.Setenv("HOME", dir)

	// Sanity-check resolveBridgePaths still works for both modes.
	paths, err := resolveBridgePaths(nil)
	if err != nil {
		t.Fatalf("resolveBridgePaths: %v", err)
	}
	if paths.ConfigDir == "" {
		t.Fatalf("paths.ConfigDir empty")
	}

	// Make sure the bridge starts clean. ofem_core_close on a never-init'd
	// bridge must be a no-op.
	resetBridgeForTest()
	if bridgeReady.Load() {
		t.Fatalf("expected bridgeReady false at start")
	}

	// Set up the bridge globals by hand so we can exercise list_accounts
	// without running ofem_core_init's MSAL client factory.
	cdir := filepath.Join(paths.ConfigDir, "cache")
	if err := os.MkdirAll(cdir, 0o700); err != nil {
		t.Fatalf("mkdir cache: %v", err)
	}
	cstore, err := cache.Open(cache.Options{Root: cdir})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	defer func() { _ = cstore.Close() }()

	// Drive the install through the config.Store API so the registry can
	// find a known account afterwards.
	bridgeInitMu.Lock()
	bridgeCache = cstore
	store, err := config.Load()
	if err != nil {
		bridgeInitMu.Unlock()
		t.Fatalf("config.Load: %v", err)
	}
	bridgeStore = store
	bridgeReg = auth.NewRegistry(store, auth.NewMemoryKeychain(), auth.EntraClientID, nil)
	bridgeEng = &fakeEngine{}
	bridgeReady.Store(true)
	bridgeInitMu.Unlock()

	// Empty registry -> empty accounts list, never an error envelope.
	got := goString(ofem_core_list_accounts())
	if !strings.Contains(got, `"accounts":[]`) && !strings.Contains(got, `"accounts":null`) {
		t.Fatalf("expected empty accounts, got %s", got)
	}
	// Then close and verify the close is idempotent.
	ofem_core_close()
	if bridgeReady.Load() {
		t.Fatalf("expected bridgeReady false after close")
	}
	ofem_core_close() // second call is a no-op

	// TODO(phase-2): add a race test where one goroutine calls
	// ofem_core_enumerate while another calls ofem_core_close. The
	// RWMutex in ofem_core_close guarantees the close blocks until the
	// in-flight call finishes, but the test requires a c-archive build
	// to exercise the real C-ABI entry points.
}

// setupBridgeWithFake wires a fakeEngine and an in-memory cache into the
// bridge globals. The returned cleanup function tears down the cache and
// resets the globals. Every write-path test that exercises the bridge
// globals must use this helper or reset manually.
func setupBridgeWithFake(t *testing.T, eng *fakeEngine) func() {
	t.Helper()
	dir := t.TempDir()
	cdir := filepath.Join(dir, "cache")
	if err := os.MkdirAll(cdir, 0o700); err != nil {
		t.Fatalf("mkdir cache: %v", err)
	}
	cstore, err := cache.Open(cache.Options{Root: cdir})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	bridgeInitMu.Lock()
	bridgeCache = cstore
	bridgeEng = eng
	bridgeReady.Store(true)
	bridgeInitMu.Unlock()
	return func() {
		bridgeInitMu.Lock()
		_ = cstore.Close()
		bridgeCache = nil
		bridgeEng = nil
		bridgeReady.Store(false)
		bridgeInitMu.Unlock()
	}
}

// createItemGo is a pure-Go shim that calls bridgeCreateItem — the same
// function body that ofem_core_create_item uses — without crossing the C
// boundary. This ensures tests cover the real production logic rather than
// a copy that can silently diverge (e.g. the isDir short-circuit bug).
func createItemGo(alias, parentID, filename string, isDir bool, srcPath string) string {
	result, err := bridgeCreateItem(alias, parentID, filename, isDir, srcPath)
	if err != nil {
		var ep *errorPayload
		if errors.As(err, &ep) {
			return string(mustMarshal(envelope{Error: ep}))
		}
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(err)}))
	}
	return result
}

// modifyItemGo is a pure-Go shim for ofem_core_modify_item.
func modifyItemGo(alias, identifier, srcPath string) string {
	sc, perr := parseIdentifier(identifier)
	if perr != nil {
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(perr)}))
	}
	if sc.kind != scopePath {
		return string(mustMarshal(envelope{Error: &errorPayload{
			Code:    "noSuchItem",
			Message: "modify_item requires a file identifier",
		}}))
	}
	f, ferr := os.Open(srcPath)
	if ferr != nil {
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(ferr)}))
	}
	defer func() { _ = f.Close() }()
	fi, serr := f.Stat()
	if serr != nil {
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(serr)}))
	}
	ctx := context.Background()
	key := cache.Key{AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path}
	if err := bridgeEng.Put(ctx, key, f, fi.Size()); err != nil {
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(err)}))
	}
	entry, gerr := bridgeCache.Get(ctx, key)
	if gerr == nil {
		it := entryToItem(alias, entry)
		return string(mustMarshal(envelope{Item: &it}))
	}
	parentID := buildPathParentID(sc.workspace, sc.item, sc.path)
	synthetic := syntheticItem(sc.workspace, sc.item, sc.path, parentID, path.Base(sc.path), false)
	synthetic.Size = fi.Size()
	return string(mustMarshal(envelope{Item: &synthetic}))
}

// deleteItemGo is a pure-Go shim for ofem_core_delete_item.
func deleteItemGo(alias, identifier string) string {
	sc, perr := parseIdentifier(identifier)
	if perr != nil {
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(perr)}))
	}
	if sc.kind != scopePath {
		return string(mustMarshal(envelope{Error: &errorPayload{
			Code:    "noSuchItem",
			Message: "delete_item requires a path identifier",
		}}))
	}
	if syncpkg.IsMacOSMetadata(sc.path) {
		return "{}"
	}
	ctx := context.Background()
	key := cache.Key{AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path}
	if err := bridgeEng.Delete(ctx, key); err != nil {
		return string(mustMarshal(envelope{Error: errorPayloadFromGo(err)}))
	}
	return "{}"
}

// mustMarshal marshals v to JSON or panics; only used in test helpers.
func mustMarshal(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// TestCreateItem_File verifies that createItemGo for a normal file
// delegates to Engine.Put and returns a bridgeItem JSON envelope.
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestCreateItem_File(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	src := filepath.Join(t.TempDir(), "hello.txt")
	if err := os.WriteFile(src, []byte("hello"), 0o600); err != nil {
		t.Fatalf("write src: %v", err)
	}

	raw := createItemGo("work", "ws-1/it-1", "hello.txt", false, src)
	if strings.Contains(raw, `"error"`) {
		t.Fatalf("unexpected error envelope: %s", raw)
	}
	if !eng.putCalled {
		t.Fatalf("expected Engine.Put to be called")
	}
	if eng.lastPutKey.WorkspaceID != "ws-1" || eng.lastPutKey.ItemID != "it-1" || eng.lastPutKey.Path != "hello.txt" {
		t.Fatalf("put key wrong: %#v", eng.lastPutKey)
	}
	if !strings.Contains(raw, `"filename":"hello.txt"`) {
		t.Fatalf("filename missing in response: %s", raw)
	}
}

// TestCreateItem_Folder verifies that createItemGo for a directory calls
// Engine.Mkdir and returns a synthetic folder item.
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestCreateItem_Folder(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	raw := createItemGo("work", "ws-1/it-1/Files", "newdir", true, "")
	if strings.Contains(raw, `"error"`) {
		t.Fatalf("unexpected error envelope: %s", raw)
	}
	if !eng.mkdirCalled {
		t.Fatalf("expected Engine.Mkdir to be called")
	}
	if eng.lastMkdirKey.Path != "Files/newdir" {
		t.Fatalf("mkdir path wrong: %q, want %q", eng.lastMkdirKey.Path, "Files/newdir")
	}
	if !strings.Contains(raw, `"isDir":true`) {
		t.Fatalf("isDir not true in response: %s", raw)
	}
}

// TestCreateItem_MacOSMetadata verifies that .DS_Store is accepted without
// calling the engine, and that the isDir field in the response reflects the
// caller's isDir parameter (not a hardcoded true).
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestCreateItem_MacOSMetadata(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	// isDir=false: .DS_Store is a file; the response must have isDir:false.
	raw := createItemGo("work", "ws-1/it-1/Files", ".DS_Store", false, "")
	if strings.Contains(raw, `"error"`) {
		t.Fatalf("unexpected error envelope: %s", raw)
	}
	if eng.putCalled {
		t.Fatalf("Engine.Put must NOT be called for macOS metadata")
	}
	if eng.mkdirCalled {
		t.Fatalf("Engine.Mkdir must NOT be called for macOS metadata")
	}
	if !strings.Contains(raw, `"filename":".DS_Store"`) {
		t.Fatalf("filename missing in response: %s", raw)
	}
	// Verify isDir reflects the caller's parameter, not hardcoded true.
	if strings.Contains(raw, `"isDir":true`) {
		t.Fatalf("isDir must be false for a file-shaped .DS_Store request, got: %s", raw)
	}
}

// TestModifyItem_HappyPath verifies that modifyItemGo calls Engine.Put
// with the correct key.
func TestModifyItem_HappyPath(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	src := filepath.Join(t.TempDir(), "data.txt")
	if err := os.WriteFile(src, []byte("updated"), 0o600); err != nil {
		t.Fatalf("write src: %v", err)
	}

	raw := modifyItemGo("work", "ws-1/it-1/Files/data.txt", src)
	if strings.Contains(raw, `"error"`) {
		t.Fatalf("unexpected error envelope: %s", raw)
	}
	if !eng.putCalled {
		t.Fatalf("expected Engine.Put to be called")
	}
	if eng.lastPutKey.Path != "Files/data.txt" {
		t.Fatalf("put path wrong: %q", eng.lastPutKey.Path)
	}
}

// TestModifyItem_MissingSource verifies that a missing srcPath surfaces
// a cannotSynchronize-or-noSuchItem error without calling the engine.
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestModifyItem_MissingSource(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	raw := modifyItemGo("work", "ws-1/it-1/Files/data.txt", "/nonexistent/path/data.txt")
	if !strings.Contains(raw, `"error"`) {
		t.Fatalf("expected error envelope, got: %s", raw)
	}
	if eng.putCalled {
		t.Fatalf("Engine.Put must not be called when source is missing")
	}
}

// TestDeleteItem_HappyPath verifies that deleteItemGo calls Engine.Delete
// with the right key and returns "{}".
func TestDeleteItem_HappyPath(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	raw := deleteItemGo("work", "ws-1/it-1/Files/data.csv")
	if raw != "{}" {
		t.Fatalf("expected {}, got: %s", raw)
	}
	if !eng.deleteCalled {
		t.Fatalf("expected Engine.Delete to be called")
	}
	if eng.lastDeleteKey.Path != "Files/data.csv" {
		t.Fatalf("delete path wrong: %q", eng.lastDeleteKey.Path)
	}
}

// TestDeleteItem_MacOSMetadata verifies that deleting a macOS metadata
// path succeeds without calling Engine.Delete.
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestDeleteItem_MacOSMetadata(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	raw := deleteItemGo("work", "ws-1/it-1/Files/.DS_Store")
	if raw != "{}" {
		t.Fatalf("expected {}, got: %s", raw)
	}
	if eng.deleteCalled {
		t.Fatalf("Engine.Delete must NOT be called for macOS metadata")
	}
}

// TestCreateItem_IdentifierEdgeCases verifies that identifiers that don't
// point inside a Fabric item (workspace-only, root) are rejected.
// Bridge globals are set so a future refactor that consults globals before
// the scope check does not silently pass due to a nil-engine panic.
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestCreateItem_IdentifierEdgeCases(t *testing.T) {
	eng := &fakeEngine{}
	cleanup := setupBridgeWithFake(t, eng)
	defer cleanup()

	cases := []struct {
		name   string
		parent string
	}{
		{"workspace only", "ws-1"},
		{"rootContainer", ".rootContainer"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			raw := createItemGo("work", c.parent, "file.txt", false, "")
			if !strings.Contains(raw, `"error"`) {
				t.Fatalf("expected error for parent %q, got: %s", c.parent, raw)
			}
		})
	}
}

// TestWritePath_NegativeErrorPropagation verifies that error codes from
// Engine.Put, Engine.Delete, and Engine.Mkdir are mapped to the expected
// bridge error codes in the JSON envelope.
// Not t.Parallel: uses package-level bridge globals via setupBridgeWithFake.
func TestWritePath_NegativeErrorPropagation(t *testing.T) {
	cases := []struct {
		name     string
		putErr   error
		delErr   error
		mkdirErr error
		// fn selects which bridge operation to exercise.
		fn       func(eng *fakeEngine, src string) string
		wantCode string
	}{
		{
			name:     "Put ErrLastWriteWinsExhausted -> cannotSynchronize",
			putErr:   syncpkg.ErrLastWriteWinsExhausted,
			fn:       func(eng *fakeEngine, src string) string { return createItemGo("work", "ws/it", "f.txt", false, src) },
			wantCode: "cannotSynchronize",
		},
		{
			name:     "Delete 401-equivalent -> notAuthenticated",
			delErr:   httpretry.ErrUnauthorized,
			fn:       func(eng *fakeEngine, src string) string { return deleteItemGo("work", "ws/it/Files/f.csv") },
			wantCode: "notAuthenticated",
		},
		{
			name:     "Mkdir paused capacity -> serverBusy",
			mkdirErr: syncpkg.ErrWorkspacePaused,
			fn:       func(eng *fakeEngine, src string) string { return createItemGo("work", "ws/it", "newdir", true, "") },
			wantCode: "serverBusy",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			eng := &fakeEngine{errPut: c.putErr, errDelete: c.delErr, errMkdir: c.mkdirErr}
			cleanup := setupBridgeWithFake(t, eng)
			defer cleanup()

			// For Put tests we need a real source file; for others src is unused.
			src := ""
			if c.putErr != nil {
				f := filepath.Join(t.TempDir(), "payload.txt")
				if err := os.WriteFile(f, []byte("data"), 0o600); err != nil {
					t.Fatalf("write src: %v", err)
				}
				src = f
			}

			raw := c.fn(eng, src)
			if !strings.Contains(raw, `"error"`) {
				t.Fatalf("%s: expected error envelope, got: %s", c.name, raw)
			}
			if !strings.Contains(raw, `"`+c.wantCode+`"`) {
				t.Fatalf("%s: expected code %q in: %s", c.name, c.wantCode, raw)
			}
		})
	}
}

// resetBridgeForTest clears the package globals so a follow-up test can
// re-init from a clean slate. Test-only helper.
func resetBridgeForTest() {
	bridgeInitMu.Lock()
	defer bridgeInitMu.Unlock()
	bridgeStore = nil
	bridgeCache = nil
	bridgeReg = nil
	bridgeEng = nil
	bridgeReady.Store(false)
}
