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
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
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

// --- path confinement tests -------------------------------------------------

func TestConfineToAllowedRoots_InRoot(t *testing.T) {
	dir := t.TempDir()
	// A file directly inside an allowed root must pass.
	if err := confineToAllowedRoots(filepath.Join(dir, "file.bin")); err != nil {
		t.Errorf("in-root path rejected: %v", err)
	}
	// A deeply nested path inside the root must also pass.
	if err := confineToAllowedRoots(filepath.Join(dir, "a", "b", "c.txt")); err != nil {
		t.Errorf("nested in-root path rejected: %v", err)
	}
}

func TestConfineToAllowedRoots_OutsideRoot(t *testing.T) {
	cases := []string{
		"/etc/passwd",
		"/Users/victim/.ssh/authorized_keys",
		"/tmp/../etc/shadow",
	}
	for _, p := range cases {
		if err := confineToAllowedRoots(p); err == nil {
			t.Errorf("outside-root path %q should be rejected, got nil", p)
		}
	}
}

func TestConfineToAllowedRoots_TraversalRejected(t *testing.T) {
	// Absolute paths outside any allowed root must be rejected regardless of
	// how they are spelled. filepath.Clean collapses ".." segments before the
	// prefix check, so these must all fail.
	cases := []string{
		"/etc/passwd",
		"/root/.ssh/authorized_keys",
		"/usr/local/bin/evil",
	}
	for _, p := range cases {
		if err := confineToAllowedRoots(p); err == nil {
			t.Errorf("outside-root path %q should be rejected, got nil", p)
		}
	}
}

func TestFetchContents_RejectsOutsideRoot(t *testing.T) {
	eng := &stubEngine{openData: "data"}
	svc := newService(eng, stubCache{})
	_, err := svc.FetchContents(context.Background(), "work", "ws1/lh/Files/x.txt", "/etc/passwd")
	if err == nil {
		t.Fatal("expected error for outside-root dest path, got nil")
	}
}

func TestCreateItem_RejectsOutsideRoot(t *testing.T) {
	eng := &stubEngine{}
	svc := newService(eng, stubCache{err: errors.New("miss")})
	_, err := svc.CreateItem(context.Background(), "work", "ws1/lh", "f.txt", false, "/etc/passwd")
	if err == nil {
		t.Fatal("expected error for outside-root src path, got nil")
	}
}

func TestModifyItem_RejectsOutsideRoot(t *testing.T) {
	eng := &stubEngine{}
	svc := newService(eng, stubCache{err: errors.New("miss")})
	_, err := svc.ModifyItem(context.Background(), "work", "ws1/lh/Files/x.txt", "/etc/passwd")
	if err == nil {
		t.Fatal("expected error for outside-root src path, got nil")
	}
}

// --- cursor paging tests ----------------------------------------------------

// makeEntries returns n stub cache entries with sequential names.
func makeEntries(n int) []cache.Entry {
	entries := make([]cache.Entry, n)
	for i := range entries {
		entries[i] = cache.Entry{
			Key:  cache.Key{WorkspaceID: "ws1", ItemID: "lh", Path: strings.Repeat("x", i+1)},
			Name: strings.Repeat("x", i+1),
		}
	}
	return entries
}

func TestEnumeratePaged_SinglePage(t *testing.T) {
	eng := &stubEngine{entries: makeEntries(5)}
	svc := newService(eng, stubCache{})
	page, err := svc.EnumeratePaged(context.Background(), "work", "ws1/lh", "")
	if err != nil {
		t.Fatalf("EnumeratePaged: %v", err)
	}
	if len(page.Items) != 5 {
		t.Errorf("items = %d, want 5", len(page.Items))
	}
	if page.NextCursor != "" {
		t.Errorf("NextCursor = %q, want empty on last page", page.NextCursor)
	}
}

func TestEnumeratePaged_MultiPage(t *testing.T) {
	// Use more items than enumeratePageSize to force paging.
	total := enumeratePageSize + 37
	eng := &stubEngine{entries: makeEntries(total)}
	svc := newService(eng, stubCache{})

	seen := map[string]bool{}
	cursor := ""
	pageCount := 0

	for {
		page, err := svc.EnumeratePaged(context.Background(), "work", "ws1/lh", cursor)
		if err != nil {
			t.Fatalf("EnumeratePaged page %d: %v", pageCount, err)
		}
		if len(page.Items) == 0 && page.NextCursor == "" {
			break
		}
		pageCount++
		for _, item := range page.Items {
			if seen[item.Identifier] {
				t.Errorf("duplicate item %q on page %d", item.Identifier, pageCount)
			}
			seen[item.Identifier] = true
		}
		if page.NextCursor == "" {
			break
		}
		cursor = page.NextCursor
	}

	if pageCount != 2 {
		t.Errorf("pageCount = %d, want 2", pageCount)
	}
	if len(seen) != total {
		t.Errorf("total unique items = %d, want %d", len(seen), total)
	}
}

func TestEnumeratePaged_FirstPageHasNextCursor(t *testing.T) {
	total := enumeratePageSize + 1
	eng := &stubEngine{entries: makeEntries(total)}
	svc := newService(eng, stubCache{})

	page, err := svc.EnumeratePaged(context.Background(), "work", "ws1/lh", "")
	if err != nil {
		t.Fatalf("EnumeratePaged: %v", err)
	}
	if page.NextCursor == "" {
		t.Error("first page should have a non-empty NextCursor when more items remain")
	}
	if len(page.Items) != enumeratePageSize {
		t.Errorf("first page items = %d, want %d", len(page.Items), enumeratePageSize)
	}

	// Follow the cursor to get the last page.
	last, err := svc.EnumeratePaged(context.Background(), "work", "ws1/lh", page.NextCursor)
	if err != nil {
		t.Fatalf("EnumeratePaged last page: %v", err)
	}
	if last.NextCursor != "" {
		t.Errorf("last page NextCursor = %q, want empty", last.NextCursor)
	}
	if len(last.Items) != 1 {
		t.Errorf("last page items = %d, want 1", len(last.Items))
	}
}

func TestClassify(t *testing.T) {
	cases := map[string]struct {
		err  error
		want ErrorCode
	}{
		"not-exist":          {os.ErrNotExist, CodeNoSuchItem},
		"paused":             {syncpkg.ErrWorkspacePaused, CodeServerBusy},
		"typed-not-found":    {httpretry.ErrNotFound, CodeNoSuchItem},
		"typed-unauthorized": {httpretry.ErrUnauthorized, CodeNotAuthenticated},
		"typed-forbidden":    {httpretry.ErrForbidden, CodeNotAuthenticated},
		"typed-throttled":    {httpretry.ErrThrottled, CodeServerBusy},
		"typed-gone":         {httpretry.ErrGone, CodeNoSuchItem},
		"other":              {errors.New("boom"), CodeCannotSynchronize},
		// Plain-text errors with status digits must NOT misfire as status
		// codes — the substring fallback was intentionally removed.
		"digit-in-filename": {errors.New("file-404.csv not readable"), CodeCannotSynchronize},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := Classify(tc.err); got != tc.want {
				t.Errorf("Classify(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
