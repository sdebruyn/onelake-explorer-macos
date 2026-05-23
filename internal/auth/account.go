package auth

import (
	"fmt"
	"time"
	"unicode"
)

// Account is one signed-in OneLake account, scoped to a single Microsoft
// Entra tenant. Multiple accounts in the same tenant are allowed and are
// distinguished by their user-chosen [Account.Alias].
type Account struct {
	// Alias is the user-chosen short name, unique across all accounts.
	// It must satisfy [ValidateAlias] because it is later used as a path
	// segment under ~/OneLake/<alias>/.
	Alias string

	// HomeAccountID is MSAL's per-user-per-tenant identifier
	// (objectId.tenantId). Stable across logins for the same identity.
	HomeAccountID string

	// Username is the UPN (e.g. "sam@contoso.com"). Display only; it is
	// never sent to telemetry.
	Username string

	// TenantID is the Microsoft Entra tenant GUID.
	TenantID string

	// TenantName is a human-friendly tenant label. Display only, optional.
	TenantName string

	// AddedAt is the wall-clock timestamp of the first successful login
	// for this alias.
	AddedAt time.Time
}

// MaxAliasLength is the upper bound enforced by [ValidateAlias]. It is
// deliberately small because aliases appear in file-system paths.
const MaxAliasLength = 32

// ValidateAlias returns an error if alias is not safe to use as an
// account identifier. The allowed character set is ASCII letters, digits,
// dash, underscore, and dot; the length must be between 1 and
// [MaxAliasLength] inclusive.
//
// On top of the character whitelist, the following names are rejected
// because they are unsafe as path segments under ~/OneLake/<alias>/ or
// as CLI arguments:
//
//   - aliases consisting only of dots (".", "..", "..." …): they collapse
//     or escape the parent directory when joined into a path;
//   - aliases starting with "-": they would be parsed as a flag by most
//     CLI argument parsers;
//   - aliases starting with ".": they create files/folders that are
//     hidden by default in Finder and most shells, which is confusing.
//
// The rules are intentionally strict because the alias becomes part of
// the mount path (~/OneLake/<alias>/...) and the keychain account name,
// so anything that could be misinterpreted by macOS, a shell, or a URL
// parser is rejected.
func ValidateAlias(alias string) error {
	if alias == "" {
		return fmt.Errorf("alias must not be empty")
	}
	if len(alias) > MaxAliasLength {
		return fmt.Errorf("alias %q is longer than %d characters", alias, MaxAliasLength)
	}
	if alias[0] == '-' {
		return fmt.Errorf("alias %q must not start with '-' (would be parsed as a CLI flag)", alias)
	}
	if alias[0] == '.' {
		return fmt.Errorf("alias %q must not start with '.' (would be hidden in Finder and most shells)", alias)
	}
	for i, r := range alias {
		if r > unicode.MaxASCII {
			return fmt.Errorf("alias %q contains non-ASCII character at position %d", alias, i)
		}
		if unicode.IsControl(r) {
			return fmt.Errorf("alias %q contains a control character at position %d", alias, i)
		}
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '-' || r == '_' || r == '.':
		default:
			return fmt.Errorf("alias %q contains disallowed character %q at position %d (allowed: letters, digits, '-', '_', '.')", alias, r, i)
		}
	}
	if isAllDots(alias) {
		return fmt.Errorf("alias %q must not consist only of dots (path traversal risk)", alias)
	}
	return nil
}

// isAllDots reports whether s is non-empty and consists exclusively of
// '.' characters. Used to reject ".", "..", "..." and so on as aliases
// because they collapse or escape the parent directory when joined into
// a filesystem path.
func isAllDots(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] != '.' {
			return false
		}
	}
	return s != ""
}
