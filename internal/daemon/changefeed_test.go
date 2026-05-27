package daemon

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestChangefeedPublishAndSince(t *testing.T) {
	cf := NewChangefeed()
	base := time.Now().UTC()

	cf.Publish("ofem.work", "work/.rootContainer", base.Add(time.Second))
	cf.Publish("ofem.work", "work/ws-1/item-A", base.Add(2*time.Second))
	cf.Publish("ofem.client-a", "client-a/.rootContainer", base.Add(3*time.Second))

	// Query from the base time: all three events should come back.
	res := cf.Since(base)
	if len(res.Events) != 3 {
		t.Fatalf("events = %d, want 3", len(res.Events))
	}
	if res.FullResync {
		t.Errorf("FullResync should be false on first call")
	}
	// Anchor should advance to the latest event.
	if !res.Anchor.Equal(base.Add(3 * time.Second)) {
		t.Errorf("anchor = %v, want %v", res.Anchor, base.Add(3*time.Second))
	}
}

func TestChangefeedSinceFiltersOldEvents(t *testing.T) {
	cf := NewChangefeed()
	base := time.Now().UTC()

	cf.Publish("ofem.work", "work/.rootContainer", base.Add(time.Second))
	cf.Publish("ofem.work", "work/ws-1/item-A", base.Add(2*time.Second))

	// Poll from just after the first event: only the second should appear.
	res := cf.Since(base.Add(time.Second))
	if len(res.Events) != 1 {
		t.Fatalf("events = %d, want 1", len(res.Events))
	}
	if res.Events[0].ContainerID != "work/ws-1/item-A" {
		t.Errorf("unexpected event: %+v", res.Events[0])
	}
}

func TestChangefeedSinceEmptyWhenUpToDate(t *testing.T) {
	cf := NewChangefeed()
	base := time.Now().UTC()

	cf.Publish("ofem.work", "work/.rootContainer", base.Add(time.Second))

	anchor := cf.Since(base).Anchor
	// Second poll at the returned anchor must return no events.
	res := cf.Since(anchor)
	if len(res.Events) != 0 {
		t.Errorf("events = %d after catching up, want 0", len(res.Events))
	}
}

func TestChangefeedBoundedEviction(t *testing.T) {
	cf := NewChangefeed()
	base := time.Now().UTC()

	// Publish more events than maxFeedEvents to trigger eviction.
	for i := 0; i <= maxFeedEvents; i++ {
		cf.Publish("ofem.work", fmt.Sprintf("work/item-%d", i), base.Add(time.Duration(i)*time.Millisecond))
	}

	res := cf.Since(base.Add(-time.Hour))
	if !res.FullResync {
		t.Errorf("FullResync should be true after eviction")
	}
	// After the eviction the feed must hold at most maxFeedEvents/2 events.
	if len(cf.events) > maxFeedEvents/2 {
		t.Errorf("feed len = %d after eviction, want <= %d", len(cf.events), maxFeedEvents/2)
	}
}

func TestChangefeedFullResyncClearsAfterReport(t *testing.T) {
	cf := NewChangefeed()
	base := time.Now().UTC()

	for i := 0; i <= maxFeedEvents; i++ {
		cf.Publish("ofem.work", fmt.Sprintf("work/item-%d", i), base.Add(time.Duration(i)*time.Millisecond))
	}

	// First Since must report FullResync=true.
	res1 := cf.Since(base.Add(-time.Hour))
	if !res1.FullResync {
		t.Fatalf("first Since: expected FullResync=true")
	}

	// Second Since must NOT report FullResync again (no new eviction).
	res2 := cf.Since(res1.Anchor)
	if res2.FullResync {
		t.Errorf("second Since: FullResync should be false after flag was consumed")
	}
}

func TestChangefeedConcurrentAccess(t *testing.T) {
	cf := NewChangefeed()
	base := time.Now().UTC()

	var wg sync.WaitGroup
	const writers = 8
	const eventsPerWriter = 200

	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < eventsPerWriter; i++ {
				cf.Publish("ofem.work", fmt.Sprintf("work/item-%d-%d", w, i), base.Add(time.Duration(w*eventsPerWriter+i)*time.Microsecond))
			}
		}(w)
	}

	// Concurrent readers.
	for r := 0; r < 4; r++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				cf.Since(base)
			}
		}()
	}

	wg.Wait()

	// After all goroutines finish, the feed must be internally consistent:
	// Since should not panic and must return a valid result.
	res := cf.Since(base.Add(-time.Hour))
	if res.Anchor.Before(base) && !res.FullResync {
		t.Errorf("unexpected anchor %v with FullResync=false after concurrent publish", res.Anchor)
	}
}
