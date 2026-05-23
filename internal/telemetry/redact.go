package telemetry

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
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

// SafeErrorCode returns errorCode unchanged when it is short, ASCII, and
// free of '@' (which would suggest a leaked UPN). Anything else collapses
// to the string "redacted" so the downstream telemetry pipeline cannot
// receive accidental PII.
func SafeErrorCode(errorCode string) string {
	if errorCode == "" {
		return ""
	}
	if len(errorCode) > safeErrorCodeMaxLen {
		return "redacted"
	}
	if strings.ContainsRune(errorCode, '@') {
		return "redacted"
	}
	for i := 0; i < len(errorCode); i++ {
		c := errorCode[i]
		if c < 0x20 || c > 0x7E {
			return "redacted"
		}
	}
	return errorCode
}
