package telemetry

import (
	"crypto/sha256"
	"encoding/hex"
)

// HashAlias returns the first 8 hex chars of sha256(alias). The empty
// string maps to the empty string so callers can pass through a missing
// alias without branching.
func HashAlias(alias string) string {
	if alias == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(alias))
	return hex.EncodeToString(sum[:])[:8]
}

// safeErrorCodeMaxLen caps the length of an error code we are willing to
// forward to telemetry. docs/telemetry.md sets the schema cap at 32
// characters; anything longer is treated as suspicious free text.
const safeErrorCodeMaxLen = 32

// maxPropertyLen bounds any single telemetry property value. Generous
// enough for the longest legitimate value (a tenant GUID is 36 chars),
// tight enough that free text — a path, a UPN, an error message — does
// not sail through on length alone.
const maxPropertyLen = 128

// safePropertyByte reports whether c is in the telemetry value charset:
// [A-Za-z0-9_.:-]. This deliberately excludes the path separators '/' and
// '\\', whitespace, and '@' (the tell-tale of a UPN), so a file path or
// user principal name cannot pass through verbatim. It admits the shapes
// of every value OFEM legitimately reports: tenant GUIDs (hex + '-'),
// account-alias hashes (hex), snake_case event names, "true"/"false", and
// constant error codes.
func safePropertyByte(c byte) bool {
	switch {
	case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		return true
	case c == '_', c == '.', c == ':', c == '-':
		return true
	default:
		return false
	}
}

// scrubProperty enforces the telemetry value charset at the boundary. A
// value made only of [safePropertyByte] up to [maxPropertyLen] passes
// unchanged; anything else collapses to "redacted". This is what makes the
// privacy promise structural instead of a matter of caller discipline:
// even if a present or future call site hands a path or UPN as a property
// value, [splitFields] cannot forward it to the sink.
func scrubProperty(v string) string {
	if v == "" {
		return ""
	}
	if len(v) > maxPropertyLen {
		return "redacted"
	}
	for i := 0; i < len(v); i++ {
		if !safePropertyByte(v[i]) {
			return "redacted"
		}
	}
	return v
}

// SafeErrorCode returns errorCode unchanged when it is short and drawn
// only from the telemetry value charset (see [safePropertyByte]); anything
// else — a path separator, whitespace, '@', a non-ASCII byte, or more than
// [safeErrorCodeMaxLen] characters — collapses to "redacted" so the
// downstream pipeline cannot receive accidental PII. Stricter than a bare
// printable-ASCII check: "Sales/budget_2026.csv" is rejected on the '/'.
func SafeErrorCode(errorCode string) string {
	if errorCode == "" {
		return ""
	}
	if len(errorCode) > safeErrorCodeMaxLen {
		return "redacted"
	}
	for i := 0; i < len(errorCode); i++ {
		if !safePropertyByte(errorCode[i]) {
			return "redacted"
		}
	}
	return errorCode
}
