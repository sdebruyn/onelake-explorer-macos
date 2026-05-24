package api

import (
	"context"
	"net/http"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
)

// Do is a thin shim that translates the legacy (ctx, client, req,
// maxAttempts) signature into [httpretry.Do]. New code should call
// [httpretry.Do] directly so it can pass an explicit [httpretry.Policy].
//
// The shim preserves the historical timing tunables (250ms initial
// backoff, 30s cap) so the wire behaviour of existing callers does not
// change as the migration unfolds.
func Do(ctx context.Context, client *http.Client, req *http.Request, maxAttempts int) (*http.Response, error) {
	return httpretry.Do(ctx, client, req, httpretry.Policy{
		MaxAttempts:    maxAttempts,
		InitialBackoff: 250 * time.Millisecond,
		MaxBackoff:     30 * time.Second,
	})
}
