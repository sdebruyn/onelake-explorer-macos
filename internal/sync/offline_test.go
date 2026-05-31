package sync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

// timeoutErr implements net.Error with Timeout() == true for test use.
type timeoutErr struct{}

func (timeoutErr) Error() string   { return "i/o timeout" }
func (timeoutErr) Timeout() bool   { return true }
func (timeoutErr) Temporary() bool { return true }

func TestIsOfflineError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"context canceled", context.Canceled, false},
		{"context deadline", context.DeadlineExceeded, false},
		{"random", errors.New("boom"), false},
		// Plain string errors are no longer treated as offline; only typed
		// net.DNSError / net.OpError values are. The Go network stack always
		// wraps in typed errors so this is the right trade-off.
		{"plain string no such host", fmt.Errorf("Get: dial tcp: no such host"), false},
		{"plain string connection refused", fmt.Errorf("dial tcp: connection refused"), false},
		{"dns error", &net.DNSError{Err: "no such host", IsNotFound: true}, true},
		// OpError without timeout (e.g. connection refused, network unreachable):
		// non-timeout OpErrors are treated as offline.
		{"op error non-timeout", &net.OpError{Op: "dial", Net: "tcp", Err: fmt.Errorf("connection refused")}, true},
		// OpError that is a timeout is NOT treated as offline (e.g. a read
		// deadline exceeded is a liveness issue, not a connectivity failure).
		{"op error timeout", &net.OpError{Op: "read", Net: "tcp", Err: timeoutErr{}}, false},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			if got := IsOfflineError(c.err); got != c.want {
				t.Errorf("IsOfflineError(%v) = %v, want %v", c.err, got, c.want)
			}
		})
	}
}

func TestOfflineState_FlipsOnObserve(t *testing.T) {
	s := newOfflineState()
	now := time.Now().UTC()
	if s.offline(now) {
		t.Error("fresh state must not be offline")
	}
	s.markOffline(now)
	if !s.offline(now) {
		t.Error("after markOffline state must be offline")
	}
	s.markOnline()
	if s.offline(now) {
		t.Error("after markOnline state must be online again")
	}
}

func TestOfflineState_AutoExpires(t *testing.T) {
	s := newOfflineState()
	now := time.Now().UTC()
	s.markOffline(now)
	if !s.offline(now) {
		t.Fatal("must be offline immediately")
	}
	future := now.Add(2 * offlineCooldown)
	if s.offline(future) {
		t.Error("must auto-expire after cooldown")
	}
}

// TestPut_OfflineEnqueuesAndDrains: a DNS-class failure during Put
// must enqueue the bytes (Put returns nil success — less-protective
// default). A subsequent successful round-trip triggers a drain that
// replays the queued upload.
func TestPut_OfflineEnqueuesAndDrains(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	var (
		shouldFail atomic.Bool
		puts       atomic.Int32
	)
	shouldFail.Store(true)

	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			puts.Add(1)
			if shouldFail.Load() {
				// Synthesise a DNS error that IsOfflineError recognises.
				return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/offline.txt"}
	if err := f.engine.Put(ctx, k, strings.NewReader("queued"), 6); err != nil {
		t.Fatalf("Put under offline: want nil (queued), got %v", err)
	}
	if !f.engine.Offline() {
		t.Error("engine should report Offline()=true after failure")
	}
	if got := f.engine.queueDepth(); got != 1 {
		t.Fatalf("queue depth = %d, want 1", got)
	}

	// Allow PUT to succeed; trigger drain manually so we don't depend
	// on the goroutine kicked off by observeNetworkResult.
	shouldFail.Store(false)
	f.engine.drainOfflineQueue(ctx)

	if got := f.engine.queueDepth(); got != 0 {
		t.Errorf("queue depth after drain = %d, want 0", got)
	}
	if f.engine.Offline() {
		t.Error("engine should report Offline()=false after successful drain")
	}
}

// TestDrainOfflineQueue_StillOfflineKeepsEntry is the C-5 regression: a
// drain that runs while the host is STILL offline must not lose the queued
// upload. Before the fix, the replay re-spooled to the same deterministic
// path and coalesced the head away, then the drain unlinked that very
// spool — losing the bytes. Now the replay surfaces the offline error, the
// drain stops, and the entry + spool survive for the next online window.
func TestDrainOfflineQueue_StillOfflineKeepsEntry(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	var shouldFail atomic.Bool
	shouldFail.Store(true)
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			if shouldFail.Load() {
				return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/flap.txt"}
	if err := f.engine.Put(ctx, k, strings.NewReader("flap"), 4); err != nil {
		t.Fatalf("Put under offline: want nil (queued), got %v", err)
	}
	if got := f.engine.queueDepth(); got != 1 {
		t.Fatalf("queue depth = %d, want 1", got)
	}
	spool := filepath.Join(f.engine.cache.Root(), offlineQueueDirName, spoolNameForKey(k))

	// Drain while STILL offline: the entry and its spool must survive.
	f.engine.drainOfflineQueue(ctx)
	if got := f.engine.queueDepth(); got != 1 {
		t.Fatalf("queue depth after offline drain = %d, want 1 (entry must survive)", got)
	}
	if _, err := os.Stat(spool); err != nil {
		t.Fatalf("spool removed during an offline drain (data loss): %v", err)
	}

	// Network recovers: the drain now completes and empties the queue.
	shouldFail.Store(false)
	f.engine.drainOfflineQueue(ctx)
	if got := f.engine.queueDepth(); got != 0 {
		t.Errorf("queue depth after online drain = %d, want 0", got)
	}
	if _, err := os.Stat(spool); !os.IsNotExist(err) {
		t.Errorf("spool not cleaned after successful drain: %v", err)
	}
}

// TestDrainOfflineQueue_KeepsRestOnMidFailure verifies the FIFO
// ordering invariant under a mid-drain failure: when entry 2 of 3
// fails to upload, entries 2 and 3 must remain in the queue (in that
// order) so a follow-up drain re-tries from the failed entry rather
// than skipping it. Closes the sad-path coverage gap on
// drainOfflineQueue from review item LOW-9.
func TestDrainOfflineQueue_KeepsRestOnMidFailure(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	// Seed the queue with three entries; the second one's upload will
	// fail because we register a 403 responder for its path.
	k1 := cache.Key{AccountAlias: "a", WorkspaceID: "w", ItemID: "i", Path: "Files/q1.txt"}
	k2 := cache.Key{AccountAlias: "a", WorkspaceID: "w", ItemID: "i", Path: "Files/q2.txt"}
	k3 := cache.Key{AccountAlias: "a", WorkspaceID: "w", ItemID: "i", Path: "Files/q3.txt"}
	for _, k := range []cache.Key{k1, k2, k3} {
		if err := f.engine.enqueueOfflineUpload(ctx, k, strings.NewReader("xx"), 2); err != nil {
			t.Fatalf("enqueue %s: %v", k.Path, err)
		}
	}
	if got := f.engine.queueDepth(); got != 3 {
		t.Fatalf("queue depth before drain = %d, want 3", got)
	}

	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			if strings.Contains(req.URL.Path, "q2.txt") {
				return httpmock.NewStringResponse(403, "denied"), nil
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	f.engine.drainOfflineQueue(ctx)

	// k1 succeeded → removed; k2 failed → kept; k3 still queued behind k2.
	if got := f.engine.queueDepth(); got != 2 {
		t.Errorf("queue depth after partial drain = %d, want 2 (k2 + k3)", got)
	}
	// FIFO check: head must be k2.
	f.engine.queueMu.Lock()
	head := f.engine.queue[0].key
	f.engine.queueMu.Unlock()
	if head != k2 {
		t.Errorf("queue head = %+v, want %+v (FIFO preserved)", head, k2)
	}
}

// TestSpoolNameForKey_RoundTrip verifies that the filename-encoded
// cache.Key survives a base32 round-trip without losing any of the
// four fields (including a Path with special characters).
func TestSpoolNameForKey_RoundTrip(t *testing.T) {
	cases := []cache.Key{
		{AccountAlias: "work", WorkspaceID: "ws-1", ItemID: "it-1", Path: "Files/a.txt"},
		{AccountAlias: "home", WorkspaceID: "ws-2", ItemID: "it-2", Path: ""},
		{AccountAlias: "x", WorkspaceID: "y", ItemID: "z", Path: "Files/with spaces and / slashes/and.csv"},
	}
	for _, k := range cases {
		k := k
		t.Run(k.AccountAlias+"|"+k.Path, func(t *testing.T) {
			name := spoolNameForKey(k)
			got, ok := keyFromSpoolName(name)
			if !ok {
				t.Fatalf("keyFromSpoolName(%q) failed", name)
			}
			if got != k {
				t.Errorf("round-trip mismatch: got %+v, want %+v", got, k)
			}
		})
	}
}

// TestKeyFromSpoolName_RejectsStrays confirms the walker skips files
// that don't carry the expected suffix or whose body isn't base32.
func TestKeyFromSpoolName_RejectsStrays(t *testing.T) {
	cases := []string{
		"spool-12345.tmp",
		"random.dat",
		"NOTBASE32" + queueSuffix,
		"",
	}
	for _, c := range cases {
		c := c
		t.Run(c, func(t *testing.T) {
			if _, ok := keyFromSpoolName(c); ok {
				t.Errorf("keyFromSpoolName(%q) = ok, want skip", c)
			}
		})
	}
}

// TestRecoverOfflineQueue_ReplaysAfterRestart simulates the crash
// scenario the review flagged: bytes spooled, daemon dies before
// drain, restart must find the spool file and finish the upload.
//
// Path:
//  1. Engine A enqueues a spool file (simulating the offline window).
//  2. Engine A is dropped without ever draining (= daemon crash).
//  3. Engine B is built over the same cache root; we call
//     RecoverOfflineQueue and assert the queue rebuilds.
//  4. The mocked PUT/PATCH succeed; drain replays the bytes.
func TestRecoverOfflineQueue_ReplaysAfterRestart(t *testing.T) {
	// Engine A: enqueue while "offline".
	a := newEngine(t)
	ctx := context.Background()

	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
		})

	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/restart.txt"}
	if err := a.engine.Put(ctx, k, strings.NewReader("durable"), 7); err != nil {
		t.Fatalf("Put while offline: %v", err)
	}
	if got := a.engine.queueDepth(); got != 1 {
		t.Fatalf("engine A queue depth = %d, want 1", got)
	}

	// Capture the cache root so engine B can re-open it.
	cacheRoot := a.cache.Root()

	// Drop A without draining. The spool file should still be on disk.
	queueDir := filepath.Join(cacheRoot, offlineQueueDirName)
	entries, err := os.ReadDir(queueDir)
	if err != nil {
		t.Fatalf("read queue dir: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("spool entries on disk = %d, want 1", len(entries))
	}
	// Verify the filename decodes back to the original key.
	if rk, ok := keyFromSpoolName(entries[0].Name()); !ok || rk != k {
		t.Errorf("spool filename did not encode cache.Key: name=%q decoded=%+v ok=%v", entries[0].Name(), rk, ok)
	}

	// httpmock state is global; reset and re-register before building B.
	httpmock.DeactivateAndReset()
	httpmock.Activate()
	defer httpmock.DeactivateAndReset()

	// Engine B: same cache root.
	b := newEngineAt(t, cacheRoot)
	if rerr := b.engine.RecoverOfflineQueue(); rerr != nil {
		t.Fatalf("RecoverOfflineQueue: %v", rerr)
	}
	if got := b.engine.queueDepth(); got != 1 {
		t.Fatalf("engine B queue depth after recovery = %d, want 1", got)
	}

	var puts atomic.Int32
	var sawBody string
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			puts.Add(1)
			if req.Body != nil {
				bs, _ := io.ReadAll(req.Body)
				sawBody = string(bs)
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	b.engine.drainOfflineQueue(ctx)
	if got := b.engine.queueDepth(); got != 0 {
		t.Errorf("queue depth after drain = %d, want 0", got)
	}
	if puts.Load() == 0 {
		t.Error("expected at least one PUT during drain")
	}
	if sawBody != "" && sawBody != "durable" {
		t.Errorf("uploaded body = %q, want %q", sawBody, "durable")
	}

	// Spool file must be gone.
	entries, _ = os.ReadDir(queueDir)
	if len(entries) != 0 {
		t.Errorf("spool entries after drain = %d, want 0", len(entries))
	}
}

// TestEnqueueOfflineUpload_Coalesces verifies that two offline Puts
// on the same cache.Key collapse to a single spool file — the second
// write replaces the first on disk and in the queue, so a later drain
// uploads the latest bytes, not duplicates.
func TestEnqueueOfflineUpload_Coalesces(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()
	k := cache.Key{AccountAlias: "a", WorkspaceID: "w", ItemID: "i", Path: "Files/dup.txt"}
	if err := f.engine.enqueueOfflineUpload(ctx, k, strings.NewReader("first"), 5); err != nil {
		t.Fatalf("enqueue 1: %v", err)
	}
	if err := f.engine.enqueueOfflineUpload(ctx, k, strings.NewReader("secondsecond"), 12); err != nil {
		t.Fatalf("enqueue 2: %v", err)
	}
	if got := f.engine.queueDepth(); got != 1 {
		t.Errorf("queue depth = %d, want 1 (coalesced)", got)
	}
	// Disk also holds a single file with the second body.
	entries, _ := os.ReadDir(filepath.Join(f.cache.Root(), offlineQueueDirName))
	if len(entries) != 1 {
		t.Fatalf("on-disk entries = %d, want 1", len(entries))
	}
	body, _ := os.ReadFile(filepath.Join(f.cache.Root(), offlineQueueDirName, entries[0].Name()))
	if string(body) != "secondsecond" {
		t.Errorf("on-disk body = %q, want %q", string(body), "secondsecond")
	}
}

// TestEnumerate_SuccessDuringOfflineWindowClearsFlagAndDrains proves that
// a successful RefreshFolder call made while the offline flag is set:
//  1. clears the offline flag (the engine reports Offline() == false), and
//  2. triggers the queued-write drain so any pending uploads go out.
//
// Before the Task 1 fix, RefreshFolder did not call observeNetworkResult,
// so a browsing session during an offline window would neither flip the
// engine back online nor drain the upload queue.
func TestEnumerate_SuccessDuringOfflineWindowClearsFlagAndDrains(t *testing.T) {
	f := newEngine(t)
	ctx := context.Background()

	// Register a PUT that always fails (DNS-class), so a Put call enqueues.
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			return nil, &net.DNSError{Err: "no such host", IsNotFound: true}
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	// Enqueue an upload by forcing an offline Put.
	k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/pending.txt"}
	if err := f.engine.Put(ctx, k, strings.NewReader("pending"), 7); err != nil {
		t.Fatalf("Put while offline: %v", err)
	}
	if !f.engine.Offline() {
		t.Fatal("engine must be offline after DNS failure")
	}
	if got := f.engine.queueDepth(); got != 1 {
		t.Fatalf("queue depth = %d, want 1", got)
	}

	// Re-register PUT to succeed so the drain can replay the queued upload.
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(201, ""))

	// Now a successful enumerate (RefreshFolder) must clear the offline flag
	// via observeNetworkResult and kick off the drain.
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, `{"paths":[]}`))
	parent := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files"}
	if _, err := f.engine.RefreshFolder(ctx, parent); err != nil {
		t.Fatalf("RefreshFolder: %v", err)
	}

	if f.engine.Offline() {
		t.Error("engine must be online after a successful RefreshFolder")
	}

	// The drain goroutine runs asynchronously; give it a moment and then
	// poll briefly. In practice on any modern machine it completes in <1 ms.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if f.engine.queueDepth() == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := f.engine.queueDepth(); got != 0 {
		t.Errorf("queue depth after successful enumerate = %d, want 0 (drain must have run)", got)
	}
}
