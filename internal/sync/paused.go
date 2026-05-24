package sync

import (
	"context"
	"errors"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpretry"
)

// DefaultPausedProbeInterval is the minimum gap between two recovery
// probes for the same paused workspace. The interval is chosen long
// enough that a paused capacity does not see a burst of probes from
// every Finder click but short enough that the user sees the workspace
// come back to life within a few minutes of the admin resuming it.
const DefaultPausedProbeInterval = 2 * time.Minute

// pausedCapacityRE matches the human-readable phrases Fabric returns
// when a workspace's backing capacity is paused or suspended. The
// service's `errorCode` is the canonical signal, but the message is
// often the only thing surfaced through the DFS endpoint, so we accept
// either.
//
// Phrases come from docs/onelake-api.md and the Microsoft Learn
// troubleshooting pages: "Fabric capacity is currently paused",
// "Capacity Not Active", "capacity is paused", "capacity is not active".
var pausedCapacityRE = regexp.MustCompile(
	`(?i)(capacity\s+not\s+active|capacity\s+is\s+not\s+active|fabric\s+capacity\s+is\s+(currently\s+)?paused|capacity\s+is\s+(currently\s+)?paused|capacity\s+suspended|capacity\s+has\s+been\s+paused)`,
)

// pausedErrorCodes lists the stable Fabric REST `errorCode` values that
// signal a paused / suspended Fabric capacity. The list is intentionally
// inclusive — when in doubt, treat as paused rather than crash a Finder
// enumeration loop on a workspace that is simply down for maintenance.
var pausedErrorCodes = map[string]struct{}{
	"capacitypaused":           {},
	"capacitysuspended":        {},
	"capacitynotactive":        {},
	"workspacecapacitypaused":  {},
	"capacityassignmentpaused": {},
}

// IsPausedCapacityError reports whether err carries a signal that the
// caller's workspace is sitting on a paused / suspended Fabric capacity.
// The check looks at the [httpretry.APIError] body for either the
// `errorCode` field (canonical) or the human-readable message (fallback).
// Returns false for nil and for non-APIError values.
func IsPausedCapacityError(err error) bool {
	if err == nil {
		return false
	}
	var ae *httpretry.APIError
	if !errors.As(err, &ae) {
		return false
	}
	// Paused capacity is most often surfaced as 403 (Fabric REST) or 503
	// (OneLake DFS), but the service has been observed to use other 4xx
	// codes too. Decide on the body, not the status, so a server-side
	// change of HTTP code does not silently break the detector.
	body := strings.ToLower(string(ae.Body))
	if pausedCapacityRE.MatchString(body) {
		return true
	}
	// Extract a JSON `errorCode` value without parsing the entire body —
	// fabric error responses always wrap it in double quotes so a small
	// substring scan is enough and avoids pulling encoding/json into the
	// retry hot path.
	if code := extractErrorCode(body); code != "" {
		if _, ok := pausedErrorCodes[strings.ToLower(code)]; ok {
			return true
		}
	}
	return false
}

// extractErrorCode pulls the value of a JSON `"errorCode": "<v>"` field
// from body. It tolerates extra whitespace and the surrounding object.
// Returns "" when the field is absent. Body is expected to be
// lower-cased by the caller for case-insensitive matching.
func extractErrorCode(body string) string {
	const key = `"errorcode"`
	idx := strings.Index(body, key)
	if idx < 0 {
		return ""
	}
	tail := body[idx+len(key):]
	// Skip whitespace then a colon.
	i := 0
	for i < len(tail) && (tail[i] == ' ' || tail[i] == '\t') {
		i++
	}
	if i >= len(tail) || tail[i] != ':' {
		return ""
	}
	i++
	for i < len(tail) && (tail[i] == ' ' || tail[i] == '\t') {
		i++
	}
	if i >= len(tail) || tail[i] != '"' {
		return ""
	}
	i++
	end := strings.IndexByte(tail[i:], '"')
	if end < 0 {
		return ""
	}
	return tail[i : i+end]
}

// pausedTracker memoises in-flight recovery probes so concurrent
// callers do not stampede the same workspace. The map is keyed by
// (alias, workspaceID).
type pausedTracker struct {
	mu       sync.Mutex
	inflight map[string]struct{}
}

func newPausedTracker() *pausedTracker {
	return &pausedTracker{inflight: make(map[string]struct{})}
}

// claim returns true if the caller may run a probe for k and is then
// responsible for calling release. Returns false when another goroutine
// already holds the slot.
func (t *pausedTracker) claim(alias, workspaceID string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	key := alias + "/" + workspaceID
	if _, ok := t.inflight[key]; ok {
		return false
	}
	t.inflight[key] = struct{}{}
	return true
}

func (t *pausedTracker) release(alias, workspaceID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.inflight, alias+"/"+workspaceID)
}

// markPausedIfNeeded inspects err and, when it indicates a paused
// capacity, persists the workspace_status row so the next call short-
// circuits. Returns true when err was the paused signal.
func (e *Engine) markPausedIfNeeded(ctx context.Context, alias, workspaceID string, err error) bool {
	if !IsPausedCapacityError(err) {
		return false
	}
	now := e.now()
	setErr := e.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: alias,
		WorkspaceID:  workspaceID,
		State:        cache.WorkspaceStatePaused,
		Reason:       "capacity_paused",
		DetectedAt:   now,
	})
	if setErr != nil {
		e.logger.Warn("paused-capacity detected; failed to persist workspace_status",
			slog.String("alias", alias),
			slog.String("workspace", workspaceID),
			slog.Any("err", setErr),
		)
	} else {
		e.logger.Info("workspace marked paused",
			slog.String("alias", alias),
			slog.String("workspace", workspaceID),
		)
	}
	return true
}

// workspacePaused returns true when the cache reports the workspace as
// currently paused. Errors reading the row are not fatal — we fall back
// to "not paused" so a transient SQLite issue cannot brick a Finder
// enumeration.
func (e *Engine) workspacePaused(ctx context.Context, alias, workspaceID string) (cache.WorkspaceStatus, bool) {
	if alias == "" || workspaceID == "" {
		return cache.WorkspaceStatus{}, false
	}
	st, err := e.cache.GetWorkspaceStatus(ctx, alias, workspaceID)
	if err != nil {
		return cache.WorkspaceStatus{}, false
	}
	return st, st.State == cache.WorkspaceStatePaused
}

// probePausedWorkspace performs a single cheap probe against a paused
// workspace. The probe is a HEAD against the filesystem root via the
// OneLake DFS endpoint: it is the cheapest call OneLake exposes and is
// the same surface that Finder hits during enumeration, so a successful
// probe is a strong signal that subsequent reads will succeed.
//
// Returns true when the workspace is reachable again (cache row is
// flipped to active before returning). Returns false when the probe
// confirms the workspace is still paused or when the probe is skipped
// because the previous probe ran too recently / another caller already
// has one in flight.
func (e *Engine) probePausedWorkspace(ctx context.Context, alias, workspaceID string) bool {
	if alias == "" || workspaceID == "" {
		return false
	}
	st, ok := e.workspacePaused(ctx, alias, workspaceID)
	if !ok {
		return true
	}
	if !st.ProbedAt.IsZero() && e.now().Sub(st.ProbedAt) < e.pausedProbeInterval {
		return false
	}
	if !e.pausedTracker.claim(alias, workspaceID) {
		return false
	}
	defer e.pausedTracker.release(alias, workspaceID)

	// Re-check after claiming the slot in case another goroutine
	// recovered the workspace while we were waiting on the lock.
	if st, ok := e.workspacePaused(ctx, alias, workspaceID); !ok {
		return true
	} else if !st.ProbedAt.IsZero() && e.now().Sub(st.ProbedAt) < e.pausedProbeInterval {
		return false
	}

	_, probeErr := e.onelake.GetProperties(ctx, alias, workspaceID, workspaceID, "")
	now := e.now()
	if probeErr == nil {
		// HEAD returned 2xx → workspace is reachable again.
		if err := e.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
			AccountAlias: alias,
			WorkspaceID:  workspaceID,
			State:        cache.WorkspaceStateActive,
			DetectedAt:   now,
			ProbedAt:     now,
		}); err != nil {
			e.logger.Warn("paused-capacity probe recovered but persist failed",
				slog.String("alias", alias), slog.String("workspace", workspaceID),
				slog.Any("err", err))
		} else {
			e.logger.Info("workspace recovered from paused state",
				slog.String("alias", alias), slog.String("workspace", workspaceID))
		}
		return true
	}
	// Non-2xx probe response: stay paused regardless of the specific
	// error. Recovery only flips on a clean 2xx; anything else keeps
	// the workspace marked paused and refreshes ProbedAt so the next
	// probe respects the minimum interval. This avoids flipping back
	// to active on transient errors (404 mid-rotation, 5xx between
	// pause and the actual recovery, …).
	_ = e.cache.SetWorkspaceStatus(ctx, cache.WorkspaceStatus{
		AccountAlias: alias,
		WorkspaceID:  workspaceID,
		State:        cache.WorkspaceStatePaused,
		Reason:       st.Reason,
		DetectedAt:   st.DetectedAt,
		ProbedAt:     now,
	})
	return false
}

// ErrWorkspacePaused is returned by sync operations when the engine
// short-circuits because the cache reports the workspace as paused.
// Callers can use [errors.Is] to skip retry without inspecting the
// error message.
var ErrWorkspacePaused = errors.New("sync: workspace capacity is paused")

// guardPausedWorkspace is the read-path entry point that decides
// whether to even attempt an outbound call. It returns ErrWorkspacePaused
// when the workspace is known-paused AND the most recent probe is too
// recent to retry, signalling the caller to skip the network round-trip.
//
// Concurrent callers triggering a probe at the same time are serialised
// by the pausedTracker; one probe runs, the rest see the freshly
// recovered (or still-paused) state.
func (e *Engine) guardPausedWorkspace(ctx context.Context, alias, workspaceID string) error {
	if _, paused := e.workspacePaused(ctx, alias, workspaceID); !paused {
		return nil
	}
	if e.probePausedWorkspace(ctx, alias, workspaceID) {
		return nil
	}
	return ErrWorkspacePaused
}
