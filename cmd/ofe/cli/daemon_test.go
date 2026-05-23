package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/daemon"
)

// TestDaemonInstallWritesPlist exercises the `ofe daemon install` CLI
// path under a sandboxed $HOME so the real ~/Library/LaunchAgents/ is
// never touched. launchctl invocations are stubbed at the package level
// via daemon.LaunchctlForTest (see launchagent_test.go) so this test
// does not require a real macOS launchd to be reachable.
func TestDaemonInstallWritesPlist(t *testing.T) {
	// No t.Parallel(): we mutate HOME and the daemon's launchctlRunner
	// global, both process-wide.
	home := t.TempDir()
	t.Setenv("HOME", home)

	daemon.SetLaunchctlForTest(t, func(_ []string) error { return nil })

	root := NewRoot()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	root.SetArgs([]string{"daemon", "install"})

	if err := root.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	if !strings.Contains(buf.String(), "Installed LaunchAgent") {
		t.Errorf("expected success message, got %q", buf.String())
	}

	plistPath := filepath.Join(home, "Library", "LaunchAgents", daemon.LaunchAgentFileName)
	body, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatalf("plist not written: %v", err)
	}
	for _, want := range []string{
		"<key>Label</key>",
		"<string>" + daemon.LaunchAgentLabel + "</string>",
		"<key>RunAtLoad</key>",
		"<key>KeepAlive</key>",
		"<string>daemon</string>",
		"<string>run</string>",
	} {
		if !strings.Contains(string(body), want) {
			t.Errorf("plist missing %q\n--- body ---\n%s", want, body)
		}
	}
}

func TestDaemonUninstallRemovesPlist(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	// Pre-populate a plist so uninstall has something to remove.
	plistDir := filepath.Join(home, "Library", "LaunchAgents")
	if err := os.MkdirAll(plistDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	plistPath := filepath.Join(plistDir, daemon.LaunchAgentFileName)
	if err := os.WriteFile(plistPath, []byte("placeholder"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	daemon.SetLaunchctlForTest(t, func(_ []string) error { return nil })

	root := NewRoot()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	root.SetArgs([]string{"daemon", "uninstall"})

	if err := root.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	if _, err := os.Stat(plistPath); !os.IsNotExist(err) {
		t.Errorf("expected plist removed, got err=%v", err)
	}
}

func TestDaemonStartInvokesLaunchctl(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	var captured [][]string
	daemon.SetLaunchctlForTest(t, func(args []string) error {
		cp := make([]string, len(args))
		copy(cp, args)
		captured = append(captured, cp)
		return nil
	})

	root := NewRoot()
	var buf bytes.Buffer
	root.SetOut(&buf)
	root.SetErr(&buf)
	root.SetArgs([]string{"daemon", "start"})

	if err := root.Execute(); err != nil {
		t.Fatalf("execute: %v", err)
	}
	if len(captured) != 1 || captured[0][0] != "kickstart" {
		t.Errorf("expected kickstart call, got %v", captured)
	}
}
