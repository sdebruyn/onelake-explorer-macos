package config

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
)

// ApplyConfig applies key=value to f. The key is normalised (lowercased,
// dashes treated as underscores) so "cache.max-size" and "cache.max_size"
// are equivalent. It returns an error for unknown keys or invalid values.
//
// This function is shared between the CLI's `ofem config set` command and
// the daemon's config.set IPC handler so the validation and normalisation
// logic stays in one place.
func ApplyConfig(f *File, key, value string) error {
	switch NormalizeConfigKey(key) {
	case "telemetry":
		v, err := ParseConfigBool(value)
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
		n, err := ParseConfigSize(value)
		if err != nil {
			return fmt.Errorf("%s: %w", NormalizeConfigKey(key), err)
		}
		f.Cache.MaxSizeBytes = n
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

// NormalizeConfigKey lower-cases the key and treats "-" and "_"
// interchangeably so "cache.max-size" and "cache.max_size" map to the
// same setting. The underlying TOML/Go field names use underscores.
func NormalizeConfigKey(key string) string {
	return strings.ReplaceAll(strings.ToLower(key), "-", "_")
}

// ParseConfigBool accepts human-friendly boolean representations:
// "1", "true", "on", "yes" → true; "0", "false", "off", "no" → false.
func ParseConfigBool(v string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "on", "yes":
		return true, nil
	case "0", "false", "off", "no":
		return false, nil
	}
	return false, fmt.Errorf("invalid boolean %q (use on/off, true/false, 1/0)", v)
}

// configSizeUnits is the suffix → multiplier table ParseConfigSize
// consults. Decimal units use base 10 (1 KB = 1000 B), binary units use
// base 1024 (1 KiB = 1024 B). A bare "B" or no suffix at all means bytes.
//
// The shorthand "K"/"M"/"G"/"T" is treated as the binary form to match
// what most macOS tools (du -h, Finder) show.
var configSizeUnits = []struct {
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

// ParseConfigSize converts a human-friendly size string into bytes. Accepted
// shapes include "10GiB", "500 MB", "1024MiB", "2048" (bare bytes), and
// "0" (no eviction limit). Whitespace is tolerated; matching is
// case-insensitive. Negative inputs and overflow are rejected.
func ParseConfigSize(s string) (int64, error) {
	raw := strings.TrimSpace(s)
	if raw == "" {
		return 0, errors.New("size cannot be empty")
	}
	if strings.HasPrefix(raw, "-") {
		return 0, fmt.Errorf("size must be non-negative, got %q", s)
	}

	upper := strings.ToUpper(raw)

	var (
		multiplier int64 = 1
		digitsEnd        = len(raw)
	)
	for _, u := range configSizeUnits {
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

	if multiplier != 0 && n > math.MaxInt64/multiplier {
		return 0, fmt.Errorf("size %q overflows int64", s)
	}
	return n * multiplier, nil
}
