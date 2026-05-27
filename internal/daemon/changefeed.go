package daemon

import (
	"sync"
	"time"
)

// maxFeedEvents is the upper bound on events retained in the in-memory
// feed. When the bound is reached the oldest events are dropped and the
// next Since call that would have returned them instead returns a
// full-resync hint via FullResync=true, so the host app can signal every
// known container rather than only the changed ones.
const maxFeedEvents = 10_000

// ChangeEvent is one entry in the change feed: a single container inside
// a domain whose content may have changed since the previous poll.
type ChangeEvent struct {
	// Domain is the File Provider domain identifier, e.g. "ofem.work".
	Domain string
	// ContainerID is the NSFileProviderItemIdentifier of the container
	// that changed. May be the working-set identifier or any folder
	// container.
	ContainerID string
	// OccurredAt is when the daemon detected the change.
	OccurredAt time.Time
}

// PollChangesResult is the response payload for the sync.pollChanges RPC.
type PollChangesResult struct {
	// Events contains the set of (domain, containerID) pairs that changed
	// since the anchor. Duplicates may appear; the caller should
	// deduplicate before calling signalEnumerator.
	Events []ChangeEvent `json:"events"`
	// Anchor is the new watermark the caller should pass in the next
	// sync.pollChanges request.
	Anchor time.Time `json:"anchor"`
	// FullResync is true when events were dropped due to the feed
	// exceeding maxFeedEvents. The caller should signal every known
	// container rather than only the events in this response.
	FullResync bool `json:"fullResync"`
}

// Changefeed is a bounded in-memory ring of ChangeEvents. It is safe for
// concurrent use. Events are appended by the adaptive poller and consumed
// by the host app via the sync.pollChanges RPC.
//
// The feed is lost when the daemon restarts; the host app's ChangeWatcher
// detects the disconnect, reconnects, and issues an initial poll with a
// zero anchor so it receives all events that accumulated since the last
// restart (which will be empty because the daemon's feed is fresh).
// The host app then signals a full-resync — signalling every known
// container — to recover any changes missed during the downtime.
type Changefeed struct {
	mu        sync.Mutex
	events    []ChangeEvent
	truncated bool // true if events were dropped due to maxFeedEvents
}

// NewChangefeed allocates a ready-to-use Changefeed.
func NewChangefeed() *Changefeed {
	return &Changefeed{}
}

// Publish appends an event to the feed. If the feed would exceed
// maxFeedEvents, the oldest half is dropped and the truncated flag is
// set so the next Since call reports FullResync.
func (cf *Changefeed) Publish(domain, containerID string, ts time.Time) {
	cf.mu.Lock()
	defer cf.mu.Unlock()

	cf.events = append(cf.events, ChangeEvent{
		Domain:      domain,
		ContainerID: containerID,
		OccurredAt:  ts,
	})

	if len(cf.events) > maxFeedEvents {
		// Drop the oldest half to amortise the cost of future evictions.
		keep := maxFeedEvents / 2
		cf.events = cf.events[len(cf.events)-keep:]
		cf.truncated = true
	}
}

// Since returns all events that occurred strictly after anchor, plus the
// new anchor the caller should pass on the next call.
//
// When FullResync is true the caller should signal every known container
// because some events were evicted from the feed.
func (cf *Changefeed) Since(anchor time.Time) PollChangesResult {
	cf.mu.Lock()
	defer cf.mu.Unlock()

	var out []ChangeEvent
	newAnchor := anchor

	for _, ev := range cf.events {
		if ev.OccurredAt.After(anchor) {
			out = append(out, ev)
			if ev.OccurredAt.After(newAnchor) {
				newAnchor = ev.OccurredAt
			}
		}
	}

	full := cf.truncated
	// Reset the truncation flag once we've reported it so subsequent polls
	// don't trigger redundant full-resyncs.
	cf.truncated = false

	return PollChangesResult{
		Events:     out,
		Anchor:     newAnchor,
		FullResync: full,
	}
}
