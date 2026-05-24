package cli

import (
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// TestParseSize_Accepted exercises every suffix variant the user is
// likely to type, plus the no-suffix "raw bytes" form.
func TestParseSize_Accepted(t *testing.T) {
	cases := []struct {
		in   string
		want int64
	}{
		// No suffix → bytes.
		{"0", 0},
		{"1024", 1024},
		{"21474836480", 21474836480},

		// Bytes suffix.
		{"512B", 512},
		{"512 B", 512},

		// Binary suffixes.
		{"1KiB", 1024},
		{"1 KiB", 1024},
		{"1MiB", 1 << 20},
		{"10GiB", 10 * (1 << 30)},
		{"2TiB", 2 * (1 << 40)},

		// Decimal suffixes.
		{"1KB", 1000},
		{"500MB", 500 * 1000 * 1000},
		{"2GB", 2 * 1000 * 1000 * 1000},
		{"1TB", 1000 * 1000 * 1000 * 1000},

		// Shorthand (binary).
		{"5K", 5 * 1024},
		{"5M", 5 * (1 << 20)},
		{"5G", 5 * (1 << 30)},
		{"5T", 5 * (1 << 40)},

		// Case-insensitive.
		{"10gib", 10 * (1 << 30)},
		{"10gIb", 10 * (1 << 30)},
		{"1024mb", 1024 * 1000 * 1000},
	}
	for _, tc := range cases {
		got, err := parseSize(tc.in)
		if err != nil {
			t.Errorf("parseSize(%q) error: %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("parseSize(%q) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

// TestParseSize_Rejected covers shapes the parser must refuse instead of
// silently accepting.
func TestParseSize_Rejected(t *testing.T) {
	cases := []struct {
		in     string
		reason string
	}{
		{"", "empty"},
		{"   ", "whitespace only"},
		{"-1", "negative"},
		{"-10GiB", "negative with suffix"},
		{"GiB", "missing number"},
		{"10.5GiB", "decimal not allowed"},
		{"10XB", "unknown suffix"},
		{"abc", "garbage"},
		{"10 20 GiB", "two numbers"},
		// 9223372036854775808 = MaxInt64 + 1 → overflows on multiplication.
		{"9223372036854775808", "overflow bare"},
		{"9999999PiB", "overflow with suffix"},
	}
	for _, tc := range cases {
		if _, err := parseSize(tc.in); err == nil {
			t.Errorf("parseSize(%q) succeeded; expected error (%s)", tc.in, tc.reason)
		}
	}
}

// TestApplyConfig_CacheMaxSizeAcceptsHumanInput verifies that 'ofem
// config set cache.max_size 10GiB' writes the right field, and that the
// raw and friendly keys both round-trip the same value.
func TestApplyConfig_CacheMaxSizeAcceptsHumanInput(t *testing.T) {
	f := config.Default()
	if err := applyConfig(&f, "cache.max_size", "10GiB"); err != nil {
		t.Fatalf("applyConfig: %v", err)
	}
	if f.Cache.MaxSizeBytes != 10*(1<<30) {
		t.Fatalf("MaxSizeBytes = %d, want %d", f.Cache.MaxSizeBytes, 10*(1<<30))
	}

	// Reading via the raw key returns the int.
	raw, ok := lookupConfig(f, "cache.max_size_bytes")
	if !ok || raw != "10737418240" {
		t.Errorf("lookupConfig(cache.max_size_bytes) = %q, want \"10737418240\"", raw)
	}
	// Reading via the friendly key returns the formatted string.
	friendly, ok := lookupConfig(f, "cache.max_size")
	if !ok || friendly != "10.0 GiB" {
		t.Errorf("lookupConfig(cache.max_size) = %q, want \"10.0 GiB\"", friendly)
	}
}

// TestApplyConfig_CacheMaxSizeRawStillWorks confirms backwards
// compatibility: a raw int via cache.max_size_bytes parses as before.
func TestApplyConfig_CacheMaxSizeRawStillWorks(t *testing.T) {
	f := config.Default()
	if err := applyConfig(&f, "cache.max_size_bytes", "21474836480"); err != nil {
		t.Fatalf("applyConfig: %v", err)
	}
	if f.Cache.MaxSizeBytes != 21474836480 {
		t.Errorf("MaxSizeBytes = %d, want 21474836480", f.Cache.MaxSizeBytes)
	}
}

// TestApplyConfig_CacheMaxSizeKebabCase verifies that --max-size with a
// hyphen normalises to the same key as max_size with an underscore.
func TestApplyConfig_CacheMaxSizeKebabCase(t *testing.T) {
	f := config.Default()
	if err := applyConfig(&f, "cache.max-size", "1GiB"); err != nil {
		t.Fatalf("applyConfig: %v", err)
	}
	if f.Cache.MaxSizeBytes != 1<<30 {
		t.Errorf("MaxSizeBytes = %d, want %d", f.Cache.MaxSizeBytes, 1<<30)
	}
}

// TestApplyConfig_CacheMaxSizeRejectsInvalid confirms the error message
// surfaces parseSize's diagnostic.
func TestApplyConfig_CacheMaxSizeRejectsInvalid(t *testing.T) {
	f := config.Default()
	err := applyConfig(&f, "cache.max_size", "10XB")
	if err == nil {
		t.Fatal("expected error for invalid suffix")
	}
	if !strings.Contains(err.Error(), "cache.max_size") {
		t.Errorf("error %q should mention the key", err)
	}
}

// TestConfigList_MentionsMaxSizeAlias makes sure `ofem config list`
// documents the human-friendly alias so users discover it.
func TestConfigList_MentionsMaxSizeAlias(t *testing.T) {
	setupTempHome(t)
	out, err := runCache(t, nil, "config", "list")
	if err != nil {
		t.Fatalf("config list: %v\n%s", err, out)
	}
	for _, want := range []string{
		"cache.max_size_bytes",
		"cache.max_size",
		"alias of cache.max_size_bytes",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("config list output missing %q\nfull:\n%s", want, out)
		}
	}
}
