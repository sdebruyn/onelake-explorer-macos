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
	return nil
}
