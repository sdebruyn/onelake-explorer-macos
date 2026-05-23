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
