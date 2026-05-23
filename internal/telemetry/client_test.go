package telemetry

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// failingSink returns the configured error from every Send and counts
// the number of calls.
type failingSink struct {
	mu     sync.Mutex
	calls  int
	events []Event
	err    error
}

func (f *failingSink) Send(_ context.Context, events []Event) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.events = append(f.events, events...)
	return f.err
}

func (f *failingSink) setErr(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *failingSink) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// ctxAwareSink blocks in Send until ctx is cancelled or done() is
// signalled. Used to test ctx-cancel propagation.
type ctxAwareSink struct {
	started chan struct{}
	done    chan struct{}
	count   atomic.Int32
}

func (c *ctxAwareSink) Send(ctx context.Context, _ []Event) error {
	c.count.Add(1)
	select {
	case c.started <- struct{}{}:
	default:
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-c.done:
		return nil
	}
}

func TestClient_TrackMergesCommonProps(t *testing.T) {
	t.Parallel()
	sink := &MemorySink{}
	c := New(Options{
		AppVersion: "2026.05.1",
		InstallID:  "install-xyz",
		Sink:       sink,
		Platform:   "darwin",
		Arch:       "arm64",
		OSVersion:  "14.5.1",
	})
	if c == nil {
		t.Fatal("New returned nil")
	}

	c.Track(Event{Name: "app_start"})

	if err := c.Flush(context.Background()); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	events := sink.Drain()
	if len(events) != 1 {
		t.Fatalf("event count = %d", len(events))
	}
	ev := events[0]
	if ev.Time.IsZero() {
		t.Errorf("Time should default to now")
	}
	want := map[string]string{
		"installId":  "install-xyz",
		"appVersion": "2026.05.1",
		"platform":   "darwin",
		"arch":       "arm64",
		"osVersion":  "14.5.1",
	}
	for k, v := range want {
		if ev.CommonProps[k] != v {
			t.Errorf("CommonProps[%q] = %q, want %q", k, ev.CommonProps[k], v)
		}
	}
}

func TestClient_NoopSinkDropsSilently(t *testing.T) {
	t.Parallel()
	c := New(Options{
		AppVersion: "x",
		InstallID:  "y",
		Sink:       NoopSink{},
	})
	c.Start(context.Background())
	for i := 0; i < 10; i++ {
		c.Track(Event{Name: "app_start"})
	}
	if err := c.Flush(context.Background()); err != nil {
		t.Errorf("Flush should be nil for noop, got %v", err)
	}
	if err := c.Close(context.Background()); err != nil {
		t.Errorf("Close: %v", err)
	}
}

func TestClient_BufferOverflowDropsOldest(t *testing.T) {
	t.Parallel()
	sink := &MemorySink{}
	c := New(Options{
		AppVersion:    "v",
		InstallID:     "i",
		Sink:          sink,
		MaxBufferSize: 3,
		FlushInterval: time.Hour, // we drive flushes manually
	})

	for i := 0; i < 5; i++ {
		c.Track(Event{Name: "ev", ErrorCode: string(rune('A' + i))})
	}
	if err := c.Flush(context.Background()); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	events := sink.Drain()
	if len(events) != 3 {
		t.Fatalf("flushed count = %d, want 3", len(events))
	}
	// Oldest two (A, B) should have been dropped.
	want := []string{"C", "D", "E"}
	for i, ev := range events {
		if ev.ErrorCode != want[i] {
			t.Errorf("events[%d].ErrorCode = %q, want %q", i, ev.ErrorCode, want[i])
		}
	}
}

func TestClient_CloseFlushesBeforeStopping(t *testing.T) {
	t.Parallel()
	sink := &MemorySink{}
	c := New(Options{
		AppVersion:    "v",
		InstallID:     "i",
		Sink:          sink,
		FlushInterval: time.Hour,
	})
	c.Start(context.Background())
	c.Track(Event{Name: "app_stop"})
	if err := c.Close(context.Background()); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if got := sink.Len(); got != 1 {
		t.Errorf("sink had %d events after Close, want 1", got)
	}
	// Track after Close should be a no-op.
	c.Track(Event{Name: "extra"})
	if got := sink.Len(); got != 1 {
		t.Errorf("post-Close Track leaked an event: now %d", got)
	}
}

func TestClient_TrackError(t *testing.T) {
	t.Parallel()
	sink := &MemorySink{}
	c := New(Options{Sink: sink})
	c.TrackError(errors.New("BoomError"), "file_download")
	if err := c.Flush(context.Background()); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	events := sink.Drain()
	if len(events) != 1 {
		t.Fatalf("event count = %d", len(events))
	}
	if events[0].Name != "error" {
		t.Errorf("name = %q, want error", events[0].Name)
	}
	if events[0].ErrorCode != "BoomError" {
		t.Errorf("errorCode = %q", events[0].ErrorCode)
	}
	if events[0].CommonProps["failedOp"] != "file_download" {
		t.Errorf("failedOp = %q", events[0].CommonProps["failedOp"])
	}
}

func TestClient_NewReturnsNilWhenNoSink(t *testing.T) {
	t.Parallel()
	if c := New(Options{}); c != nil {
		t.Errorf("New with nil sink should return nil, got %v", c)
	}
}

func TestClient_NilReceiverIsSafe(t *testing.T) {
	t.Parallel()
	var c *Client
	c.Track(Event{Name: "ignored"})
	c.TrackError(errors.New("x"), "op")
	c.Start(context.Background())
	if err := c.Flush(context.Background()); err != nil {
		t.Errorf("Flush on nil: %v", err)
	}
	if err := c.Close(context.Background()); err != nil {
		t.Errorf("Close on nil: %v", err)
	}
}

// TestClient_FlushRequeuesOnSendFailure verifies that a Sink error does
// not drop events: the next Flush must see the same batch (plus anything
// Tracked in between), matching the docs/telemetry.md promise that
// events accumulate up to maxBuffer and only get dropped on overflow.
func TestClient_FlushRequeuesOnSendFailure(t *testing.T) {
	t.Parallel()
	sink := &failingSink{err: errors.New("network down")}
	c := New(Options{
		AppVersion:    "v",
		InstallID:     "i",
		Sink:          sink,
		FlushInterval: time.Hour,
	})

	c.Track(Event{Name: "ev1"})
	c.Track(Event{Name: "ev2"})

	if err := c.Flush(context.Background()); err == nil {
		t.Fatal("expected Flush to return the sink error")
	}
	if got := sink.callCount(); got != 1 {
		t.Errorf("sink.Send calls = %d, want 1", got)
	}

	// Track another event in the meantime; it should land behind the
	// re-queued batch (ev1, ev2 first, then ev3).
	c.Track(Event{Name: "ev3"})

	// Now connectivity is back: switch the sink to succeed.
	memory := &MemorySink{}
	c.sink = memory
	sink.setErr(nil)
	if err := c.Flush(context.Background()); err != nil {
		t.Fatalf("second Flush: %v", err)
	}
	events := memory.Drain()
	if len(events) != 3 {
		t.Fatalf("flushed count = %d, want 3 (re-queue must preserve everything)", len(events))
	}
	want := []string{"ev1", "ev2", "ev3"}
	for i, ev := range events {
		if ev.Name != want[i] {
			t.Errorf("events[%d].Name = %q, want %q", i, ev.Name, want[i])
		}
	}
}

// TestClient_FlushRequeueRespectsBufferCap ensures the re-queue path
// still honors the hard cap of maxBuffer, dropping the oldest events
// rather than allowing the buffer to grow unbounded.
func TestClient_FlushRequeueRespectsBufferCap(t *testing.T) {
	t.Parallel()
	sink := &failingSink{err: errors.New("nope")}
	c := New(Options{
		AppVersion:    "v",
		InstallID:     "i",
		Sink:          sink,
		MaxBufferSize: 4,
		FlushInterval: time.Hour,
	})

	for i := 0; i < 4; i++ {
		c.Track(Event{Name: "old", ErrorCode: string(rune('A' + i))})
	}
	// Flush fails; ev[A-D] are now re-queued.
	if err := c.Flush(context.Background()); err == nil {
		t.Fatal("expected failure")
	}
	// Add more events that should push the oldest out of the buffer.
	for i := 0; i < 4; i++ {
		c.Track(Event{Name: "new", ErrorCode: string(rune('a' + i))})
	}
	// Switch sink to success and flush.
	memory := &MemorySink{}
	c.sink = memory
	sink.setErr(nil)
	if err := c.Flush(context.Background()); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	events := memory.Drain()
	if len(events) != 4 {
		t.Fatalf("flushed count = %d, want 4 (capped)", len(events))
	}
	// We expect the 4 newest events to survive. The original A-D were
	// pushed out by the new a-d Tracks.
	want := []string{"a", "b", "c", "d"}
	for i, ev := range events {
		if ev.ErrorCode != want[i] {
			t.Errorf("events[%d].ErrorCode = %q, want %q", i, ev.ErrorCode, want[i])
		}
	}
}

// TestClient_TrackDoesNotMutateCallerCommonProps ensures we never write
// back into a CommonProps map the caller still holds.
func TestClient_TrackDoesNotMutateCallerCommonProps(t *testing.T) {
	t.Parallel()
	sink := &MemorySink{}
	c := New(Options{
		AppVersion: "v",
		InstallID:  "i",
		Sink:       sink,
		Platform:   "darwin",
		Arch:       "arm64",
		OSVersion:  "14.5.1",
	})

	caller := map[string]string{"failedOp": "x"}
	c.Track(Event{Name: "error", CommonProps: caller})

	if len(caller) != 1 {
		t.Errorf("caller map mutated; size = %d want 1, contents = %v", len(caller), caller)
	}
	if _, ok := caller["installId"]; ok {
		t.Errorf("caller map gained installId key: %v", caller)
	}
}

// TestClient_FlushContextCancel verifies that a cancelled context
// causes Send to fail with a wrapped ctx error and that the events are
// re-queued for a future Flush.
func TestClient_FlushContextCancel(t *testing.T) {
	t.Parallel()
	sink := &ctxAwareSink{
		started: make(chan struct{}, 1),
		done:    make(chan struct{}),
	}
	c := New(Options{
		AppVersion:    "v",
		InstallID:     "i",
		Sink:          sink,
		FlushInterval: time.Hour,
	})
	c.Track(Event{Name: "ev1"})
	c.Track(Event{Name: "ev2"})

	ctx, cancel := context.WithCancel(context.Background())
	flushErr := make(chan error, 1)
	go func() {
		flushErr <- c.Flush(ctx)
	}()

	// Wait until Send is actually in flight before cancelling.
	select {
	case <-sink.started:
	case <-time.After(time.Second):
		t.Fatal("Send did not start within 1s")
	}
	cancel()

	select {
	case err := <-flushErr:
		if err == nil {
			t.Fatal("expected Flush error after ctx cancel")
		}
		if !errors.Is(err, context.Canceled) {
			t.Errorf("error did not wrap context.Canceled: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Flush did not return within 2s of cancel")
	}

	// The events should have been re-queued — confirm by draining with
	// a fresh, successful sink.
	memory := &MemorySink{}
	c.sink = memory
	close(sink.done) // unblock any in-flight Send that may still be lingering
	if err := c.Flush(context.Background()); err != nil {
		t.Fatalf("retry Flush: %v", err)
	}
	if got := memory.Len(); got != 2 {
		t.Errorf("re-queued events count = %d, want 2", got)
	}
}

// TestClient_SignalFlushWakesBackgroundOnOverflow verifies the
// overflow-wake path: hitting MaxBufferSize via Track must cause the
// background goroutine to drain promptly without waiting for the full
// flush interval.
func TestClient_SignalFlushWakesBackgroundOnOverflow(t *testing.T) {
	t.Parallel()
	sink := &MemorySink{}
	c := New(Options{
		AppVersion:    "v",
		InstallID:     "i",
		Sink:          sink,
		MaxBufferSize: 5,
		// Long enough that the ticker cannot save us if signalFlush is
		// broken; short test will time out instead.
		FlushInterval: time.Hour,
	})
	c.Start(context.Background())
	defer func() {
		_ = c.Close(context.Background())
	}()

	for i := 0; i < 5; i++ {
		c.Track(Event{Name: "burst"})
	}

	// signalFlush should wake the goroutine; the MemorySink should fill
	// within a small bounded time.
	deadline := time.After(2 * time.Second)
	for {
		if sink.Len() == 5 {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("background goroutine did not drain on overflow; sink.Len=%d", sink.Len())
		case <-time.After(5 * time.Millisecond):
		}
	}
}
