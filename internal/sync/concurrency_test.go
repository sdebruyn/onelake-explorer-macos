package sync

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

func TestPerAccountSemaphore_CapEnforced(t *testing.T) {
	s := newPerAccountSemaphore(3)
	ctx := context.Background()

	const goroutines = 16
	var (
		peak    int32
		inUse   int32
		wg      sync.WaitGroup
		barrier = make(chan struct{})
	)
	wg.Add(goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			if err := s.acquire(ctx, "alias-1"); err != nil {
				t.Errorf("acquire: %v", err)
				return
			}
			n := atomic.AddInt32(&inUse, 1)
			for {
				prev := atomic.LoadInt32(&peak)
				if n <= prev {
					break
				}
				if atomic.CompareAndSwapInt32(&peak, prev, n) {
					break
				}
			}
			<-barrier
			atomic.AddInt32(&inUse, -1)
			s.release("alias-1")
		}()
	}

	// Let the spawned goroutines pile up against the cap, then release
	// them all at once.
	time.Sleep(50 * time.Millisecond)
	close(barrier)
	wg.Wait()

	if peak > 3 {
		t.Errorf("peak in-flight = %d, want <= 3", peak)
	}
}

func TestPerAccountSemaphore_AliasesAreIndependent(t *testing.T) {
	s := newPerAccountSemaphore(1)
	ctx := context.Background()
	if err := s.acquire(ctx, "a"); err != nil {
		t.Fatalf("acquire a: %v", err)
	}
	defer s.release("a")
	// Another alias must succeed independently.
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := s.acquire(ctx, "b"); err != nil {
			t.Errorf("acquire b: %v", err)
		}
		s.release("b")
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("acquire on alias b blocked even though alias a held the only slot")
	}
}

func TestPerAccountSemaphore_RespectsContext(t *testing.T) {
	s := newPerAccountSemaphore(1)
	ctx, cancel := context.WithCancel(context.Background())
	if err := s.acquire(ctx, "a"); err != nil {
		t.Fatalf("acquire: %v", err)
	}
	defer s.release("a")

	ctx2, cancel2 := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- s.acquire(ctx2, "a") }()
	cancel2()
	select {
	case err := <-errCh:
		if err == nil {
			t.Fatal("want ctx.Err(), got nil")
		}
	case <-time.After(time.Second):
		t.Fatal("acquire did not unblock on context cancel")
	}
	cancel()
}

// TestPerAccountSemaphore_Clear verifies that clear empties the internal
// map so previously allocated per-alias channels are released.
func TestPerAccountSemaphore_Clear(t *testing.T) {
	s := newPerAccountSemaphore(2)
	ctx := context.Background()

	// Touch two aliases to populate the map.
	for _, alias := range []string{"alice", "bob"} {
		if err := s.acquire(ctx, alias); err != nil {
			t.Fatalf("acquire %s: %v", alias, err)
		}
		s.release(alias)
	}

	s.mu.Lock()
	before := len(s.sem)
	s.mu.Unlock()
	if before != 2 {
		t.Fatalf("expected 2 entries before clear, got %d", before)
	}

	s.clear()

	s.mu.Lock()
	after := len(s.sem)
	s.mu.Unlock()
	if after != 0 {
		t.Fatalf("expected 0 entries after clear, got %d", after)
	}
}

// TestEngine_Close_ClearsSemaphores builds a real Engine, exercises both
// upload and download semaphores across a couple of aliases, calls Close,
// and asserts the semaphore maps are empty.
func TestEngine_Close_ClearsSemaphores(t *testing.T) {
	f := newEngine(t)

	ctx := context.Background()
	// Prime the per-alias channels for two aliases in each semaphore.
	for _, alias := range []string{"acme", "contoso"} {
		if err := f.engine.downloadSem.acquire(ctx, alias); err != nil {
			t.Fatalf("downloadSem.acquire(%s): %v", alias, err)
		}
		f.engine.downloadSem.release(alias)

		if err := f.engine.uploadSem.acquire(ctx, alias); err != nil {
			t.Fatalf("uploadSem.acquire(%s): %v", alias, err)
		}
		f.engine.uploadSem.release(alias)
	}

	if err := f.engine.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	f.engine.downloadSem.mu.Lock()
	dLen := len(f.engine.downloadSem.sem)
	f.engine.downloadSem.mu.Unlock()

	f.engine.uploadSem.mu.Lock()
	uLen := len(f.engine.uploadSem.sem)
	f.engine.uploadSem.mu.Unlock()

	if dLen != 0 {
		t.Errorf("downloadSem.sem: want 0 entries after Close, got %d", dLen)
	}
	if uLen != 0 {
		t.Errorf("uploadSem.sem: want 0 entries after Close, got %d", uLen)
	}
}

// TestOpen_DownloadConcurrencyCap launches more parallel Opens than
// the cap and asserts that no more than cap requests ever sit in
// flight against the mock server.
func TestOpen_DownloadConcurrencyCap(t *testing.T) {
	f := newEngine(t, func(o *Options) { o.MaxConcurrentDownloads = 2 })
	ctx := context.Background()

	var (
		inFlight int32
		peak     int32
		release  = make(chan struct{})
	)
	httpmock.RegisterResponder("GET", "=~^"+testOneLakeBase+`.*`,
		func(req *http.Request) (*http.Response, error) {
			n := atomic.AddInt32(&inFlight, 1)
			for {
				prev := atomic.LoadInt32(&peak)
				if n <= prev || atomic.CompareAndSwapInt32(&peak, prev, n) {
					break
				}
			}
			<-release
			atomic.AddInt32(&inFlight, -1)
			body := "x"
			resp := httpmock.NewStringResponse(200, body)
			resp.Header.Set("ETag", "e")
			resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
			return resp, nil
		})

	const n = 6
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		i := i
		go func() {
			k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID,
				Path: "Files/c-" + strings.Repeat("a", i+1) + ".txt"}
			rc, err := f.engine.Open(ctx, k)
			if err == nil {
				_ = rc.Close()
			}
			errs <- err
		}()
	}
	// Let the goroutines pile up against the semaphore.
	time.Sleep(50 * time.Millisecond)
	close(release)
	for i := 0; i < n; i++ {
		if err := <-errs; err != nil {
			t.Errorf("Open: %v", err)
		}
	}
	if peak > 2 {
		t.Errorf("peak concurrent GET = %d, want <= 2", peak)
	}
}

// TestPut_WriteErrorReleasesAccountSlot covers the per-account / per-host
// composition concern: a failed upload must not lock the per-account
// upload slot indefinitely. The deferred release must fire on the error
// path so a subsequent Put on the same account can run.
//
// We assert this by running two Puts in series against cap=1: the first
// fails on a write error and the second must complete promptly (the slot
// was released).
func TestPut_WriteErrorReleasesAccountSlot(t *testing.T) {
	f := newEngine(t, func(o *Options) { o.MaxConcurrentUploads = 1 })
	ctx := context.Background()

	var puts atomic.Int32
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			// The first Put's PUT fails; the second Put's PUT succeeds.
			if puts.Add(1) == 1 {
				return httpmock.NewStringResponse(412, "etag conflict"), nil
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	k1 := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/storm.txt"}
	if err := f.engine.Put(ctx, k1, strings.NewReader("x"), 1); err == nil {
		t.Fatal("Put under 412 storm: want error, got nil")
	}

	// Slot must already be released by the deferred call inside Put.
	// A second Put on the SAME account must run; bound the wait so a
	// regression that holds the slot indefinitely fails the test.
	k2 := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID, Path: "Files/storm-after.txt"}
	done := make(chan error, 1)
	go func() { done <- f.engine.Put(ctx, k2, strings.NewReader("y"), 1) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("second Put: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("second Put blocked — per-account slot not released after 412 storm")
	}
}

// TestPerAccountSemaphore_UnbalancedReleasePanics verifies that calling
// release without a prior acquire panics, making double-release bugs
// immediately visible under the race detector.
func TestPerAccountSemaphore_UnbalancedReleasePanics(t *testing.T) {
	s := newPerAccountSemaphore(1)
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("expected panic on unbalanced release, got none")
		}
	}()
	s.release("ghost") // no prior acquire — must panic
}

// TestPut_UploadConcurrencyCap mirrors the download cap assertion on
// the upload path.
func TestPut_UploadConcurrencyCap(t *testing.T) {
	f := newEngine(t, func(o *Options) { o.MaxConcurrentUploads = 2 })
	ctx := context.Background()

	var inFlight, peak int32
	release := make(chan struct{})
	httpmock.RegisterResponder("PUT", "=~^"+testOneLakeBase+`.*`,
		func(_ *http.Request) (*http.Response, error) {
			n := atomic.AddInt32(&inFlight, 1)
			for {
				prev := atomic.LoadInt32(&peak)
				if n <= prev || atomic.CompareAndSwapInt32(&peak, prev, n) {
					break
				}
			}
			<-release
			atomic.AddInt32(&inFlight, -1)
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(202, ""))
	httpmock.RegisterResponder("HEAD", "=~^"+testOneLakeBase+`.*`,
		httpmock.NewStringResponder(200, ""))

	const n = 5
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		i := i
		go func() {
			k := cache.Key{AccountAlias: testAlias, WorkspaceID: testWorkspaceID, ItemID: testItemID,
				Path: "Files/up-" + strings.Repeat("b", i+1) + ".txt"}
			errs <- f.engine.Put(ctx, k, strings.NewReader("ok"), 2)
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	for i := 0; i < n; i++ {
		if err := <-errs; err != nil {
			t.Errorf("Put: %v", err)
		}
	}
	if peak > 2 {
		t.Errorf("peak concurrent PUT = %d, want <= 2", peak)
	}
}
