package cache

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"time"
)

// WorkspaceState enumerates the persisted workspace availability flags.
// Values are stable, lower-case strings so the on-disk schema does not
// drift when a new state is added.
type WorkspaceState string

const (
	// WorkspaceStateActive is the default for any workspace the engine
	// can read/write against. A row in this state is equivalent to a
	// missing row; the engine still upserts it during recovery so the
	// transition timeline is observable.
	WorkspaceStateActive WorkspaceState = "active"

	// WorkspaceStatePaused marks a workspace as currently unable to
	// accept reads or writes. The sync engine sets this when an API
	// response signals a paused / suspended Fabric capacity and the
	// adaptive poller skips the workspace until a probe succeeds.
	WorkspaceStatePaused WorkspaceState = "paused"
)

// WorkspaceStatus is the persisted view of one workspace's availability.
// Zero-value times encode "never set" and are stored as 0 nanoseconds.
type WorkspaceStatus struct {
	AccountAlias string
	WorkspaceID  string
	State        WorkspaceState
	// Reason is a short, machine-friendly string describing why the
	// workspace landed in its current state (e.g. "capacity_paused").
	// Empty when State is Active.
	Reason string
	// DetectedAt is the wall-clock timestamp at which State was first
	// observed (or last transitioned into) for this workspace.
	DetectedAt time.Time
	// ProbedAt is the wall-clock timestamp at which the engine last ran
	// a recovery probe against this workspace. Zero when no probe has
	// run yet.
	ProbedAt time.Time
}

// SetWorkspaceStatus upserts the workspace_status row for (alias,
// workspaceID). When the row already exists and the new state matches
// the persisted one, DetectedAt is preserved (the workspace has been
// paused continuously); on a state change the new DetectedAt is
// recorded so callers can compute "paused for N minutes".
//
// ProbedAt is updated to the value in s unless s.ProbedAt is zero, in
// which case the persisted value is preserved.
func (c *Cache) SetWorkspaceStatus(ctx context.Context, s WorkspaceStatus) error {
	if s.AccountAlias == "" {
		return errors.New("cache.SetWorkspaceStatus: AccountAlias is required")
	}
	if s.WorkspaceID == "" {
		return errors.New("cache.SetWorkspaceStatus: WorkspaceID is required")
	}
	if s.State == "" {
		return errors.New("cache.SetWorkspaceStatus: State is required")
	}

	tx, err := c.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("cache.SetWorkspaceStatus: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var (
		existingState      sql.NullString
		existingDetectedNs sql.NullInt64
		existingProbedNs   sql.NullInt64
	)
	err = tx.QueryRowContext(ctx, `
SELECT state, detected_at_ns, probed_at_ns FROM workspace_status
WHERE account_alias = ? AND workspace_id = ?
`, s.AccountAlias, s.WorkspaceID).Scan(&existingState, &existingDetectedNs, &existingProbedNs)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("cache.SetWorkspaceStatus: select: %w", err)
	}

	detectedNs := timeToNs(s.DetectedAt)
	if existingState.Valid && WorkspaceState(existingState.String) == s.State && existingDetectedNs.Valid && existingDetectedNs.Int64 > 0 {
		detectedNs = existingDetectedNs.Int64
	}
	probedNs := timeToNs(s.ProbedAt)
	if probedNs == 0 && existingProbedNs.Valid {
		probedNs = existingProbedNs.Int64
	}

	if _, err := tx.ExecContext(ctx, `
INSERT INTO workspace_status (account_alias, workspace_id, state, reason, detected_at_ns, probed_at_ns)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (account_alias, workspace_id) DO UPDATE SET
    state          = excluded.state,
    reason         = excluded.reason,
    detected_at_ns = excluded.detected_at_ns,
    probed_at_ns   = excluded.probed_at_ns
`, s.AccountAlias, s.WorkspaceID, string(s.State), s.Reason, detectedNs, probedNs); err != nil {
		return fmt.Errorf("cache.SetWorkspaceStatus: exec: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("cache.SetWorkspaceStatus: commit: %w", err)
	}
	return nil
}

// GetWorkspaceStatus reads the persisted status for (alias, workspaceID).
// Returns a wrapped [os.ErrNotExist] when no row exists; callers should
// treat that as "active" (the default zero value would also work).
func (c *Cache) GetWorkspaceStatus(ctx context.Context, alias, workspaceID string) (WorkspaceStatus, error) {
	if alias == "" || workspaceID == "" {
		return WorkspaceStatus{}, errors.New("cache.GetWorkspaceStatus: alias and workspaceID are required")
	}
	var (
		out        WorkspaceStatus
		state      string
		reason     string
		detectedNs int64
		probedNs   int64
	)
	out.AccountAlias = alias
	out.WorkspaceID = workspaceID
	err := c.db.QueryRowContext(ctx, `
SELECT state, reason, detected_at_ns, probed_at_ns FROM workspace_status
WHERE account_alias = ? AND workspace_id = ?
`, alias, workspaceID).Scan(&state, &reason, &detectedNs, &probedNs)
	if errors.Is(err, sql.ErrNoRows) {
		return out, fmt.Errorf("cache.GetWorkspaceStatus: %w", os.ErrNotExist)
	}
	if err != nil {
		return out, fmt.Errorf("cache.GetWorkspaceStatus: scan: %w", err)
	}
	out.State = WorkspaceState(state)
	out.Reason = reason
	out.DetectedAt = nsToTime(detectedNs)
	out.ProbedAt = nsToTime(probedNs)
	return out, nil
}

// ListWorkspaceStatuses returns every persisted workspace status row,
// ordered by (account_alias, workspace_id) for deterministic output.
// Useful for IPC status responses and tests.
func (c *Cache) ListWorkspaceStatuses(ctx context.Context) ([]WorkspaceStatus, error) {
	rows, err := c.db.QueryContext(ctx, `
SELECT account_alias, workspace_id, state, reason, detected_at_ns, probed_at_ns
FROM workspace_status
ORDER BY account_alias, workspace_id
`)
	if err != nil {
		return nil, fmt.Errorf("cache.ListWorkspaceStatuses: query: %w", err)
	}
	defer func() { _ = rows.Close() }()

	out := make([]WorkspaceStatus, 0)
	for rows.Next() {
		var (
			ws         WorkspaceStatus
			state      string
			detectedNs int64
			probedNs   int64
		)
		if err := rows.Scan(&ws.AccountAlias, &ws.WorkspaceID, &state, &ws.Reason, &detectedNs, &probedNs); err != nil {
			return nil, fmt.Errorf("cache.ListWorkspaceStatuses: scan: %w", err)
		}
		ws.State = WorkspaceState(state)
		ws.DetectedAt = nsToTime(detectedNs)
		ws.ProbedAt = nsToTime(probedNs)
		out = append(out, ws)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("cache.ListWorkspaceStatuses: rows: %w", err)
	}
	return out, nil
}
