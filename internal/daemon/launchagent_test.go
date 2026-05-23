package daemon

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// stubLaunchctl swaps launchctlRunner for the duration of the test and
// returns a slice that captures every invocation.
func stubLaunchctl(t *testing.T, behavior func(args []string) error) *[][]string {
	t.Helper()
	original := launchctlRunner
	calls := &[][]string{}
	launchctlRunner = func(args []string) error {
		cp := make([]string, len(args))
		copy(cp, args)
		*calls = append(*calls, cp)
		if behavior != nil {
			return behavior(args)
		}
		return nil
	}
	t.Cleanup(func() { launchctlRunner = original })
	return calls
}

func TestRenderLaunchAgentPlistContainsExpectedFields(t *testing.T) {
	t.Parallel()

	params := LaunchAgentParams{
		Label:          "dev.debruyn.ofe.daemon",
		ExecutablePath: "/usr/local/bin/ofe",
		StdoutPath:     "/Users/x/Library/Logs/dev.debruyn.ofe/daemon.stdout.log",
		StderrPath:     "/Users/x/Library/Logs/dev.debruyn.ofe/daemon.stderr.log",
	}
	got, err := RenderLaunchAgentPlist(params)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	s := string(got)
	wants := []string{
		"<key>Label</key>",
		"<string>dev.debruyn.ofe.daemon</string>",
		"<string>/usr/local/bin/ofe</string>",
		"<string>daemon</string>",
		"<string>run</string>",
		"<key>RunAtLoad</key>",
		"<key>KeepAlive</key>",
		"<key>StandardOutPath</key>",
		"<string>/Users/x/Library/Logs/dev.debruyn.ofe/daemon.stdout.log</string>",
		"<key>StandardErrorPath</key>",
		"<string>/Users/x/Library/Logs/dev.debruyn.ofe/daemon.stderr.log</string>",
	}
	for _, w := range wants {
		if !strings.Contains(s, w) {
			t.Errorf("rendered plist missing %q\n--- plist ---\n%s", w, s)
		}
	}
}

func TestInstallLaunchAgentWritesPlistAndBootstraps(t *testing.T) {
	// No t.Parallel(): launchctlRunner is a process-wide global that
	// these tests swap. Running them in parallel races on that global.

	home := t.TempDir()
	paths := config.Paths{
		ConfigDir:  filepath.Join(home, "Library", "Application Support", "dev.debruyn.ofe"),
		ConfigFile: filepath.Join(home, "Library", "Application Support", "dev.debruyn.ofe", "config.toml"),
		CacheDir:   filepath.Join(home, "Library", "Caches", "dev.debruyn.ofe"),
		LogDir:     filepath.Join(home, "Library", "Logs", "dev.debruyn.ofe"),
		SocketPath: filepath.Join(home, "Library", "Application Support", "dev.debruyn.ofe", "ofe.sock"),
	}
	execPath := "/fake/bin/ofe"
	calls := stubLaunchctl(t, nil)

	if err := InstallLaunchAgent(home, paths, execPath); err != nil {
		t.Fatalf("install: %v", err)
	}

	plistPath := LaunchAgentPlistPath(home)
	body, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatalf("read plist: %v", err)
	}
	for _, want := range []string{
		"<string>/fake/bin/ofe</string>",
		"<string>" + filepath.Join(paths.LogDir, "daemon.stdout.log") + "</string>",
		"<string>" + filepath.Join(paths.LogDir, "daemon.stderr.log") + "</string>",
		"<string>dev.debruyn.ofe.daemon</string>",
	} {
		if !strings.Contains(string(body), want) {
			t.Errorf("plist missing %q\n--- plist ---\n%s", want, body)
		}
	}

	if _, err := os.Stat(paths.LogDir); err != nil {
		t.Errorf("LogDir was not created: %v", err)
	}

	if len(*calls) < 2 {
		t.Fatalf("expected at least 2 launchctl calls (bootstrap + enable), got %v", *calls)
	}
	if (*calls)[0][0] != "bootstrap" {
		t.Errorf("first call should be bootstrap, got %v", (*calls)[0])
	}
	if (*calls)[1][0] != "enable" {
		t.Errorf("second call should be enable, got %v", (*calls)[1])
	}
}

func TestInstallLaunchAgentIdempotentWhenAlreadyBootstrapped(t *testing.T) {
	// No t.Parallel(): launchctlRunner is a process-wide global that
	// these tests swap. Running them in parallel races on that global.

	home := t.TempDir()
	paths := config.Paths{
		LogDir:     filepath.Join(home, "logs"),
		ConfigDir:  filepath.Join(home, "cfg"),
		ConfigFile: filepath.Join(home, "cfg", "config.toml"),
		CacheDir:   filepath.Join(home, "cache"),
		SocketPath: filepath.Join(home, "cfg", "ofe.sock"),
	}
	stubLaunchctl(t, func(args []string) error {
		if len(args) > 0 && args[0] == "bootstrap" {
			return errors.New("Bootstrap failed: 37: service already loaded")
		}
		return nil
	})

	if err := InstallLaunchAgent(home, paths, "/fake/bin/ofe"); err != nil {
		t.Fatalf("install should swallow already-bootstrapped: %v", err)
	}
}

func TestInstallLaunchAgentSurfacesUnknownBootstrapError(t *testing.T) {
	// No t.Parallel(): launchctlRunner is a process-wide global that
	// these tests swap. Running them in parallel races on that global.

	home := t.TempDir()
	paths := config.Paths{LogDir: filepath.Join(home, "logs")}
	stubLaunchctl(t, func(args []string) error {
		if len(args) > 0 && args[0] == "bootstrap" {
			return errors.New("Bootstrap failed: 13: unexpected explosion")
		}
		return nil
	})

	err := InstallLaunchAgent(home, paths, "/fake/bin/ofe")
	if err == nil {
		t.Fatalf("expected install to surface unknown bootstrap error")
	}
	if !strings.Contains(err.Error(), "unexpected explosion") {
		t.Errorf("expected error to mention upstream message, got %v", err)
	}
}

func TestUninstallLaunchAgentRemovesPlist(t *testing.T) {
	// No t.Parallel(): launchctlRunner is a process-wide global that
	// these tests swap. Running them in parallel races on that global.

	home := t.TempDir()
	plistDir := LaunchAgentPlistDir(home)
	if err := os.MkdirAll(plistDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	plistPath := LaunchAgentPlistPath(home)
	if err := os.WriteFile(plistPath, []byte("dummy"), 0o644); err != nil {
		t.Fatalf("write plist: %v", err)
	}
	calls := stubLaunchctl(t, nil)

	if err := UninstallLaunchAgent(home); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(plistPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("expected plist to be removed, got stat err = %v", err)
	}
	if len(*calls) < 1 || (*calls)[0][0] != "bootout" {
		t.Errorf("expected bootout call, got %v", *calls)
	}
}

func TestUninstallLaunchAgentIdempotent(t *testing.T) {
	// No t.Parallel(): launchctlRunner is a process-wide global that
	// these tests swap. Running them in parallel races on that global.

	home := t.TempDir()
	stubLaunchctl(t, func(args []string) error {
		if args[0] == "bootout" {
			return errors.New("Could not find specified service")
		}
		return nil
	})
	if err := UninstallLaunchAgent(home); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
}

func TestStartLaunchAgentInvokesKickstart(t *testing.T) {
	// No t.Parallel(): launchctlRunner is process-wide global.
	calls := stubLaunchctl(t, nil)
	if err := StartLaunchAgent(); err != nil {
		t.Fatalf("start: %v", err)
	}
	if len(*calls) != 1 || (*calls)[0][0] != "kickstart" || (*calls)[0][1] != "-k" {
		t.Errorf("expected kickstart -k call, got %v", *calls)
	}
}

func TestStopLaunchAgentSendsSIGTERM(t *testing.T) {
	// No t.Parallel(): launchctlRunner is process-wide global.
	calls := stubLaunchctl(t, nil)
	if err := StopLaunchAgent(); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if len(*calls) != 1 || (*calls)[0][0] != "kill" || (*calls)[0][1] != "SIGTERM" {
		t.Errorf("expected kill SIGTERM call, got %v", *calls)
	}
}
