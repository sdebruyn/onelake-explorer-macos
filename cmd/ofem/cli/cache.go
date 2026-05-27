// Package cli — cache subcommands.
//
// `ofem cache` is the user-facing surface for inspecting and managing
// the local OneLake blob cache. The cache itself is owned by the cache
// package (see internal/cache); these commands are a thin wrapper that
// opens the cache read-write, runs one operation, and prints a result.
//
// The daemon may also be holding the SQLite store open at the same time.
// modernc.org/sqlite + WAL mode handle that fine: writes serialise via
// the busy_timeout pragma, and Wipe/Evict both run inside short
// transactions.
package cli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// newCacheCmd builds the `ofem cache` command group.
func newCacheCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "cache",
		Short: "Inspect and manage the local OneLake blob cache",
		Long: `Inspect and manage the local OneLake blob cache.

The cache lives under ~/Library/Group Containers/group.dev.debruyn.ofem/cache
and is shared with the background daemon and the File Provider Extension.
Use 'ofem cache size' to see how much disk the cached blobs occupy,
'ofem cache clear' to drop them all, and 'ofem cache evict' to run a
manual LRU eviction down to the configured limit (see 'ofem config get
cache.max_size').`,
	}
	cmd.AddCommand(newCacheSizeCmd())
	cmd.AddCommand(newCacheClearCmd())
	cmd.AddCommand(newCacheEvictCmd())
	return cmd
}

// newCacheSizeCmd prints how much disk the cached blobs occupy and the
// configured upper bound. Opens the cache read-only.
func newCacheSizeCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "size",
		Short: "Show current cache usage and the configured limit",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			f := store.Snapshot()
			paths := store.Paths()
			out := cmd.OutOrStdout()

			// If the cache has never been opened (no daemon ever ran) we
			// don't want to create directory side-effects just to print
			// "0 B" — print and return early.
			count, used, err := readCacheUsage(cmd.Context(), paths.CacheDir, f.Cache.MaxSizeBytes)
			if err != nil {
				return err
			}

			fmt.Fprintf(out, "Cache:     %s\n", paths.CacheDir)
			fmt.Fprintf(out, "Used:      %s\n", humanBytes(used))
			fmt.Fprintf(out, "Limit:     %s\n", limitOrUnlimited(f.Cache.MaxSizeBytes))
			fmt.Fprintf(out, "Blobs:     %d\n", count)
			return nil
		},
	}
}

// newCacheClearCmd deletes every blob from the cache. Metadata rows
// survive — the sync engine still needs them — but the blob_sha256 /
// blob_size columns are cleared so the row reads back as "not cached".
func newCacheClearCmd() *cobra.Command {
	var yes bool
	cmd := &cobra.Command{
		Use:   "clear",
		Short: "Delete every blob from the local cache",
		Long: `Delete every blob from the local cache.

Metadata rows survive (the sync engine still needs them to track what
exists remotely); only the cached file contents are removed. The next
access re-downloads the bytes from OneLake.

Prompts for confirmation unless --yes is given.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			paths := store.Paths()
			out := cmd.OutOrStdout()

			if !yes {
				ok, err := confirm(cmd.InOrStdin(), out,
					fmt.Sprintf("Clear every cached blob under %s? [y/N]: ", paths.CacheDir),
				)
				if err != nil {
					return err
				}
				if !ok {
					fmt.Fprintln(out, "Aborted.")
					return nil
				}
			}

			c, err := cache.Open(cache.Options{
				Root:         paths.CacheDir,
				MaxBlobBytes: store.Snapshot().Cache.MaxSizeBytes,
			})
			if err != nil {
				return fmt.Errorf("open cache: %w", err)
			}
			defer func() { _ = c.Close() }()

			count, reclaimed, err := c.Wipe(cmd.Context())
			if err != nil {
				return fmt.Errorf("wipe cache: %w", err)
			}
			slog.Info("cache cleared via CLI",
				slog.Int("blobs", count),
				slog.Int64("bytes", reclaimed),
			)
			fmt.Fprintf(out, "Cleared %d blob(s), reclaimed %s.\n", count, humanBytes(reclaimed))
			return nil
		},
	}
	cmd.Flags().BoolVarP(&yes, "yes", "y", false, "skip the interactive confirmation")
	return cmd
}

// newCacheEvictCmd manually runs LRU eviction down to cache.max_size_bytes.
// Useful right after the user lowers the limit — the daemon will get
// around to it eventually, but this gives them an immediate result.
func newCacheEvictCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "evict",
		Short: "Run LRU eviction down to the configured cache.max_size",
		Long: `Run a one-shot LRU eviction pass. Drops the least-recently-used
cached blobs until the total bytes fall at or below cache.max_size_bytes.

When cache.max_size_bytes is 0 ("unlimited") eviction is a no-op.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			f := store.Snapshot()
			paths := store.Paths()
			out := cmd.OutOrStdout()

			c, err := cache.Open(cache.Options{
				Root:         paths.CacheDir,
				MaxBlobBytes: f.Cache.MaxSizeBytes,
			})
			if err != nil {
				return fmt.Errorf("open cache: %w", err)
			}
			defer func() { _ = c.Close() }()

			evicted, reclaimed, err := c.EvictToLimit(cmd.Context())
			if err != nil {
				return fmt.Errorf("evict: %w", err)
			}
			slog.Info("cache evicted via CLI",
				slog.Int("blobs", evicted),
				slog.Int64("bytes", reclaimed),
			)
			fmt.Fprintf(out, "Evicted %d blob(s), reclaimed %s.\n", evicted, humanBytes(reclaimed))
			return nil
		},
	}
}

// readCacheUsage opens the cache (if its directory already exists) and
// returns its blob count and on-disk bytes. When the directory does not
// exist yet — typical on a fresh install where no daemon has ever run —
// it returns (0, 0, nil) so `ofem cache size` prints zeros instead of
// creating the cache as a side effect.
func readCacheUsage(ctx context.Context, root string, maxBytes int64) (count int, bytes int64, err error) {
	if !directoryExists(root) {
		return 0, 0, nil
	}
	c, err := cache.Open(cache.Options{Root: root, MaxBlobBytes: maxBytes})
	if err != nil {
		return 0, 0, fmt.Errorf("open cache: %w", err)
	}
	defer func() { _ = c.Close() }()
	return c.DiskUsage(ctx)
}

// confirm prints prompt to out, reads one line from in and returns true
// when the user answered yes (y / yes, case-insensitive). EOF or any
// other answer is treated as "no" — the safe default for destructive
// commands.
func confirm(in io.Reader, out io.Writer, prompt string) (bool, error) {
	fmt.Fprint(out, prompt)
	reader := bufio.NewReader(in)
	line, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return false, fmt.Errorf("read confirmation: %w", err)
	}
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true, nil
	}
	return false, nil
}

// limitOrUnlimited formats max for display: zero means "no eviction
// limit", everything else is rendered through humanBytes.
func limitOrUnlimited(max int64) string {
	if max == 0 {
		return "unlimited"
	}
	return humanBytes(max)
}

// directoryExists reports whether path is an existing directory. Errors
// other than os.ErrNotExist (e.g. permission denied) are treated as
// "exists" so the caller surfaces them on the subsequent open instead
// of silently returning zeros.
func directoryExists(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return !os.IsNotExist(err)
	}
	return st.IsDir()
}
