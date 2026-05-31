package sync

import (
	"context"
	"sync"
)

// DefaultMaxConcurrentDownloads is the per-account cap on concurrent
// Open() calls, matching the spec in docs/onelake-api.md. Downloads are
// streaming reads with response-header timeouts, so a relatively
// generous default keeps Finder responsive when the user opens several
// files at once.
const DefaultMaxConcurrentDownloads = 8

// DefaultMaxConcurrentUploads is the per-account cap on concurrent
// Put() calls. Uploads are chunked PUT/PATCH chains that hold the
// process's tempfile + an HTTP connection per chunk; the default is
// lower than downloads to keep memory + socket usage bounded.
const DefaultMaxConcurrentUploads = 4

// perAccountSemaphore caps in-flight operations per account-alias. The
// implementation lazily allocates a buffered-channel "semaphore" the
// first time a given alias is seen.
//
// A new semaphore is allocated under the master mutex; the per-alias
// channel itself is unsynchronised (its send/receive operations are
// the synchronisation point).
type perAccountSemaphore struct {
	cap int
	mu  sync.Mutex
	sem map[string]chan struct{}
}

func newPerAccountSemaphore(cap int) *perAccountSemaphore {
	if cap <= 0 {
		cap = 1
	}
	return &perAccountSemaphore{
		cap: cap,
		sem: make(map[string]chan struct{}),
	}
}

// acquire blocks until a slot is available for alias or ctx fires.
// Returns ctx.Err() on cancellation. The caller MUST call release.
func (s *perAccountSemaphore) acquire(ctx context.Context, alias string) error {
	if s == nil {
		return nil
	}
	ch := s.channel(alias)
	select {
	case ch <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// release frees a slot acquired via acquire. Calling release without a
// prior successful acquire is a programmer error and will panic.
// All callers must guard defer release() behind a nil-error check on acquire.
func (s *perAccountSemaphore) release(alias string) {
	if s == nil {
		return
	}
	ch := s.channel(alias)
	select {
	case <-ch:
	default:
		panic("perAccountSemaphore: unbalanced release for alias " + alias)
	}
}

// channel returns the (lazily allocated) semaphore channel for alias.
func (s *perAccountSemaphore) channel(alias string) chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	ch, ok := s.sem[alias]
	if !ok {
		ch = make(chan struct{}, s.cap)
		s.sem[alias] = ch
	}
	return ch
}
