package api

import (
	"net/http"

	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
)

// Sentinel errors and the APIError type are owned by internal/httpretry
// so the retry decision and the error classification stay in one place.
// The aliases here keep existing call sites compiling; new code should
// import from internal/httpretry directly.

// Sentinel error aliases. Kept for source compatibility with code
// written before internal/httpretry existed.
var (
	ErrUnauthorized       = httpretry.ErrUnauthorized
	ErrForbidden          = httpretry.ErrForbidden
	ErrNotFound           = httpretry.ErrNotFound
	ErrConflict           = httpretry.ErrConflict
	ErrPreconditionFailed = httpretry.ErrPreconditionFailed
	ErrThrottled          = httpretry.ErrThrottled
	ErrServerError        = httpretry.ErrServerError
)

// APIError aliases [httpretry.APIError] so existing errors.As targets
// keep working unchanged.
type APIError = httpretry.APIError

// FromResponse aliases [httpretry.FromResponse].
func FromResponse(resp *http.Response) error { return httpretry.FromResponse(resp) }
