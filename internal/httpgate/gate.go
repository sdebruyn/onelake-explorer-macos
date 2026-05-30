package httpgate

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Gate is the per-host coordinator.
//
// A Gate combines three throttles, applied in order on every Acquire:
//
//  1. The pause window. If [Gate.Penalty] was called with a deadline in
//     the future, Acquire blocks until that deadline passes. All callers
//     share the same deadline, so a single 429 stalls every other
//     in-flight request against the host.
//  2. The concurrency cap. Only concurrency callers may hold the gate
//     at once; further Acquires block until a previous release.
//  3. The token-bucket QPS budget. After the pause clears, callers leave
//     the gate at qps per second with the configured burst — this is
//     what smears a wave of retries instead of releasing them at once.
//
// Construct with [New]. The zero value is not usable.
type Gate struct {
	host        string
	concurrency int
	qps         float64
	burst       int

	limiter *rate.Limiter
	sem     chan struct{}

	mu         sync.Mutex
	pauseUntil time.Time
}

// New builds a Gate for host with the given concurrency cap, steady-
// state qps budget and burst capacity. Invalid values (concurrency < 1,
// qps <= 0, burst < 1) are clamped to sensible minimums so callers can
// pass zero defaults without having to special-case them.
func New(host string, concurrency int, qps float64, burst int) *Gate {
	if concurrency < 1 {
		concurrency = 1
	}
	if qps <= 0 {
		qps = 1
	}
	if burst < 1 {
		burst = 1
	}
	return &Gate{
		host:        host,
		concurrency: concurrency,
		qps:         qps,
		burst:       burst,
		limiter:     rate.NewLimiter(rate.Limit(qps), burst),
		sem:         make(chan struct{}, concurrency),
	}
}

// Host returns the host this gate guards. Useful for logging and the
// IPC status surface.
func (g *Gate) Host() string { return g.host }

// Acquire reserves one slot on the gate. It blocks until:
//
//   - the current pause window (if any) has elapsed,
//   - the concurrency cap admits one more in-flight caller, and
//   - the token bucket grants a token.
//
// The returned release function MUST be called exactly once when the
// round trip completes (success or failure). Forgetting to release
// leaks one concurrency slot for the lifetime of the process. release
// is idempotent — calling it twice is a no-op — so it is safe to defer.
//
// If ctx is cancelled while waiting, Acquire returns ctx.Err() and
// release is the no-op function (still safe to call).
func (g *Gate) Acquire(ctx context.Context) (release func(), err error) {
	// 1. Wait out any pending pause window first. We loop because a
	// concurrent Penalty during the wait may extend the deadline.
	if err := g.waitPause(ctx); err != nil {
		return func() {}, err
	}

	// 2. Reserve a concurrency slot.
	select {
	case g.sem <- struct{}{}:
	case <-ctx.Done():
		return func() {}, ctx.Err()
	}

	// 3. Wait for a token. The token bucket is what prevents the
	// post-pause stampede — even if every waiter clears step 1 at the
	// same instant, only qps tokens per second are issued.
	if err := g.limiter.Wait(ctx); err != nil {
		// Give the slot back; the caller never got to use it.
		<-g.sem
		return func() {}, err
	}

	// 4. Re-check the pause window. A Penalty posted between step 1 and
	// step 3 must still hold this caller back, otherwise it could
	// stampede past a freshly applied throttle.
	if err := g.waitPause(ctx); err != nil {
		<-g.sem
		return func() {}, err
	}

	var once sync.Once
	return func() {
		once.Do(func() {
			<-g.sem
		})
	}, nil
}

// waitPause blocks until the configured pauseUntil deadline (if any)
// has passed. Each iteration re-reads the deadline under the lock so a
// concurrent Penalty that extends it is honoured.
func (g *Gate) waitPause(ctx context.Context) error {
	for {
		g.mu.Lock()
		until := g.pauseUntil
		g.mu.Unlock()

		wait := time.Until(until)
		if wait <= 0 {
			return nil
		}

		t := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			t.Stop()
			return ctx.Err()
		case <-t.C:
			// Loop and re-read the deadline in case it was extended.
		}
	}
}

// Penalty closes the gate until t. The latest of all posted deadlines
// wins; a Penalty whose deadline is earlier than (or equal to) the
// currently-stored one is dropped. A Penalty for a time in the past
// (or zero) is a no-op and logged at debug.
//
// Penalty does NOT block. Callers waiting in Acquire wake on the timer
// they armed; the next iteration of waitPause picks up the new deadline.
func (g *Gate) Penalty(until time.Time) {
	if until.IsZero() || time.Until(until) <= 0 {
		slog.Debug("httpgate: penalty in past, ignored",
			slog.String("host", g.host),
			slog.Time("until", until),
		)
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if until.After(g.pauseUntil) {
		prev := g.pauseUntil
		g.pauseUntil = until
		slog.Info("httpgate: pause window applied",
			slog.String("host", g.host),
			slog.Duration("for", time.Until(until)),
			slog.Time("previous_until", prev),
		)
	}
}

// State is a snapshot of the gate's internal counters. Returned by
// [Gate.State] and consumed by the IPC status endpoint.
type State struct {
	// Host is the host the gate guards.
	Host string `json:"host"`
	// PauseUntil is the current pause deadline. Zero when not paused.
	PauseUntil time.Time `json:"pauseUntil,omitempty"`
	// Inflight is the number of in-flight callers holding the gate.
	Inflight int `json:"inflight"`
	// Concurrency is the configured upper bound on Inflight.
	Concurrency int `json:"concurrency"`
	// Available is the integer number of tokens currently available
	// in the bucket. Reading the bucket does not consume tokens.
	Available int `json:"available"`
	// Burst is the configured upper bound on Available.
	Burst int `json:"burst"`
	// QPS is the configured steady-state throughput.
	QPS float64 `json:"qps"`
}

// State returns a snapshot of the gate counters. Cheap; safe to call
// from a status handler on every IPC request.
func (g *Gate) State() State {
	g.mu.Lock()
	pause := g.pauseUntil
	g.mu.Unlock()

	// rate.Limiter.Tokens reads state without mutating.
	tokens := g.limiter.Tokens()
	if tokens < 0 {
		tokens = 0
	}
	if tokens > float64(g.burst) {
		tokens = float64(g.burst)
	}

	// len() on a channel is safe to call from any goroutine, but the
	// returned value has no happens-before relationship with concurrent
	// send/receive ops — Inflight is a best-effort snapshot, fine for
	// status display but NOT load-bearing for control flow.
	inflight := len(g.sem)

	return State{
		Host:        g.host,
		PauseUntil:  pause,
		Inflight:    inflight,
		Concurrency: g.concurrency,
		Available:   int(tokens),
		Burst:       g.burst,
		QPS:         g.qps,
	}
}

// String renders the gate's state in a compact, human-friendly form.
// Useful for debug output and log lines.
func (s State) String() string {
	return fmt.Sprintf("%s %s", s.Host, s.summary())
}

// summary renders everything after the host column — used by
// [State.String] and by [State.Summary] so the format lives in one
// place. Callers that align the host column themselves can use
// [State.Summary] and prepend s.Host on their own.
func (s State) summary() string {
	paused := "no"
	if d := time.Until(s.PauseUntil); d > 0 {
		paused = fmt.Sprintf("for %s", d.Round(time.Second))
	}
	return fmt.Sprintf("inflight=%d/%d tokens=%d/%d paused: %s",
		s.Inflight, s.Concurrency, s.Available, s.Burst, paused)
}

// Summary returns the per-host gate summary without the host prefix,
// suitable for callers that need to align the host column themselves.
func (s State) Summary() string { return s.summary() }
