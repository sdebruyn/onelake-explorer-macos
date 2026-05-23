package telemetry

import (
	"context"
	"sync"
)

// MemorySink is a Sink that appends every event to an in-memory slice.
// It is intended for tests: callers use Drain to inspect what the Client
// would have shipped.
type MemorySink struct {
	mu     sync.Mutex
	events []Event
}

// Send appends events under a mutex.
func (m *MemorySink) Send(_ context.Context, events []Event) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.events = append(m.events, events...)
	return nil
}

// Drain returns and clears the buffered events.
func (m *MemorySink) Drain() []Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := m.events
	m.events = nil
	return out
}

// Len returns the current number of buffered events without draining.
func (m *MemorySink) Len() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.events)
}
