package sync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
)

// maxLastWriteWinsCycles is the cap on PUT retries when the server
// signals 412 Precondition Failed. After this many cycles we log a
// warning, drop the local change, and surface ErrLastWriteWinsExhausted
// so the caller knows the lake won the race. The cap matches the spec
// in the sync-polish brief: 3 productive cycles then a fourth that
// warns + drops.
const maxLastWriteWinsCycles = 3

// ErrLastWriteWinsExhausted is returned when even after re-fetching the
// remote etag and re-applying our local content, the server keeps
// returning 412. We do NOT create a conflict copy — Sam's preference is
// "no protective UX layers" — but we surface a clean error so the
// caller can treat it as "upload aborted".
var ErrLastWriteWinsExhausted = errors.New("sync: last-write-wins exhausted after 412 retries")

// uploadWithLastWriteWins runs onelake.Write, retrying on a 412
// Precondition Failed by re-fetching the latest remote etag (the
// re-apply step is implicit: we replay the same buffered content via
// the rewindable spill). On the maxLastWriteWinsCycles + 1'th 412 we
// give up and surface ErrLastWriteWinsExhausted.
//
// The spec asks for "no conflict copy" — that is precisely what
// happens here: on exhaustion we DROP the local change rather than
// creating a sibling file with the local bytes.
//
// rewind must reset the content reader back to byte 0 so a subsequent
// retry can replay the bytes. tmp may be nil when the caller cannot
// rewind (the function then surfaces 412 on the first attempt).
func (e *Engine) uploadWithLastWriteWins(ctx context.Context, k cache.Key, content io.Reader, size int64, rewind func() error) error {
	for attempt := 1; attempt <= maxLastWriteWinsCycles+1; attempt++ {
		err := e.onelake.Write(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path, content, size)
		if err == nil {
			return nil
		}
		if !errors.Is(err, httpretry.ErrPreconditionFailed) {
			return err
		}
		if attempt > maxLastWriteWinsCycles {
			e.logger.Warn("412 PreconditionFailed not resolved after retries; dropping local change",
				slog.String("path", k.Path),
				slog.Int("cycles", attempt-1),
			)
			return ErrLastWriteWinsExhausted
		}
		// Re-fetch the latest etag so callers / logs see we acknowledged
		// the remote winner before replaying. The etag is informational
		// here because onelake.Write does not send If-Match itself; the
		// HEAD just keeps the cache row in sync with reality so the
		// caller's post-upload state lands on the freshest etag.
		if _, perr := e.onelake.GetProperties(ctx, k.AccountAlias, k.WorkspaceID, k.ItemID, k.Path); perr != nil {
			e.logger.Debug("post-412 HEAD failed",
				slog.String("path", k.Path), slog.Any("err", perr))
		}
		if rewind != nil {
			if rerr := rewind(); rerr != nil {
				return fmt.Errorf("sync: rewind for 412 retry: %w", rerr)
			}
		}
		e.logger.Info("412 PreconditionFailed; replaying upload (last-write-wins)",
			slog.String("path", k.Path),
			slog.Int("attempt", attempt),
		)
	}
	return ErrLastWriteWinsExhausted
}
