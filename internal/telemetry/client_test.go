package telemetry

import (
	"context"
	"errors"
	"testing"
	"time"
)

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
