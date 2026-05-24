package cli

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "Inspect and modify OFEM configuration",
	}
	cmd.AddCommand(newConfigGetCmd())
	cmd.AddCommand(newConfigSetCmd())
	cmd.AddCommand(newConfigListCmd())
	return cmd
}

func newConfigListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "Print all configurable keys and their current values",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			f := store.Snapshot()
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "telemetry                       = %s\n", boolWord(f.Telemetry))
			fmt.Fprintf(out, "default_account                 = %q\n", f.DefaultAccount)
			fmt.Fprintf(out, "cache.max_size_bytes            = %d\n", f.Cache.MaxSizeBytes)
			fmt.Fprintf(out, "cache.max_size                  = %s   # alias of cache.max_size_bytes, accepts 10GiB / 500MB / etc.\n", humanBytes(f.Cache.MaxSizeBytes))
			fmt.Fprintf(out, "net.max_concurrency_per_account = %d\n", f.Net.MaxConcurrencyPerAccount)
			fmt.Fprintf(out, "log.level                       = %q\n", f.Log.Level)
			return nil
		},
	}
}

func newConfigGetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "get <key>",
		Short: "Print a single config value",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			val, ok := lookupConfig(store.Snapshot(), args[0])
			if !ok {
				return fmt.Errorf("unknown config key %q", args[0])
			}
			fmt.Fprintln(cmd.OutOrStdout(), val)
			return nil
		},
	}
}

func newConfigSetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "set <key> <value>",
		Short: "Update a config value and persist to disk",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			key, value := args[0], args[1]
			store, err := config.Load()
			if err != nil {
				return err
			}
			var setErr error
			store.Update(func(f *config.File) {
				setErr = applyConfig(f, key, value)
			})
			if setErr != nil {
				return setErr
			}
			if err := store.Save(); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s = %s\n", key, value)
			return nil
		},
	}
}

func lookupConfig(f config.File, key string) (string, bool) {
	switch normalizeKey(key) {
	case "telemetry":
		return boolWord(f.Telemetry), true
	case "default_account":
		return f.DefaultAccount, true
	case "cache.max_size_bytes":
		return strconv.FormatInt(f.Cache.MaxSizeBytes, 10), true
	case "cache.max_size":
		return humanBytes(f.Cache.MaxSizeBytes), true
	case "net.max_concurrency_per_account":
		return strconv.Itoa(f.Net.MaxConcurrencyPerAccount), true
	case "log.level":
		return f.Log.Level, true
	}
	return "", false
}

func applyConfig(f *config.File, key, value string) error {
	switch normalizeKey(key) {
	case "telemetry":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		f.Telemetry = v
	case "default_account":
		if value != "" {
			if _, ok := f.Accounts[value]; !ok {
				return fmt.Errorf("no account with alias %q (run `ofem account list`)", value)
			}
		}
		f.DefaultAccount = value
	case "cache.max_size_bytes", "cache.max_size":
		// Both keys write to Cache.MaxSizeBytes; the parser accepts either
		// a raw integer (the historical shape) or a human-friendly value
		// like "10GiB", "500MB", "1024MiB".
		n, err := parseSize(value)
		if err != nil {
			return fmt.Errorf("%s: %w", normalizeKey(key), err)
		}
		f.Cache.MaxSizeBytes = n
	case "net.max_concurrency_per_account":
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 32 {
			return fmt.Errorf("net.max_concurrency_per_account must be between 1 and 32")
		}
		f.Net.MaxConcurrencyPerAccount = n
	case "log.level":
		switch strings.ToLower(value) {
		case "debug", "info", "warn", "error":
			f.Log.Level = strings.ToLower(value)
		default:
			return fmt.Errorf("log.level must be debug|info|warn|error")
		}
	default:
		return fmt.Errorf("unknown config key %q", key)
	}
	return nil
}

// normalizeKey lower-cases the key and treats "-" and "_" interchangeably
// so `cache.max-size` and `cache.max_size` are the same setting. The
// underlying TOML/Go field name still uses underscores.
func normalizeKey(key string) string {
	return strings.ReplaceAll(strings.ToLower(key), "-", "_")
}

func parseBool(v string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "on", "yes":
		return true, nil
	case "0", "false", "off", "no":
		return false, nil
	}
	return false, fmt.Errorf("invalid boolean %q (use on/off, true/false, 1/0)", v)
}

// sizeUnits is the suffix → multiplier table parseSize consults. Decimal
// units use base 10 (1 KB = 1000 B), binary units use base 1024
// (1 KiB = 1024 B). A bare "B" or no suffix at all means bytes.
//
// The shorthand "K"/"M"/"G"/"T" is treated as the binary form to match
// what most macOS tools (`du -h`, Finder) show; that's also what the
// user expects when they type `10G`.
var sizeUnits = []struct {
	suffix string
	mult   int64
}{
	{"KIB", 1 << 10},
	{"MIB", 1 << 20},
	{"GIB", 1 << 30},
	{"TIB", 1 << 40},
	{"KB", 1000},
	{"MB", 1000 * 1000},
	{"GB", 1000 * 1000 * 1000},
	{"TB", 1000 * 1000 * 1000 * 1000},
	{"K", 1 << 10},
	{"M", 1 << 20},
	{"G", 1 << 30},
	{"T", 1 << 40},
	{"B", 1},
}

// parseSize converts a human-friendly size string into bytes. Accepted
// shapes are e.g. "10GiB", "500 MB", "1024MiB", "2048" (bare bytes),
// "0" (no eviction). Whitespace is tolerated; matching is
// case-insensitive. Negative inputs and overflow are rejected.
func parseSize(s string) (int64, error) {
	raw := strings.TrimSpace(s)
	if raw == "" {
		return 0, errors.New("size cannot be empty")
	}
	if strings.HasPrefix(raw, "-") {
		return 0, fmt.Errorf("size must be non-negative, got %q", s)
	}

	upper := strings.ToUpper(raw)

	// Find the longest matching suffix (so "KIB" wins over "K").
	var (
		multiplier int64 = 1
		digitsEnd        = len(raw)
	)
	for _, u := range sizeUnits {
		if strings.HasSuffix(upper, u.suffix) {
			multiplier = u.mult
			digitsEnd = len(raw) - len(u.suffix)
			break
		}
	}

	numberPart := strings.TrimSpace(raw[:digitsEnd])
	if numberPart == "" {
		return 0, fmt.Errorf("missing numeric part in %q", s)
	}

	n, err := strconv.ParseInt(numberPart, 10, 64)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("invalid size %q", s)
	}

	// Multiplication overflow check: bail before int64 wraps around.
	if multiplier != 0 && n > math.MaxInt64/multiplier {
		return 0, fmt.Errorf("size %q overflows int64", s)
	}
	return n * multiplier, nil
}
