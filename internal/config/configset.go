package config

import (
	"fmt"
	"strconv"
	"strings"
)

// ApplyConfig applies key=value to f. The key is normalised (lowercased,
// dashes treated as underscores) so "cache.max-size-gb" and
// "cache.max_size_gb" are equivalent. It returns an error for unknown
// keys or invalid values.
//
// Invoked from the daemon's config.set IPC handler (which the menu bar
// app calls from CoreBridge.configSet) so the validation and normalisation
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
				return fmt.Errorf("no account with alias %q", value)
			}
		}
		f.DefaultAccount = value
	case "cache.max_size_gb":
		gb, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return fmt.Errorf("cache.max_size_gb: invalid integer %q", value)
		}
		if gb < MinCacheSizeGB || gb > MaxCacheSizeGB {
			return fmt.Errorf("cache.max_size_gb: %d out of range [%d, %d]",
				gb, MinCacheSizeGB, MaxCacheSizeGB)
		}
		f.Cache.MaxSizeGB = gb
		// Clear any lingering legacy field so the next Save emits only
		// the canonical max_size_gb key.
		f.Cache.MaxSizeBytes = 0
	case "net.max_concurrent_uploads_per_account":
		n, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return fmt.Errorf("net.max_concurrent_uploads_per_account: invalid integer %q", value)
		}
		if n < MinNetConcurrentUploadsPerAccount || n > MaxNetConcurrentUploadsPerAccount {
			return fmt.Errorf("net.max_concurrent_uploads_per_account: %d out of range [%d, %d]",
				n, MinNetConcurrentUploadsPerAccount, MaxNetConcurrentUploadsPerAccount)
		}
		f.Net.MaxConcurrentUploadsPerAccount = n
	case "net.max_concurrent_downloads_per_account":
		n, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return fmt.Errorf("net.max_concurrent_downloads_per_account: invalid integer %q", value)
		}
		if n < MinNetConcurrentDownloadsPerAccount || n > MaxNetConcurrentDownloadsPerAccount {
			return fmt.Errorf("net.max_concurrent_downloads_per_account: %d out of range [%d, %d]",
				n, MinNetConcurrentDownloadsPerAccount, MaxNetConcurrentDownloadsPerAccount)
		}
		f.Net.MaxConcurrentDownloadsPerAccount = n
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
