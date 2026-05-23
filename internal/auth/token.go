package auth

import "context"

// TokenProvider returns an OAuth access token for the given account alias.
//
// The token has audience https://storage.azure.com/ — the audience that
// both the OneLake ADLS Gen2 DFS endpoint and the Microsoft Fabric REST
// API accept. Implementations cache and refresh tokens silently; the
// token returned to the caller is valid for at least five minutes from
// the moment it is returned, so callers do not need to add their own
// expiry buffer for a single request.
//
// Errors:
//   - If the alias is unknown, implementations return an error that wraps
//     os.ErrNotExist so callers can use errors.Is.
//   - If silent refresh fails because the user must interact again (for
//     example after a Conditional Access policy change), implementations
//     should return an error that callers can distinguish; the concrete
//     sentinel is defined alongside the MSAL implementation in a
//     follow-up change.
type TokenProvider interface {
	Token(ctx context.Context, alias string) (string, error)
}
