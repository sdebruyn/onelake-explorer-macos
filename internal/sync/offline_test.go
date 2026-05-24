package sync

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
)

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
		{"dns error", &net.DNSError{Err: "no such host", IsNotFound: true}, true},
		{"no such host msg", fmt.Errorf("Get: dial tcp: no such host"), true},
		{"connection refused msg", fmt.Errorf("dial tcp: connection refused"), true},
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
