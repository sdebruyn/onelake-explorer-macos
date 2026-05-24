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
		Label:          "dev.debruyn.ofem.daemon",
		ExecutablePath: "/usr/local/bin/ofem",
		StdoutPath:     "/Users/x/Library/Logs/dev.debruyn.ofem/daemon.stdout.log",
		StderrPath:     "/Users/x/Library/Logs/dev.debruyn.ofem/daemon.stderr.log",
	}
	got, err := RenderLaunchAgentPlist(params)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	s := string(got)
	wants := []string{
		"<key>Label</key>",
		"<string>dev.debruyn.ofem.daemon</string>",
		"<string>/usr/local/bin/ofem</string>",
		"<string>daemon</string>",
		"<string>run</string>",
		"<key>RunAtLoad</key>",
		"<key>KeepAlive</key>",
		"<key>StandardOutPath</key>",
		"<string>/Users/x/Library/Logs/dev.debruyn.ofem/daemon.stdout.log</string>",
		"<key>StandardErrorPath</key>",
		"<string>/Users/x/Library/Logs/dev.debruyn.ofem/daemon.stderr.log</string>",
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
		ConfigDir:  filepath.Join(home, "Library", "Application Support", "dev.debruyn.ofem"),
		ConfigFile: filepath.Join(home, "Library", "Application Support", "dev.debruyn.ofem", "config.toml"),
		CacheDir:   filepath.Join(home, "Library", "Caches", "dev.debruyn.ofem"),
		LogDir:     filepath.Join(home, "Library", "Logs", "dev.debruyn.ofem"),
		SocketPath: filepath.Join(home, "Library", "Application Support", "dev.debruyn.ofem", "ofem.sock"),
	}
	execPath := "/fake/bin/ofem"
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
		"<string>/fake/bin/ofem</string>",
		"<string>" + filepath.Join(paths.LogDir, "daemon.stdout.log") + "</string>",
		"<string>" + filepath.Join(paths.LogDir, "daemon.stderr.log") + "</string>",
		"<string>dev.debruyn.ofem.daemon</string>",
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
		SocketPath: filepath.Join(home, "cfg", "ofem.sock"),
	}
	stubLaunchctl(t, func(args []string) error {
		if len(args) > 0 && args[0] == "bootstrap" {
			return errors.New("Bootstrap failed: 37: service already loaded")
		}
		return nil
	})

	if err := InstallLaunchAgent(home, paths, "/fake/bin/ofem"); err != nil {
		t.Fatalf("install should swallow already-bootstrapped: %v", err)
	}
}

// TestInstallLaunchAgentIdempotentWithRealisticLaunchctlError exercises
// the production code path: realLaunchctl wraps exec.ExitError into a
// *launchctlError carrying the captured stderr ("Bootstrap failed: 37:
// Service is already loaded\n"). This regression test guards against
// the bug where isAlreadyBootstrapped only matched the test stub's
// hand-crafted string but never the real exec error, whose .Error()
// would have been just "exit status 37".
func TestInstallLaunchAgentIdempotentWithRealisticLaunchctlError(t *testing.T) {
	// No t.Parallel(): launchctlRunner is process-wide global.

	home := t.TempDir()
	paths := config.Paths{
		LogDir:     filepath.Join(home, "logs"),
		ConfigDir:  filepath.Join(home, "cfg"),
		ConfigFile: filepath.Join(home, "cfg", "config.toml"),
		CacheDir:   filepath.Join(home, "cache"),
		SocketPath: filepath.Join(home, "cfg", "ofem.sock"),
	}
	stubLaunchctl(t, func(args []string) error {
		if len(args) > 0 && args[0] == "bootstrap" {
			return &launchctlError{
				Args:     args,
				ExitCode: 37,
				Stderr:   "Bootstrap failed: 37: Service is already loaded\n",
				Err:      errors.New("exit status 37"),
			}
		}
		return nil
	})

	if err := InstallLaunchAgent(home, paths, "/fake/bin/ofem"); err != nil {
		t.Fatalf("install should swallow already-bootstrapped launchctlError: %v", err)
	}
}

// TestIsAlreadyBootstrappedRecognisesLaunchctlError verifies the
// exit-code fast path on a *launchctlError even when the stderr text
// is empty (some launchctl invocations only set the code).
func TestIsAlreadyBootstrappedRecognisesLaunchctlError(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"exit code 37 only", &launchctlError{ExitCode: 37, Err: errors.New("exit status 37")}, true},
		{"stderr text", &launchctlError{ExitCode: 1, Stderr: "Bootstrap failed: 37: Service is already loaded", Err: errors.New("exit status 1")}, true},
		{"unrelated error", errors.New("permission denied"), false},
		{"unrelated launchctl exit", &launchctlError{ExitCode: 1, Stderr: "kaboom", Err: errors.New("exit status 1")}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isAlreadyBootstrapped(tc.err); got != tc.want {
				t.Errorf("isAlreadyBootstrapped(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
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

	err := InstallLaunchAgent(home, paths, "/fake/bin/ofem")
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

// writeStubPlist drops an empty placeholder plist at the canonical
// location so the StartLaunchAgent fallback path can stat it.
func writeStubPlist(t *testing.T, home string) {
	t.Helper()
	dir := LaunchAgentPlistDir(home)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir plist dir: %v", err)
	}
	if err := os.WriteFile(LaunchAgentPlistPath(home), []byte("stub"), 0o644); err != nil {
		t.Fatalf("write stub plist: %v", err)
	}
}

func TestStartLaunchAgentInvokesKickstart(t *testing.T) {
	// No t.Parallel(): launchctlRunner is process-wide global.
	home := t.TempDir()
	writeStubPlist(t, home)
	calls := stubLaunchctl(t, nil)
	if err := StartLaunchAgent(home); err != nil {
		t.Fatalf("start: %v", err)
	}
	if len(*calls) != 1 || (*calls)[0][0] != "kickstart" || (*calls)[0][1] != "-k" {
		t.Errorf("expected single kickstart -k call, got %v", *calls)
	}
}

// TestStartLaunchAgentReBootstrapsWhenServiceUnknown covers the
// fallback path: kickstart fails because launchd has forgotten the
// service (for example after a previous bootout) but the plist still
// lives on disk. StartLaunchAgent should then bootstrap + enable.
func TestStartLaunchAgentReBootstrapsWhenServiceUnknown(t *testing.T) {
	// No t.Parallel(): launchctlRunner is process-wide global.
	home := t.TempDir()
	writeStubPlist(t, home)
	calls := stubLaunchctl(t, func(args []string) error {
		if len(args) > 0 && args[0] == "kickstart" {
			return &launchctlError{
				Args:     args,
				ExitCode: 113,
				Stderr:   "Could not find specified service\n",
				Err:      errors.New("exit status 113"),
			}
		}
		return nil
	})

	if err := StartLaunchAgent(home); err != nil {
		t.Fatalf("start: %v", err)
	}

	if len(*calls) != 3 {
		t.Fatalf("expected 3 calls (kickstart, bootstrap, enable), got %v", *calls)
	}
	if (*calls)[0][0] != "kickstart" {
		t.Errorf("call 0 should be kickstart, got %v", (*calls)[0])
	}
	if (*calls)[1][0] != "bootstrap" {
		t.Errorf("call 1 should be bootstrap, got %v", (*calls)[1])
	}
	if (*calls)[2][0] != "enable" {
		t.Errorf("call 2 should be enable, got %v", (*calls)[2])
	}
}

func TestStartLaunchAgentReturnsErrNotInstalled(t *testing.T) {
	// No t.Parallel(): launchctlRunner is process-wide global.
	home := t.TempDir() // plist deliberately not written
	stubLaunchctl(t, func(args []string) error {
		if len(args) > 0 && args[0] == "kickstart" {
			return &launchctlError{
				Args:     args,
				ExitCode: 113,
				Stderr:   "Could not find specified service\n",
				Err:      errors.New("exit status 113"),
			}
		}
		return nil
	})

	err := StartLaunchAgent(home)
	if !errors.Is(err, ErrNotInstalled) {
		t.Fatalf("expected ErrNotInstalled, got %v", err)
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
