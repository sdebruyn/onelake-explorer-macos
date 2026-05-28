package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
)

// debugRef is a parsed `alias:/workspace[/item[/path]]` reference. The
// workspace and item segments may be either a Fabric display name or a
// GUID; debugResolve turns them into the GUIDs the sync.Engine needs.
type debugRef struct {
	alias     string
	workspace string // display name or GUID, "" when only the alias was given
	item      string // display name or GUID, "" when only workspace was given
	path      string // POSIX path inside the item, "" for the item root
}

// parseDebugRef splits `alias:/workspace/item/path/...` into its parts.
// The scheme separator is the first ':'; everything after the leading
// '/' is the slash-separated workspace / item / path triple.
//
// A double slash after the colon (e.g. `alias://workspace`) is rejected
// because it silently produces an empty first segment that would be
// interpreted as a missing workspace name, masking the caller's typo.
func parseDebugRef(s string) (debugRef, error) {
	colon := strings.IndexByte(s, ':')
	if colon <= 0 {
		return debugRef{}, fmt.Errorf("expected <alias:/workspace[/item[/path]]>, got %q", s)
	}
	ref := debugRef{alias: s[:colon]}
	rest := strings.TrimPrefix(s[colon+1:], "/")
	if rest == "" {
		return ref, nil
	}
	parts := strings.SplitN(rest, "/", 3)
	// A leading double slash ("alias://workspace") strips one '/' but
	// leaves the first segment empty. Treat this as a malformed reference.
	if parts[0] == "" {
		return debugRef{}, fmt.Errorf("malformed reference %q: unexpected double slash after colon", s)
	}
	ref.workspace = parts[0]
	if len(parts) > 1 {
		ref.item = parts[1]
	}
	if len(parts) > 2 {
		ref.path = parts[2]
	}
	return ref, nil
}

// debugEngine bundles a fully-wired sync.Engine with its cache so the
// debug commands can close the cache when done.
type debugEngine struct {
	engine *sync.Engine
	cache  *cache.Cache
}

func (d *debugEngine) close() { _ = d.cache.Close() }

// newDebugEngine wires cache + auth registry + Fabric/OneLake clients +
// sync.Engine exactly like the daemon does, but for a one-shot CLI
// invocation. The CLI is unsandboxed, so config.Load / auth.NewKeychain
// resolve the real home correctly.
func newDebugEngine() (*debugEngine, error) {
	store, err := config.Load()
	if err != nil {
		return nil, fmt.Errorf("load config: %w", err)
	}
	paths := store.Paths()
	kc, err := auth.NewKeychain()
	if err != nil {
		return nil, fmt.Errorf("open keychain: %w", err)
	}
	registry := auth.NewRegistry(store, kc, auth.EntraClientID, nil)

	c, err := cache.Open(cache.Options{
		Root:         paths.CacheDir,
		MaxBlobBytes: store.Snapshot().Cache.MaxSizeBytes,
	})
	if err != nil {
		return nil, fmt.Errorf("open cache: %w", err)
	}

	gates := httpgate.DefaultRegistry()
	engine, err := sync.New(sync.Options{
		Cache: c,
		// Fabric REST needs a Power BI-audience token; OneLake DFS needs
		// the storage-audience token the registry serves by default.
		Fabric:  fabric.New(fabric.Options{TokenProvider: registry.ScopedProvider(auth.FabricScopes), Registry: gates}),
		OneLake: onelake.New(onelake.Options{TokenProvider: registry, Registry: gates}),
		Tenants: registry,
	})
	if err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("build sync engine: %w", err)
	}
	return &debugEngine{engine: engine, cache: c}, nil
}

// resolveWorkspaceID maps a display name or GUID to a workspace GUID by
// listing the alias's workspaces. A segment that already matches a
// listed ID is returned as-is.
func resolveWorkspaceID(ctx context.Context, e *sync.Engine, alias, want string) (string, error) {
	wss, err := e.ListWorkspaces(ctx, alias)
	if err != nil {
		return "", err
	}
	for _, w := range wss {
		if w.ID == want || w.DisplayName == want {
			return w.ID, nil
		}
	}
	return "", fmt.Errorf("workspace %q not found for account %q", want, alias)
}

// resolveItemID maps a display name or GUID to an item GUID by listing
// the workspace's items. A GUID match wins outright. For a display-name
// match we skip SQLEndpoint items: a Lakehouse auto-creates a same-named
// SQLEndpoint that has no OneLake file tree, so browsing it 404s. When a
// name is still ambiguous across file-bearing items we report the
// candidates so the caller can disambiguate by GUID.
func resolveItemID(ctx context.Context, e *sync.Engine, alias, workspaceID, want string) (string, error) {
	items, err := e.ListItems(ctx, alias, workspaceID)
	if err != nil {
		return "", err
	}
	var matches []fabric.Item
	for _, it := range items {
		if it.ID == want {
			return it.ID, nil
		}
		if it.DisplayName == want && it.Type != "SQLEndpoint" {
			matches = append(matches, it)
		}
	}
	switch len(matches) {
	case 0:
		return "", fmt.Errorf("item %q not found in workspace %q", want, workspaceID)
	case 1:
		return matches[0].ID, nil
	default:
		var b strings.Builder
		fmt.Fprintf(&b, "item %q is ambiguous in workspace %q; use a GUID:\n", want, workspaceID)
		for _, m := range matches {
			fmt.Fprintf(&b, "  %s (%s)\n", m.ID, m.Type)
		}
		return "", errors.New(b.String())
	}
}

// resolveKey turns a debugRef (which needs at least workspace + item)
// into the cache.Key the engine's path operations expect.
func resolveKey(ctx context.Context, e *sync.Engine, ref debugRef) (cache.Key, error) {
	wsID, err := resolveWorkspaceID(ctx, e, ref.alias, ref.workspace)
	if err != nil {
		return cache.Key{}, err
	}
	itemID, err := resolveItemID(ctx, e, ref.alias, wsID, ref.item)
	if err != nil {
		return cache.Key{}, err
	}
	return cache.Key{
		AccountAlias: ref.alias,
		WorkspaceID:  wsID,
		ItemID:       itemID,
		Path:         ref.path,
	}, nil
}

func newDebugCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "debug",
		Short:  "Internal commands for development",
		Hidden: true,
	}
	cmd.AddCommand(newDebugLsCmd(), newDebugCatCmd(), newDebugStatCmd())
	return cmd
}

func newDebugLsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ls <alias:/workspace[/item[/path]]>",
		Short: "List a OneLake path via the core library (bypasses Finder)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ref, err := parseDebugRef(args[0])
			if err != nil {
				return err
			}
			de, err := newDebugEngine()
			if err != nil {
				return err
			}
			defer de.close()

			ctx, cancel := context.WithTimeout(cmd.Context(), 30*time.Second)
			defer cancel()
			out := cmd.OutOrStdout()

			switch {
			case ref.workspace == "":
				// alias:/ -> list workspaces.
				wss, err := de.engine.ListWorkspaces(ctx, ref.alias)
				if err != nil {
					return err
				}
				for _, w := range wss {
					fmt.Fprintf(out, "%s\t%s\t(%s)\n", w.ID, w.DisplayName, w.Type)
				}
			case ref.item == "":
				// alias:/workspace -> list items.
				wsID, err := resolveWorkspaceID(ctx, de.engine, ref.alias, ref.workspace)
				if err != nil {
					return err
				}
				items, err := de.engine.ListItems(ctx, ref.alias, wsID)
				if err != nil {
					return err
				}
				for _, it := range items {
					fmt.Fprintf(out, "%s\t%s\t(%s)\n", it.ID, it.DisplayName, it.Type)
				}
			default:
				// alias:/workspace/item[/path] -> enumerate folder.
				key, err := resolveKey(ctx, de.engine, ref)
				if err != nil {
					return err
				}
				entries, err := de.engine.Enumerate(ctx, key)
				if err != nil {
					return err
				}
				for _, e := range entries {
					marker := ""
					if e.IsDir {
						marker = "/"
					}
					fmt.Fprintf(out, "%s%s\t%d\n", e.Name, marker, e.ContentLength)
				}
			}
			return nil
		},
	}
}

func newDebugCatCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "cat <alias:/workspace/item/path/file>",
		Short: "Print a OneLake file to stdout via the core library",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ref, err := parseDebugRef(args[0])
			if err != nil {
				return err
			}
			if ref.item == "" || ref.path == "" {
				return fmt.Errorf("cat needs a file path: <alias:/workspace/item/path/file>")
			}
			de, err := newDebugEngine()
			if err != nil {
				return err
			}
			defer de.close()

			ctx, cancel := context.WithTimeout(cmd.Context(), 60*time.Second)
			defer cancel()

			key, err := resolveKey(ctx, de.engine, ref)
			if err != nil {
				return err
			}
			rc, err := de.engine.Open(ctx, key)
			if err != nil {
				return err
			}
			defer func() { _ = rc.Close() }()
			if _, err := io.Copy(cmd.OutOrStdout(), rc); err != nil {
				return fmt.Errorf("stream %q: %w", ref.path, err)
			}
			return nil
		},
	}
}

func newDebugStatCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stat <alias:/workspace/item/path>",
		Short: "Show metadata for a OneLake path",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ref, err := parseDebugRef(args[0])
			if err != nil {
				return err
			}
			if ref.item == "" || ref.path == "" {
				return fmt.Errorf("stat needs a path inside an item: <alias:/workspace/item/path>")
			}
			de, err := newDebugEngine()
			if err != nil {
				return err
			}
			defer de.close()

			ctx, cancel := context.WithTimeout(cmd.Context(), 30*time.Second)
			defer cancel()

			// stat resolves the parent folder and finds the entry by name;
			// the engine has no single-item metadata call, and enumerating
			// the parent reuses the same cache-backed path the mount uses.
			key, err := resolveKey(ctx, de.engine, ref)
			if err != nil {
				return err
			}
			parent := key
			parent.Path = parentDir(key.Path)
			entries, err := de.engine.Enumerate(ctx, parent)
			if err != nil {
				return err
			}
			name := baseName(key.Path)
			out := cmd.OutOrStdout()
			for _, e := range entries {
				if e.Name != name {
					continue
				}
				fmt.Fprintf(out, "name:    %s\n", e.Name)
				fmt.Fprintf(out, "dir:     %t\n", e.IsDir)
				fmt.Fprintf(out, "size:    %d\n", e.ContentLength)
				fmt.Fprintf(out, "etag:    %s\n", e.Etag)
				fmt.Fprintf(out, "type:    %s\n", e.ContentType)
				fmt.Fprintf(out, "mtime:   %s\n", e.LastModified.Format(time.RFC3339))
				return nil
			}
			return fmt.Errorf("path %q not found under %q", name, parent.Path)
		},
	}
}

// parentDir returns the POSIX parent of an item-relative path, or "" for
// a top-level entry.
func parentDir(p string) string {
	i := strings.LastIndexByte(p, '/')
	if i < 0 {
		return ""
	}
	return p[:i]
}

// baseName returns the final path segment.
func baseName(p string) string {
	i := strings.LastIndexByte(p, '/')
	if i < 0 {
		return p
	}
	return p[i+1:]
}
