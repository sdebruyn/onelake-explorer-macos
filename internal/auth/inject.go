package auth

import (
	"context"
	"fmt"
	"net/http"
)

// InjectBearer fetches a token from tp for the given alias and sets the
// Authorization header on req. It returns the token-provider error
// unwrapped so callers can errors.Is against their own auth errors.
func InjectBearer(ctx context.Context, req *http.Request, tp TokenProvider, alias string) error {
	if tp == nil {
		return fmt.Errorf("auth: nil TokenProvider")
	}
	tok, err := tp.Token(ctx, alias)
	if err != nil {
		return fmt.Errorf("auth: get token for alias %q: %w", alias, err)
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	return nil
}
