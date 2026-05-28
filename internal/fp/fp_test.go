package fp

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	syncpkg "github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// stubEngine implements Engine with canned responses.
type stubEngine struct {
	workspaces []fabric.Workspace
	items      []fabric.Item
	entries    []cache.Entry
	openData   string
	openErr    error
	enumErr    error
	putErr     error
	mkdirErr   error
	delErr     error

	lastPutKey   cache.Key
	lastDelKey   cache.Key
	lastMkdirKey cache.Key
}

func (s *stubEngine) ListWorkspaces(context.Context, string) ([]fabric.Workspace, error) {
	return s.workspaces, nil
}
func (s *stubEngine) ListItems(context.Context, string, string) ([]fabric.Item, error) {
	return s.items, nil
}
func (s *stubEngine) Enumerate(context.Context, cache.Key) ([]cache.Entry, error) {
	return s.entries, s.enumErr
}
func (s *stubEngine) Open(context.Context, cache.Key) (io.ReadCloser, error) {
	if s.openErr != nil {
		return nil, s.openErr
	}
	return io.NopCloser(strings.NewReader(s.openData)), nil
}
func (s *stubEngine) Put(_ context.Context, k cache.Key, content io.Reader, _ int64) error {
	s.lastPutKey = k
	_, _ = io.Copy(io.Discard, content)
	return s.putErr
}
func (s *stubEngine) Delete(_ context.Context, k cache.Key) error { s.lastDelKey = k; return s.delErr }
func (s *stubEngine) Mkdir(_ context.Context, k cache.Key) error {
	s.lastMkdirKey = k
	return s.mkdirErr
}

// stubCache implements MetaCache.
type stubCache struct {
	entry cache.Entry
	err   error
}

func (s stubCache) Get(context.Context, cache.Key) (cache.Entry, error) { return s.entry, s.err }

func newService(e *stubEngine, c MetaCache) Service { return Service{Engine: e, Cache: c} }

func TestEnumerate_Root(t *testing.T) {
	eng := &stubEngine{workspaces: []fabric.Workspace{{ID: "ws1", DisplayName: "Sales"}}}
	items, err := newService(eng, stubCache{}).Enumerate(context.Background(), "work", "")
	if err != nil {
		t.Fatalf("Enumerate root: %v", err)
	}
	if len(items) != 1 || items[0].Identifier != "ws1" || items[0].ParentIdentifier != RootContainerID {
		t.Fatalf("unexpected root items: %+v", items)
	}
	if !items[0].IsDir {
		t.Error("workspace item should be a directory")
	}
}

func TestEnumerate_WorkspaceFiltersSQLEndpoint(t *testing.T) {
	eng := &stubEngine{items: []fabric.Item{
		{ID: "lh", WorkspaceID: "ws1", DisplayName: "Lake", Type: "Lakehouse"},
		{ID: "sql", WorkspaceID: "ws1", DisplayName: "Lake", Type: "SQLEndpoint"},
	}}
	items, err := newService(eng, stubCache{}).Enumerate(context.Background(), "work", "ws1")
	if err != nil {
		t.Fatalf("Enumerate workspace: %v", err)
	}
	if len(items) != 1 || items[0].Identifier != "ws1/lh" {
		t.Fatalf("SQLEndpoint not filtered: %+v", items)
	}
}

func TestEnumerate_PathMapsEntries(t *testing.T) {
	eng := &stubEngine{entries: []cache.Entry{
		{Key: cache.Key{WorkspaceID: "ws1", ItemID: "lh", Path: "Files/a.csv"}, Name: "a.csv", ContentLength: 12},
	}}
	items, err := newService(eng, stubCache{}).Enumerate(context.Background(), "work", "ws1/lh/Files")
	if err != nil {
		t.Fatalf("Enumerate path: %v", err)
	}
	if len(items) != 1 || items[0].Identifier != "ws1/lh/Files/a.csv" || items[0].ParentIdentifier != "ws1/lh/Files" {
		t.Fatalf("unexpected path items: %+v", items)
	}
}

func TestParseIdentifier_RejectsEmptySegments(t *testing.T) {
	eng := &stubEngine{}
	// Leading slash (empty workspace segment) and an empty item segment
	// are rejected. Note "ws/item//deep" is intentionally NOT here: it
	// parses as a path "/deep", matching the original bridge grammar.
	for _, bad := range []string{"/ws", "ws//item"} {
		if _, err := newService(eng, stubCache{}).Enumerate(context.Background(), "work", bad); err == nil {
			t.Errorf("identifier %q should be rejected", bad)
		}
	}
}

func TestFetchContents_WritesDestAndReturnsItem(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "sub", "out.bin")
	eng := &stubEngine{openData: "hello world"}
	c := stubCache{entry: cache.Entry{
		Key:  cache.Key{WorkspaceID: "ws1", ItemID: "lh", Path: "Files/x.txt"},
		Name: "x.txt", ContentLength: 11, Etag: "e1",
	}}
	item, err := newService(eng, c).FetchContents(context.Background(), "work", "ws1/lh/Files/x.txt", dest)
	if err != nil {
		t.Fatalf("FetchContents: %v", err)
	}
	got, rerr := os.ReadFile(dest)
	if rerr != nil || string(got) != "hello world" {
		t.Fatalf("dest content = %q (err %v), want %q", got, rerr, "hello world")
	}
	if item.Identifier != "ws1/lh/Files/x.txt" || item.Filename != "x.txt" {
		t.Fatalf("unexpected item: %+v", item)
	}
}

func TestFetchContents_RejectsNonFileIdentifier(t *testing.T) {
	_, err := newService(&stubEngine{}, stubCache{}).FetchContents(context.Background(), "work", "ws1/lh", "/tmp/x")
	if err == nil || Classify(err) != CodeNoSuchItem {
		t.Fatalf("err = %v (code %v), want noSuchItem", err, Classify(err))
	}
}

func TestCreateItem_Dir(t *testing.T) {
	eng := &stubEngine{}
	c := stubCache{err: errors.New("miss")} // force synthetic item
	item, err := newService(eng, c).CreateItem(context.Background(), "work", "ws1/lh", "newdir", true, "")
	if err != nil {
		t.Fatalf("CreateItem dir: %v", err)
	}
	if eng.lastMkdirKey.Path != "newdir" {
		t.Errorf("Mkdir key path = %q, want newdir", eng.lastMkdirKey.Path)
	}
	if item.Identifier != "ws1/lh/newdir" || !item.IsDir {
		t.Fatalf("unexpected created item: %+v", item)
	}
}

func TestDeleteItem(t *testing.T) {
	eng := &stubEngine{}
	if err := newService(eng, stubCache{}).DeleteItem(context.Background(), "work", "ws1/lh/Files/x.txt"); err != nil {
		t.Fatalf("DeleteItem: %v", err)
	}
	if eng.lastDelKey.Path != "Files/x.txt" || eng.lastDelKey.ItemID != "lh" {
		t.Errorf("unexpected delete key: %+v", eng.lastDelKey)
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]struct {
		err  error
		want ErrorCode
	}{
		"not-exist": {os.ErrNotExist, CodeNoSuchItem},
		"paused":    {syncpkg.ErrWorkspacePaused, CodeServerBusy},
		"plain-404": {errors.New("HTTP 404 not found"), CodeNoSuchItem},
		"plain-401": {errors.New("HTTP 401 unauthorized"), CodeNotAuthenticated},
		"other":     {errors.New("boom"), CodeCannotSynchronize},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := Classify(tc.err); got != tc.want {
				t.Errorf("Classify(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
