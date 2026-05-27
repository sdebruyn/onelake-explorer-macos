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

	lastEnumerateKey cache.Key
	lastOpenKey      cache.Key
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
	if got.Capabilities[0] != "read" || len(got.Capabilities) != 1 {
		t.Fatalf("file caps = %v, want [read]", got.Capabilities)
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
	if !got.IsDir || got.Capabilities[1] != "enumerate" {
		t.Fatalf("dir caps wrong: %#v", got.Capabilities)
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
