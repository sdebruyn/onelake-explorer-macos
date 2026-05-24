package httpgate

import (
	"context"
	"errors"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testHost = "test.example.com"

// TestAcquire_ConcurrencyCap verifies that at most `concurrency`
// callers hold the gate at once. We spin up 20 goroutines on a
// gate with concurrency=4 and a generous QPS budget; at any
// observation point the number of goroutines holding the gate must
// not exceed 4.
func TestAcquire_ConcurrencyCap(t *testing.T) {
	const want = 4
	g := New(testHost, want, 1000, 1000) // huge qps/burst -> tokens never block

	var (
		inflight int32
		peak     int32
	)

	const total = 20
	var wg sync.WaitGroup
	wg.Add(total)
	for i := 0; i < total; i++ {
		go func() {
			defer wg.Done()
			release, err := g.Acquire(context.Background())
			if err != nil {
				t.Errorf("Acquire: %v", err)
				return
			}
			defer release()
			cur := atomic.AddInt32(&inflight, 1)
			for {
				p := atomic.LoadInt32(&peak)
				if cur <= p || atomic.CompareAndSwapInt32(&peak, p, cur) {
					break
				}
			}
			// Hold the slot just long enough that other goroutines
			// catch up. 20ms is plenty for the runtime to schedule
			// every goroutine without making the test slow.
			time.Sleep(20 * time.Millisecond)
			atomic.AddInt32(&inflight, -1)
		}()
	}
	wg.Wait()

	if peak > int32(want) {
		t.Errorf("peak inflight = %d, want <= %d", peak, want)
	}
}

// TestAcquire_TokenThrottling drains the bucket and measures how long
// the next N Acquires take. The lower bound must be at least N / qps
// because the bucket has to refill between calls.
func TestAcquire_TokenThrottling(t *testing.T) {
	const qps = 5.0
	const burst = 1
	const n = 6 // 1 burst token + 5 refills at 5 qps -> ~1s
	g := New(testHost, 100, qps, burst)

	// Drain the initial burst so the first Acquire after this also
	// waits on the bucket.
	relInit, _ := g.Acquire(context.Background())
	relInit()

	start := time.Now()
	for i := 0; i < n; i++ {
		rel, err := g.Acquire(context.Background())
		if err != nil {
			t.Fatalf("Acquire %d: %v", i, err)
		}
		rel()
	}
	elapsed := time.Since(start)
	// Theoretical floor: (n - burst) tokens at qps per second. Allow a
	// small slack for scheduling jitter (-50 ms).
	want := time.Duration(float64(n-burst)/qps*float64(time.Second)) - 50*time.Millisecond
	if elapsed < want {
		t.Errorf("token throttling too loose: elapsed = %s, want >= %s", elapsed, want)
	}
}

// TestPenalty_BlocksDuringPause verifies that Acquire called during a
// pause window unblocks shortly after the deadline passes.
func TestPenalty_BlocksDuringPause(t *testing.T) {
	g := New(testHost, 8, 1000, 1000)

	const pause = 100 * time.Millisecond
	g.Penalty(time.Now().Add(pause))

	start := time.Now()
	rel, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer rel()
	elapsed := time.Since(start)
	// Lower bound: must wait roughly the full pause.
	if elapsed < pause-20*time.Millisecond {
		t.Errorf("Acquire returned too early: %s, want >= %s", elapsed, pause)
	}
	// Upper bound: should not be wildly longer than the pause + token
	// wait. 500ms is comfortable while still catching obvious bugs.
	if elapsed > 500*time.Millisecond {
		t.Errorf("Acquire took too long: %s", elapsed)
	}
}

// TestPenalty_StampedePrevention is the load-bearing test for the
// design. 50 goroutines all block on the same pause window. After it
// expires they must be released at the token rate, not all at once.
// We assert that the spread between the first and last unblock is at
// least (N / qps) seconds minus generous slack.
func TestPenalty_StampedePrevention(t *testing.T) {
	const (
		waiters = 50
		qps     = 10.0
		burst   = 1
		pause   = 100 * time.Millisecond
	)
	g := New(testHost, waiters, qps, burst)

	// Drain the initial burst so post-pause unblocks are strictly
	// bottlenecked by the token refill rate.
	rel, _ := g.Acquire(context.Background())
	rel()

	g.Penalty(time.Now().Add(pause))

	type sample struct{ at time.Time }
	got := make(chan sample, waiters)

	var wg sync.WaitGroup
	wg.Add(waiters)
	for i := 0; i < waiters; i++ {
		go func() {
			defer wg.Done()
			r, err := g.Acquire(context.Background())
			if err != nil {
				t.Errorf("Acquire: %v", err)
				return
			}
			got <- sample{at: time.Now()}
			r()
		}()
	}
	wg.Wait()
	close(got)

	stamps := make([]time.Time, 0, waiters)
	for s := range got {
		stamps = append(stamps, s.at)
	}
	if len(stamps) != waiters {
		t.Fatalf("got %d samples, want %d", len(stamps), waiters)
	}
	sort.Slice(stamps, func(i, j int) bool { return stamps[i].Before(stamps[j]) })

	spread := stamps[len(stamps)-1].Sub(stamps[0])
	// Theoretical floor: (waiters - burst) tokens at qps per second.
	// Subtract 500ms of slack for scheduler jitter and the imprecise
	// alignment between the post-pause wake-up and the token refill
	// schedule.
	wantSpread := time.Duration(float64(waiters-burst)/qps*float64(time.Second)) - 500*time.Millisecond
	if spread < wantSpread {
		t.Errorf("post-pause unblock not smeared: spread = %s, want >= %s", spread, wantSpread)
	}
}

// TestPenalty_LatestWins covers the case where two callers post Penalty
// nearly simultaneously with different deadlines. The later deadline
// must win regardless of arrival order.
func TestPenalty_LatestWins(t *testing.T) {
	g := New(testHost, 1, 1000, 1000)

	now := time.Now()
	earlier := now.Add(50 * time.Millisecond)
	later := now.Add(200 * time.Millisecond)

	// Post in two orders to make sure neither path forgets to compare.
	g.Penalty(earlier)
	g.Penalty(later)
	st := g.State()
	if !st.PauseUntil.Equal(later) {
		t.Errorf("after earlier-then-later: PauseUntil = %s, want %s", st.PauseUntil, later)
	}

	g2 := New(testHost, 1, 1000, 1000)
	g2.Penalty(later)
	g2.Penalty(earlier)
	st = g2.State()
	if !st.PauseUntil.Equal(later) {
		t.Errorf("after later-then-earlier: PauseUntil = %s, want %s", st.PauseUntil, later)
	}
}

// TestPenalty_PastIsNoop verifies that a Penalty with a deadline in
// the past doesn't block subsequent Acquires.
func TestPenalty_PastIsNoop(t *testing.T) {
	g := New(testHost, 1, 1000, 1000)
	g.Penalty(time.Now().Add(-time.Hour))
	g.Penalty(time.Time{})

	start := time.Now()
	rel, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	rel()
	if time.Since(start) > 50*time.Millisecond {
		t.Errorf("past Penalty blocked Acquire; took %s", time.Since(start))
	}
	if !g.State().PauseUntil.IsZero() {
		t.Errorf("PauseUntil = %s, want zero", g.State().PauseUntil)
	}
}

// TestAcquire_ContextCancel verifies that a goroutine waiting in
// Acquire on a pause window returns ctx.Err() when the context is
// cancelled — no leaked goroutine, no leaked slot.
func TestAcquire_ContextCancel(t *testing.T) {
	g := New(testHost, 1, 1000, 1000)
	g.Penalty(time.Now().Add(5 * time.Second))

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := g.Acquire(ctx)
		done <- err
	}()

	// Give the goroutine a moment to enter the pause wait.
	time.Sleep(20 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("Acquire err = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Acquire did not return after cancel")
	}

	// The cancelled Acquire must not have consumed a concurrency slot.
	st := g.State()
	if st.Inflight != 0 {
		t.Errorf("Inflight after cancel = %d, want 0", st.Inflight)
	}
}

// TestRelease_Idempotent verifies that calling the returned release
// function multiple times does not blow up or under-count the slot.
func TestRelease_Idempotent(t *testing.T) {
	g := New(testHost, 2, 1000, 1000)
	rel, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	rel()
	rel() // double release must be a no-op
	rel()
	if got := g.State().Inflight; got != 0 {
		t.Errorf("Inflight = %d, want 0", got)
	}
}

// TestParseRetryAfter is the table-driven coverage for the Retry-After
// header parser, including delta-seconds, HTTP-date, and edge cases.
func TestParseRetryAfter(t *testing.T) {
	now := time.Date(2026, 5, 24, 12, 0, 0, 0, time.UTC)

	tests := []struct {
		name   string
		header string
		want   time.Time
		wantOK bool
	}{
		{"empty", "", time.Time{}, false},
		{"whitespace", "   ", time.Time{}, false},
		{"zero seconds", "0", now, true},
		{"five seconds", "5", now.Add(5 * time.Second), true},
		{"large seconds", "3600", now.Add(time.Hour), true},
		{"negative seconds", "-5", time.Time{}, false},
		{"non-numeric junk", "soon-ish", time.Time{}, false},
		{
			name:   "rfc1123 date in future",
			header: "Sun, 24 May 2026 12:00:30 GMT",
			want:   time.Date(2026, 5, 24, 12, 0, 30, 0, time.UTC),
			wantOK: true,
		},
		{
			name:   "rfc1123 date in past",
			header: "Sun, 24 May 2026 11:59:59 GMT",
			want:   time.Time{},
			wantOK: false,
		},
		{
			name:   "rfc850 date in future",
			header: "Sunday, 24-May-26 12:01:00 GMT",
			want:   time.Date(2026, 5, 24, 12, 1, 0, 0, time.UTC),
			wantOK: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := ParseRetryAfter(tc.header, now)
			if ok != tc.wantOK {
				t.Errorf("ok = %v, want %v", ok, tc.wantOK)
			}
			if !got.Equal(tc.want) {
				t.Errorf("got = %s, want %s", got, tc.want)
			}
		})
	}
}

