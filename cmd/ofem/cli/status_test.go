package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
)

// TestPrintGates_NoPause renders a two-host gate snapshot without any
// active pause. Asserts the exact format the design doc specifies and
// the host-column alignment.
func TestPrintGates_NoPause(t *testing.T) {
	var buf bytes.Buffer
	printGates(&buf, []httpgate.State{
		{
			Host:     "api.fabric.microsoft.com",
			Inflight: 3, Concurrency: 8,
			Available: 2, Burst: 4,
			QPS: 2,
		},
		{
			Host:     "onelake.dfs.fabric.microsoft.com",
			Inflight: 12, Concurrency: 16,
			Available: 4, Burst: 16,
			QPS: 8,
		},
	})
	got := buf.String()
	wantLines := []string{
		"Gates:",
		"api.fabric.microsoft.com         inflight=3/8 tokens=2/4 paused: no",
		"onelake.dfs.fabric.microsoft.com inflight=12/16 tokens=4/16 paused: no",
	}
	for _, ln := range wantLines {
		if !strings.Contains(got, ln) {
			t.Errorf("missing line %q in:\n%s", ln, got)
		}
	}
}

// TestPrintGates_WithPause renders an active pause window and checks
// the "paused: for <duration>" branch.
func TestPrintGates_WithPause(t *testing.T) {
	var buf bytes.Buffer
	printGates(&buf, []httpgate.State{
		{
			Host:     "onelake.dfs.fabric.microsoft.com",
			Inflight: 12, Concurrency: 16,
			Available: 4, Burst: 16,
			PauseUntil: time.Now().Add(23 * time.Second),
		},
	})
	got := buf.String()
	if !strings.Contains(got, "paused: for ") {
		t.Errorf("missing paused branch in:\n%s", got)
	}
}

// TestPrintGates_Empty: with no gates, nothing past the heading is
// printed. We intentionally do NOT print "Gates:" when the list is empty
// at the call site (printDaemonStatus only calls printGates when
// len(Gates) > 0), so calling printGates directly with an empty slice
// would still print just the heading. We don't depend on that here.
func TestPrintGates_PadsHostColumn(t *testing.T) {
	var buf bytes.Buffer
	printGates(&buf, []httpgate.State{
		{Host: "short.example.com", Inflight: 0, Concurrency: 1, Available: 1, Burst: 1},
		{Host: "much-longer-host.example.com", Inflight: 0, Concurrency: 1, Available: 1, Burst: 1},
	})
	lines := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
	// Find the data line for "short.example.com" and verify it is
	// padded to the longer hostname's width so columns align.
	if len(lines) < 3 {
		t.Fatalf("expected 3 lines, got %d:\n%s", len(lines), buf.String())
	}
	if !strings.Contains(lines[1], "short.example.com            inflight=") {
		t.Errorf("host column not padded: %q", lines[1])
	}
}
