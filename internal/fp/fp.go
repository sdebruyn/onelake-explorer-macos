// Package fp holds the File Provider domain model that the daemon exposes
// over IPC to the sandboxed File Provider Extension: identifier parsing,
// the wire-shape [Item] the extension turns into an NSFileProviderItem,
// the enumerate / item / fetch / create / modify / delete operations
// against a [sync.Engine], and the error→code classification the
// extension maps onto NSFileProviderError.
//
// This logic used to live inside the cgo bridge (core/bridge.go), compiled
// into the extension as a second engine. It moved here so the daemon —
// the single owner of the engine and the cache — can serve it over the
// same unix-socket IPC the host app uses, and the cgo bridge can be
// deleted (see SIMPLIFICATION.md).
package fp

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"mime"
	"net"
	"os"
	"path"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
	syncpkg "github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// allowedRoots is the set of filesystem root prefixes under which the
// daemon may read or write files on behalf of IPC callers. It is
// populated once at init time from the well-known macOS locations shared
// between the daemon, the host app, and the sandboxed extension.
//
// The App Group container (~/Library/Group Containers/group.dev.debruyn.ofem)
// is the rendezvous point documented in docs/file-provider.md. Both the
// daemon's cache/staging area and the extension's per-file staging area
// live under it. The user's temp dir is also included for test fixtures.
var allowedRoots []string

func init() {
	home, err := os.UserHomeDir()
	if err == nil {
		candidates := []string{
			filepath.Join(home, "Library", "Group Containers", "group.dev.debruyn.ofem"),
			os.TempDir(),
		}
		for _, c := range candidates {
			c = filepath.Clean(c)
			allowedRoots = append(allowedRoots, c)
			// Also add the symlink-resolved form so the prefix check in
			// confineToAllowedRoots works on macOS where /var/folders →
			// /private/var/folders. Both forms are accepted.
			if resolved, err := filepath.EvalSymlinks(c); err == nil && resolved != c {
				allowedRoots = append(allowedRoots, resolved)
			}
		}
	}
}

// confineToAllowedRoots verifies that p, after filepath.Clean+EvalSymlinks,
// is inside one of the daemon's allowed staging roots. It rejects any path
// that contains ".." after cleaning or that resolves outside those roots.
// Returns a wrapped sentinel error on rejection so callers can log it
// without leaking the raw path to cloud storage.
//
// When p does not yet exist on disk (e.g. a destination file that will be
// created by FetchContents), EvalSymlinks fails on p itself. Callers that
// write to a new path MUST call confineToAllowedRoots again on the PARENT
// directory after os.MkdirAll — the parent exists at that point, so
// EvalSymlinks will resolve any symlinks that a race introduced there and
// the subsequent open must use the resolved parent path with O_NOFOLLOW.
// See fetchContentsConfineParent for the correct pattern.
func confineToAllowedRoots(p string) error {
	if p == "" {
		return errors.New("fp: empty path")
	}
	cleaned := filepath.Clean(p)
	if resolved, err := filepath.EvalSymlinks(cleaned); err == nil {
		cleaned = resolved
	}
	for _, root := range allowedRoots {
		if strings.HasPrefix(cleaned, root+string(filepath.Separator)) || cleaned == root {
			return nil
		}
	}
	return fmt.Errorf("fp: path outside allowed staging roots: %w", os.ErrPermission)
}

// fetchContentsConfineParent resolves the parent of destPath (which must
// already exist after os.MkdirAll) via filepath.EvalSymlinks and verifies
// that the resolved parent is within an allowed root. Returns the resolved
// parent so the caller can open the final path without following symlinks.
//
// This is the second confinement check for FetchContents: the first
// (confineToAllowedRoots on the full destPath) is a fast lexical reject for
// paths that are obviously outside allowed roots; this one catches a
// race where an adversary creates a symlink at a parent component between
// the first check and the os.MkdirAll call.
func fetchContentsConfineParent(destPath string) (resolvedParent string, err error) {
	parent := filepath.Dir(destPath)
	resolvedParent, err = filepath.EvalSymlinks(parent)
	if err != nil {
		return "", fmt.Errorf("fp: resolve dest parent: %w", err)
	}
	if confineErr := confineToAllowedRoots(resolvedParent); confineErr != nil {
		return "", fmt.Errorf("fp: dest parent resolved outside allowed staging roots: %w", os.ErrPermission)
	}
	return resolvedParent, nil
}

// RootContainerID is the sentinel identifier for a domain's root
// container. It maps to NSFileProviderItemIdentifier.rootContainer on the
// Swift side and to "list this account's workspaces" here.
const RootContainerID = ".rootContainer"

// Item is the wire shape the extension turns into an NSFileProviderItem.
// The JSON tags are part of the IPC contract; keep them stable.
type Item struct {
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

// Envelope is the result shape every fp IPC method returns. Exactly one
// of Items / Item / Error is set. It deliberately mirrors the JSON the cgo
// bridge used to return so the File Provider Extension decodes one shape
// regardless of transport — collapsing what used to be two error mappings
// (cgo envelope + JSON-RPC error) into one.
type Envelope struct {
	Items []Item        `json:"items,omitempty"`
	Item  *Item         `json:"item,omitempty"`
	Error *ErrorPayload `json:"error,omitempty"`
}

// ErrorPayload carries a stable [ErrorCode] the extension switches on plus
// the unfiltered Go error string (for logs, not end-user display).
type ErrorPayload struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ErrorEnvelope wraps err as an [Envelope] with the classified code.
func ErrorEnvelope(err error) Envelope {
	return Envelope{Error: &ErrorPayload{Code: string(Classify(err)), Message: err.Error()}}
}

// Engine is the subset of [sync.Engine] the File Provider operations need.
// *sync.Engine satisfies it; tests can stub it.
type Engine interface {
	ListWorkspaces(ctx context.Context, alias string) ([]fabric.Workspace, error)
	ListItems(ctx context.Context, alias, workspaceID string) ([]fabric.Item, error)
	Enumerate(ctx context.Context, k cache.Key) ([]cache.Entry, error)
	Open(ctx context.Context, k cache.Key) (io.ReadCloser, error)
	Put(ctx context.Context, k cache.Key, content io.Reader, size int64) error
	Delete(ctx context.Context, k cache.Key) error
	Mkdir(ctx context.Context, k cache.Key) error
}

// MetaCache is the subset of [cache.Cache] the operations read for
// metadata-only item lookups. *cache.Cache satisfies it.
type MetaCache interface {
	Get(ctx context.Context, k cache.Key) (cache.Entry, error)
}

// Service binds the engine and cache the operations run against. One
// Service is shared by every IPC handler in the daemon.
type Service struct {
	Engine Engine
	Cache  MetaCache
}

// --- identifier parsing -----------------------------------------------------

type scopeKind int

const (
	scopeRoot      scopeKind = iota // "" / ".rootContainer" -> list workspaces
	scopeWorkspace                  // "<wsId>"              -> list items
	scopeItem                       // "<wsId>/<itemId>"     -> item root
	scopePath                       // "<wsId>/<itemId>/<p>" -> item subpath
)

type scope struct {
	kind      scopeKind
	workspace string
	item      string
	path      string
}

// parseIdentifier splits an identifier into its components. The grammar is
// deliberately strict: any identifier with an empty segment (double slash,
// leading slash, trailing slash producing an empty item/workspace) is
// rejected so callers surface noSuchItem rather than a Fabric call with an
// empty ID.
//
//	""                  -> scopeRoot
//	".rootContainer"    -> scopeRoot
//	"<ws>"              -> scopeWorkspace
//	"<ws>/<item>"       -> scopeItem
//	"<ws>/<item>/<p>"   -> scopePath  (p may be empty for the item root)
func parseIdentifier(id string) (scope, error) {
	switch id {
	case "", RootContainerID:
		return scope{kind: scopeRoot}, nil
	}
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
	return scope{}, fmt.Errorf("invalid identifier %q", id)
}

// --- operations -------------------------------------------------------------

// enumeratePageSize is the maximum number of items returned in a single
// fp.enumerate response page. 1000 items × ~800 bytes each ≈ 800 KiB,
// safely under the 1 MiB IPC frame cap (ipc.MaxFrameSize).
const enumeratePageSize = 1000

// EnumeratePage is the result of a paged enumeration.
//
// Cursor scheme: the cursor is an opaque base64-encoded decimal offset into
// the sorted child list. "Opaque" means the Swift caller must not parse or
// construct it, only echo it back verbatim. An empty cursor means "start from
// the beginning"; an empty NextCursor means "this is the last page".
type EnumeratePage struct {
	Items      []Item
	NextCursor string // empty when no more pages remain
}

// EnumeratePaged returns one page of the children of identifier, starting at
// the position encoded in cursor (empty = first page). The result includes a
// NextCursor token that the caller passes back to fetch the next page.
func (s Service) EnumeratePaged(ctx context.Context, alias, identifier, cursor string) (EnumeratePage, error) {
	all, err := s.Enumerate(ctx, alias, identifier)
	if err != nil {
		return EnumeratePage{}, err
	}

	offset := 0
	if cursor != "" {
		decoded, decErr := base64.StdEncoding.DecodeString(cursor)
		if decErr != nil {
			return EnumeratePage{}, fmt.Errorf("fp.EnumeratePaged: invalid cursor: %w", decErr)
		}
		var n int
		if _, scanErr := fmt.Sscanf(string(decoded), "%d", &n); scanErr != nil {
			return EnumeratePage{}, fmt.Errorf("fp.EnumeratePaged: invalid cursor value: %w", scanErr)
		}
		offset = n
	}

	if offset < 0 || offset > len(all) {
		return EnumeratePage{}, fmt.Errorf("fp.EnumeratePaged: cursor offset %d out of range [0, %d]", offset, len(all))
	}

	page := all[offset:]
	var nextCursor string
	if len(page) > enumeratePageSize {
		page = page[:enumeratePageSize]
		nextOffset := offset + enumeratePageSize
		nextCursor = base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("%d", nextOffset)))
	}

	return EnumeratePage{Items: page, NextCursor: nextCursor}, nil
}

// Enumerate lists the children of the container named by identifier.
func (s Service) Enumerate(ctx context.Context, alias, identifier string) ([]Item, error) {
	sc, err := parseIdentifier(identifier)
	if err != nil {
		return nil, err
	}
	switch sc.kind {
	case scopeRoot:
		ws, err := s.Engine.ListWorkspaces(ctx, alias)
		if err != nil {
			return nil, err
		}
		out := make([]Item, 0, len(ws))
		for _, w := range ws {
			out = append(out, workspaceToItem(w))
		}
		return out, nil
	case scopeWorkspace:
		items, err := s.Engine.ListItems(ctx, alias, sc.workspace)
		if err != nil {
			return nil, err
		}
		out := make([]Item, 0, len(items))
		for _, it := range items {
			// Skip the SQL analytics endpoint Fabric auto-creates next to
			// every Lakehouse: it carries the Lakehouse's display name (so
			// it collides in Finder) but exposes no OneLake file tree.
			if it.Type == "SQLEndpoint" {
				continue
			}
			out = append(out, itemToItem(it))
		}
		return out, nil
	case scopeItem, scopePath:
		entries, err := s.Engine.Enumerate(ctx, cache.Key{
			AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path,
		})
		if err != nil {
			return nil, err
		}
		out := make([]Item, 0, len(entries))
		for _, e := range entries {
			out = append(out, entryToItem(e))
		}
		return out, nil
	}
	return nil, fmt.Errorf("unknown scope kind %v", sc.kind)
}

// Item returns the synthetic item for one identifier without remote calls,
// consulting the cache opportunistically and stubbing on a miss so Finder
// never sees noSuchItem before the first enumerate lands.
func (s Service) Item(ctx context.Context, alias, identifier string) (Item, error) {
	sc, err := parseIdentifier(identifier)
	if err != nil {
		return Item{}, err
	}
	switch sc.kind {
	case scopeRoot:
		return Item{
			Identifier:      RootContainerID,
			Filename:        "OneLake — " + alias,
			IsDir:           true,
			ContentVersion:  fallbackVersion(alias, 0, time.Time{}),
			MetadataVersion: fallbackVersion(alias, 0, time.Time{}),
			Capabilities:    []string{"read", "enumerate"},
		}, nil
	case scopeWorkspace:
		k := cache.Key{
			AccountAlias: alias,
			WorkspaceID:  syncpkg.VirtualWorkspaceID,
			ItemID:       syncpkg.VirtualWorkspaceID,
			Path:         sc.workspace,
		}
		if entry, err := s.Cache.Get(ctx, k); err == nil {
			return dirItem(sc.workspace, RootContainerID, entry), nil
		}
		return stubDir(sc.workspace, RootContainerID, sc.workspace), nil
	case scopeItem:
		k := cache.Key{
			AccountAlias: alias,
			WorkspaceID:  sc.workspace,
			ItemID:       syncpkg.VirtualItemID,
			Path:         sc.item,
		}
		id := sc.workspace + "/" + sc.item
		if entry, err := s.Cache.Get(ctx, k); err == nil {
			return dirItem(id, sc.workspace, entry), nil
		}
		return stubDir(id, sc.workspace, sc.item), nil
	case scopePath:
		entry, err := s.Cache.Get(ctx, cache.Key{
			AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path,
		})
		if err != nil {
			return Item{}, err
		}
		return entryToItem(entry), nil
	}
	return Item{}, fmt.Errorf("unknown scope kind %v", sc.kind)
}

// FetchContents downloads the file named by identifier (via the engine,
// which caches it in the shared blob store) and copies it to destPath,
// which MUST be a location both the daemon and the calling extension can
// access (the App Group container). Returns the item metadata.
func (s Service) FetchContents(ctx context.Context, alias, identifier, destPath string) (Item, error) {
	sc, err := parseIdentifier(identifier)
	if err != nil {
		return Item{}, err
	}
	if sc.kind != scopePath {
		return Item{}, errNoSuchItem("fetch requires a file identifier")
	}
	if destPath == "" {
		return Item{}, errors.New("fp.FetchContents: empty destination path")
	}
	if err := confineToAllowedRoots(destPath); err != nil {
		return Item{}, fmt.Errorf("fp.FetchContents: %w", err)
	}
	k := cache.Key{AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path}
	rc, err := s.Engine.Open(ctx, k)
	if err != nil {
		return Item{}, err
	}
	defer func() { _ = rc.Close() }()

	if err := os.MkdirAll(filepath.Dir(destPath), 0o700); err != nil {
		return Item{}, fmt.Errorf("fp.FetchContents: mkdir dest: %w", err)
	}
	// Second confinement check: the parent directory now exists, so
	// EvalSymlinks can resolve it. This catches a TOCTOU race where an
	// adversary inserts a symlink at a parent component between the first
	// confineToAllowedRoots call above and the os.MkdirAll call just above.
	// We then open using the resolved parent path + O_NOFOLLOW so that even
	// the final filename component cannot be redirected via a symlink.
	resolvedParent, confineErr := fetchContentsConfineParent(destPath)
	if confineErr != nil {
		return Item{}, fmt.Errorf("fp.FetchContents: %w", confineErr)
	}
	safeDestPath := filepath.Join(resolvedParent, filepath.Base(destPath))
	// #nosec G304 -- path is confined to allowed App Group staging roots above (two checks).
	// O_NOFOLLOW prevents the final filename component from being a symlink.
	f, err := os.OpenFile(safeDestPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return Item{}, fmt.Errorf("fp.FetchContents: open dest: %w", err)
	}
	if _, err := io.Copy(f, rc); err != nil {
		_ = f.Close()
		_ = os.Remove(safeDestPath)
		return Item{}, fmt.Errorf("fp.FetchContents: copy: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(safeDestPath)
		return Item{}, fmt.Errorf("fp.FetchContents: close dest: %w", err)
	}

	// Return the freshest item metadata from the cache row Open populated.
	if entry, err := s.Cache.Get(ctx, k); err == nil {
		return entryToItem(entry), nil
	}
	// Cache miss is unexpected after a successful Open; synthesize a
	// minimal file item so the caller still gets a usable identifier.
	return Item{
		Identifier:       buildPathID(sc.workspace, sc.item, sc.path),
		ParentIdentifier: buildPathParentID(sc.workspace, sc.item, sc.path),
		Filename:         path.Base(sc.path),
		Capabilities:     []string{"read", "write", "delete"},
		ContentVersion:   fallbackVersion(sc.path, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(sc.path, 0, time.Time{}),
	}, nil
}

// CreateItem creates a file (from srcPath) or directory under parentID.
func (s Service) CreateItem(ctx context.Context, alias, parentID, filename string, isDir bool, srcPath string) (Item, error) {
	parent, err := parseIdentifier(parentID)
	if err != nil {
		return Item{}, err
	}
	if parent.kind != scopeItem && parent.kind != scopePath {
		return Item{}, errNoSuchItem("create requires a parent inside a Fabric item")
	}
	newPath := filename
	if parent.path != "" {
		newPath = parent.path + "/" + filename
	}
	k := cache.Key{AccountAlias: alias, WorkspaceID: parent.workspace, ItemID: parent.item, Path: newPath}

	if isDir {
		if err := s.Engine.Mkdir(ctx, k); err != nil {
			return Item{}, err
		}
	} else {
		if err := confineToAllowedRoots(srcPath); err != nil {
			return Item{}, fmt.Errorf("fp.CreateItem: %w", err)
		}
		// #nosec G304 -- path is confined to allowed App Group staging roots above.
		f, err := os.Open(srcPath)
		if err != nil {
			return Item{}, fmt.Errorf("fp.CreateItem: open src: %w", err)
		}
		info, statErr := f.Stat()
		if statErr != nil {
			_ = f.Close()
			return Item{}, fmt.Errorf("fp.CreateItem: stat src: %w", statErr)
		}
		if err := s.Engine.Put(ctx, k, f, info.Size()); err != nil {
			_ = f.Close()
			return Item{}, err
		}
		_ = f.Close()
	}
	if entry, err := s.Cache.Get(ctx, k); err == nil {
		return entryToItem(entry), nil
	}
	return syntheticItem(parent.workspace, parent.item, newPath, parentID, filename, isDir), nil
}

// ModifyItem replaces the contents of the file at identifier with srcPath.
func (s Service) ModifyItem(ctx context.Context, alias, identifier, srcPath string) (Item, error) {
	sc, err := parseIdentifier(identifier)
	if err != nil {
		return Item{}, err
	}
	if sc.kind != scopePath {
		return Item{}, errNoSuchItem("modify requires a file identifier")
	}
	if err := confineToAllowedRoots(srcPath); err != nil {
		return Item{}, fmt.Errorf("fp.ModifyItem: %w", err)
	}
	// #nosec G304 -- path is confined to allowed App Group staging roots above.
	f, err := os.Open(srcPath)
	if err != nil {
		return Item{}, fmt.Errorf("fp.ModifyItem: open src: %w", err)
	}
	info, statErr := f.Stat()
	if statErr != nil {
		_ = f.Close()
		return Item{}, fmt.Errorf("fp.ModifyItem: stat src: %w", statErr)
	}
	k := cache.Key{AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path}
	if err := s.Engine.Put(ctx, k, f, info.Size()); err != nil {
		_ = f.Close()
		return Item{}, err
	}
	_ = f.Close()
	if entry, err := s.Cache.Get(ctx, k); err == nil {
		return entryToItem(entry), nil
	}
	return entryToItem(cache.Entry{Key: k, Name: path.Base(sc.path), ContentLength: info.Size()}), nil
}

// DeleteItem removes the file or directory at identifier.
func (s Service) DeleteItem(ctx context.Context, alias, identifier string) error {
	sc, err := parseIdentifier(identifier)
	if err != nil {
		return err
	}
	if sc.kind != scopePath {
		return errNoSuchItem("delete requires an item-relative identifier")
	}
	return s.Engine.Delete(ctx, cache.Key{
		AccountAlias: alias, WorkspaceID: sc.workspace, ItemID: sc.item, Path: sc.path,
	})
}

// --- adapters ---------------------------------------------------------------

func workspaceToItem(w fabric.Workspace) Item {
	return Item{
		Identifier:       w.ID,
		ParentIdentifier: RootContainerID,
		Filename:         w.DisplayName,
		IsDir:            true,
		ContentVersion:   fallbackVersion(w.ID, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(w.DisplayName, 0, time.Time{}),
		Capabilities:     []string{"read", "enumerate"},
	}
}

func itemToItem(it fabric.Item) Item {
	return Item{
		Identifier:       it.WorkspaceID + "/" + it.ID,
		ParentIdentifier: it.WorkspaceID,
		Filename:         it.DisplayName,
		IsDir:            true,
		ContentVersion:   fallbackVersion(it.ID, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(it.DisplayName, 0, time.Time{}),
		Capabilities:     []string{"read", "enumerate"},
	}
}

func entryToItem(e cache.Entry) Item {
	ct := e.ContentType
	if ct == "" && !e.IsDir {
		ct = mime.TypeByExtension(path.Ext(e.Path))
	}
	caps := []string{"read", "write", "delete"}
	if e.IsDir {
		caps = []string{"read", "write", "delete", "enumerate", "add_subitems"}
	}
	return Item{
		Identifier:       buildPathID(e.WorkspaceID, e.ItemID, e.Path),
		ParentIdentifier: buildPathParentID(e.WorkspaceID, e.ItemID, e.Path),
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

// dirItem builds a directory item for a workspace/item row from the cache.
func dirItem(identifier, parentID string, e cache.Entry) Item {
	return Item{
		Identifier:       identifier,
		ParentIdentifier: parentID,
		Filename:         e.Name,
		IsDir:            true,
		ModificationDate: rfc3339OrEmpty(e.LastModified),
		ContentVersion:   fallbackVersion(e.Name, 0, e.SyncedAt),
		MetadataVersion:  fallbackVersion(e.Name, 0, e.SyncedAt),
		Capabilities:     []string{"read", "enumerate"},
	}
}

// stubDir builds a placeholder directory item used before the first
// enumerate populates the cache.
func stubDir(identifier, parentID, name string) Item {
	return Item{
		Identifier:       identifier,
		ParentIdentifier: parentID,
		Filename:         name,
		IsDir:            true,
		ContentVersion:   fallbackVersion(name, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(name, 0, time.Time{}),
		Capabilities:     []string{"read", "enumerate"},
	}
}

// syntheticItem builds an item for a just-created path before its cache
// row exists.
func syntheticItem(ws, item, newPath, parentID, name string, isDir bool) Item {
	caps := []string{"read", "write", "delete"}
	if isDir {
		caps = []string{"read", "write", "delete", "enumerate", "add_subitems"}
	}
	return Item{
		Identifier:       buildPathID(ws, item, newPath),
		ParentIdentifier: parentID,
		Filename:         name,
		IsDir:            isDir,
		ContentVersion:   fallbackVersion(newPath, 0, time.Time{}),
		MetadataVersion:  fallbackVersion(newPath, 0, time.Time{}),
		Capabilities:     caps,
	}
}

func buildPathID(ws, item, p string) string {
	if p == "" {
		return ws + "/" + item
	}
	return ws + "/" + item + "/" + p
}

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

func contentVersionFor(e cache.Entry) string {
	if e.Etag != "" {
		return base64.StdEncoding.EncodeToString([]byte(e.Etag))
	}
	return fallbackVersion(e.Path, e.ContentLength, e.LastModified)
}

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

func fallbackVersion(seed string, size int64, mtime time.Time) string {
	h := fnv.New64a()
	_, _ = h.Write([]byte(seed))
	_, _ = h.Write([]byte{0})
	_, _ = fmt.Fprintf(h, "%d", size)
	_, _ = h.Write([]byte{0})
	if !mtime.IsZero() {
		_, _ = h.Write([]byte(mtime.UTC().Format(time.RFC3339Nano)))
	}
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

func rfc3339OrEmpty(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// --- error classification ---------------------------------------------------

// ErrorCode is one of a fixed set the extension maps onto
// NSFileProviderError without parsing the message.
type ErrorCode string

// The fixed set of error codes the extension maps onto NSFileProviderError.
const (
	CodeNoSuchItem        ErrorCode = "noSuchItem"
	CodeNotAuthenticated  ErrorCode = "notAuthenticated"
	CodeServerBusy        ErrorCode = "serverBusy"
	CodeServerUnreachable ErrorCode = "serverUnreachable"
	CodeCannotSynchronize ErrorCode = "cannotSynchronize"
)

// errNoSuchItem returns an error that Classify maps to noSuchItem.
func errNoSuchItem(msg string) error { return fmt.Errorf("%s: %w", msg, os.ErrNotExist) }

// Classify maps a Go error to the wire ErrorCode the extension switches
// on. Classification is based exclusively on typed errors and sentinels;
// substring matching on error messages is intentionally absent because it
// misfires on filenames or error context that happen to contain status
// digits (e.g. a file named "report-404.csv").
func Classify(err error) ErrorCode {
	switch {
	// Paused capacity first: Fabric surfaces it as a 404 (DFS) or 403
	// (REST), so it must precede the generic ErrNotFound arm.
	case errors.Is(err, syncpkg.ErrWorkspacePaused),
		errors.Is(err, httpretry.ErrThrottled),
		syncpkg.IsPausedCapacityError(err):
		return CodeServerBusy
	case errors.Is(err, os.ErrNotExist),
		errors.Is(err, httpretry.ErrNotFound),
		errors.Is(err, httpretry.ErrGone):
		return CodeNoSuchItem
	case errors.Is(err, httpretry.ErrUnauthorized),
		errors.Is(err, httpretry.ErrForbidden):
		return CodeNotAuthenticated
	case syncpkg.IsOfflineError(err):
		return CodeServerUnreachable
	}
	var nerr net.Error
	if errors.As(err, &nerr) {
		return CodeServerUnreachable
	}
	return CodeCannotSynchronize
}
