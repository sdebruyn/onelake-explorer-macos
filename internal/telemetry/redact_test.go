package telemetry

import "testing"

func TestHashAlias_Stable(t *testing.T) {
	t.Parallel()
	a := HashAlias("work")
	b := HashAlias("work")
	if a == "" {
		t.Fatal("hash should not be empty")
	}
	if a != b {
		t.Errorf("hash not stable: %q vs %q", a, b)
	}
	if len(a) != 8 {
		t.Errorf("hash length = %d, want 8", len(a))
	}
}

func TestHashAlias_DifferentInputsDiffer(t *testing.T) {
	t.Parallel()
	if HashAlias("work") == HashAlias("home") {
		t.Error("different aliases hashed to the same value")
	}
}

func TestHashAlias_Empty(t *testing.T) {
	t.Parallel()
	if got := HashAlias(""); got != "" {
		t.Errorf("HashAlias(\"\") = %q, want \"\"", got)
	}
}

func TestSafeErrorCode(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		in   string
		want string
	}{
		"empty":         {"", ""},
		"clean":         {"AADSTS50079", "AADSTS50079"},
		"too-long":      {"X12345678901234567890123456789012345", "redacted"},
		"upn-like":      {"user@example.com", "redacted"},
		"unicode":       {"café", "redacted"},
		"control-chars": {"line1\nline2", "redacted"},
		"path-like":     {"Sales/budget_2026.csv", "redacted"},
		"backslash":     {"a\\b", "redacted"},
		"space":         {"server busy", "redacted"},
		"max-len-32":    {"abcdefghijabcdefghijabcdefghij12", "abcdefghijabcdefghijabcdefghij12"},
		"over-max-len":  {"abcdefghijabcdefghijabcdefghij123", "redacted"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := SafeErrorCode(tc.in); got != tc.want {
				t.Errorf("SafeErrorCode(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestScrubProperty(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		in   string
		want string
	}{
		"empty":          {"", ""},
		"tenant-guid":    {"9064c167-4885-40ef-9f34-1853218aea86", "9064c167-4885-40ef-9f34-1853218aea86"},
		"alias-hash":     {"a1b2c3d4", "a1b2c3d4"},
		"event-name":     {"folder_list", "folder_list"},
		"bool":           {"true", "true"},
		"dotted":         {"2026.05.1", "2026.05.1"},
		"file-path":      {"Files/raw/sales-2026.csv", "redacted"},
		"windows-path":   {"C:\\Users\\sam", "redacted"},
		"upn":            {"sam@debruyn.dev", "redacted"},
		"workspace-name": {"My Workspace", "redacted"},
		"non-ascii":      {"wörkspace", "redacted"},
		"over-max":       {"012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678", "redacted"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := scrubProperty(tc.in); got != tc.want {
				t.Errorf("scrubProperty(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestSplitFields_RedactsLeakedValues is the boundary guarantee: even when
// a caller stuffs a file path, UPN, or workspace name into CommonProps or
// the error code, splitFields must not emit it verbatim.
func TestSplitFields_RedactsLeakedValues(t *testing.T) {
	t.Parallel()
	ev := Event{
		Name:             "file_download",
		TenantID:         "9064c167-4885-40ef-9f34-1853218aea86",
		AccountAliasHash: "a1b2c3d4",
		ErrorCode:        "Sales/budget_2026.csv",
		CommonProps: map[string]string{
			"leakedPath":      "Files/raw/sales-2026.csv",
			"leakedUPN":       "sam@debruyn.dev",
			"leakedWorkspace": "My Workspace",
		},
	}
	props, _ := splitFields(ev)

	// Legitimate values pass through.
	if props["tenantId"] != ev.TenantID {
		t.Errorf("tenantId = %q, want %q", props["tenantId"], ev.TenantID)
	}
	if props["event"] != "file_download" {
		t.Errorf("event = %q, want file_download", props["event"])
	}
	// Anything carrying a separator / space / '@' is redacted.
	for _, k := range []string{"errorCode", "leakedPath", "leakedUPN", "leakedWorkspace"} {
		if props[k] != "redacted" {
			t.Errorf("props[%q] = %q, want \"redacted\"", k, props[k])
		}
	}
}
