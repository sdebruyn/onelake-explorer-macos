package httpgate

import (
	"sort"
	"sync"
	"time"
)

// Defaults configures fall-back values used when [Registry.Gate] is
// asked for a host that was never explicitly [Registry.Register]ed.
// Picking conservative defaults here means an unknown host gets some
// throttling rather than none — useful when a code path forgets to
// pre-register.
type Defaults struct {
	// Concurrency caps in-flight requests for an auto-created gate.
	Concurrency int
	// QPS is the steady-state throughput for an auto-created gate.
	QPS float64
	// Burst is the token-bucket capacity for an auto-created gate.
	Burst int
	// MissingRetryAfter is the pause applied when the server returns
	// 429/503 without a Retry-After header. Zero disables the fallback
	// — only honoured headers trigger a pause.
	MissingRetryAfter time.Duration
}

// Registry is the process-wide map of host -> [Gate]. It is constructed
// once at process start (see cmd/ofem) and shared between the Fabric
// and OneLake clients so both hosts coordinate through a single source
// of truth.
//
// Registry is safe for concurrent use.
type Registry struct {
	defaults Defaults

	mu    sync.RWMutex
	gates map[string]*Gate
}

// NewRegistry builds an empty Registry with the given defaults applied
// to lazily-created gates. Pre-register expected hosts with
// [Registry.Register] for predictable QPS budgets.
func NewRegistry(defaults Defaults) *Registry {
	if defaults.Concurrency < 1 {
		defaults.Concurrency = 1
	}
	if defaults.QPS <= 0 {
		defaults.QPS = 1
	}
	if defaults.Burst < 1 {
		defaults.Burst = 1
	}
	return &Registry{
		defaults: defaults,
		gates:    make(map[string]*Gate),
	}
}

// Defaults returns the registry's configured defaults. Useful when
// callers need to compute a missing-Retry-After fallback identical to
// what an auto-created gate would use.
func (r *Registry) Defaults() Defaults { return r.defaults }

// Register installs or replaces a gate for host with explicit budgets.
// Replacing an existing host wipes any current pause window for that
// gate — call it at start-up only.
func (r *Registry) Register(host string, concurrency int, qps float64, burst int) *Gate {
	g := New(host, concurrency, qps, burst)
	r.mu.Lock()
	defer r.mu.Unlock()
	r.gates[host] = g
	return g
}

// Gate returns the gate for host, creating one with the registry's
// defaults if none was previously registered. Always returns non-nil.
//
// The double-checked locking pattern (RLock fast path, then Lock to
// create) keeps the hot path (host is known) lock-free for writers.
func (r *Registry) Gate(host string) *Gate {
	r.mu.RLock()
	if g, ok := r.gates[host]; ok {
		r.mu.RUnlock()
		return g
	}
	r.mu.RUnlock()

	r.mu.Lock()
	defer r.mu.Unlock()
	// Re-check under write lock; another goroutine may have created
	// the gate while we were upgrading.
	if g, ok := r.gates[host]; ok {
		return g
	}
	g := New(host, r.defaults.Concurrency, r.defaults.QPS, r.defaults.Burst)
	r.gates[host] = g
	return g
}

// States returns a snapshot of every gate's [State], sorted by host so
// the IPC output is deterministic.
func (r *Registry) States() []State {
	r.mu.RLock()
	out := make([]State, 0, len(r.gates))
	for _, g := range r.gates {
		out = append(out, g.State())
	}
	r.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool { return out[i].Host < out[j].Host })
	return out
}
