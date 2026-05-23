package daemon

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"text/template"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// LaunchAgentLabel is the launchd label for the OFE daemon. macOS uses
// it to uniquely identify the LaunchAgent across bootstrap/bootout
// commands; it must match the CFBundleIdentifier-style key inside the
// plist.
const LaunchAgentLabel = config.BundleID + ".daemon"

// LaunchAgentFileName is the basename of the plist installed into
// ~/Library/LaunchAgents/.
const LaunchAgentFileName = LaunchAgentLabel + ".plist"

// LaunchAgentParams captures the bits the install template needs to
// emit. ResolveLaunchAgentParams fills it from the live config and the
// running executable's location.
type LaunchAgentParams struct {
	// Label is the launchd Label key. Always [LaunchAgentLabel].
	Label string
	// ExecutablePath is the absolute path to the ofe binary the agent
	// should run. Normally the binary's own resolved path so an
	// `ofe daemon install` from /usr/local/bin survives a `brew
	// upgrade` that replaces the underlying file.
	ExecutablePath string
	// StdoutPath is where launchd redirects the daemon's stdout.
	StdoutPath string
	// StderrPath is where launchd redirects the daemon's stderr.
	StderrPath string
}

// launchAgentTemplate is the plist contents we install. It runs the
// daemon at login (RunAtLoad=true) and respawns it if it crashes
// (KeepAlive=true).
const launchAgentTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{{ .Label }}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{{ .ExecutablePath }}</string>
        <string>daemon</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{{ .StdoutPath }}</string>
    <key>StandardErrorPath</key>
    <string>{{ .StderrPath }}</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
`

// ResolveLaunchAgentParams builds a [LaunchAgentParams] from the OFE
// paths and the currently-running executable's absolute location.
//
// execPath, when non-empty, overrides os.Executable; used in tests.
func ResolveLaunchAgentParams(paths config.Paths, execPath string) (LaunchAgentParams, error) {
	if execPath == "" {
		p, err := os.Executable()
		if err != nil {
			return LaunchAgentParams{}, fmt.Errorf("resolve executable: %w", err)
		}
		abs, err := filepath.Abs(p)
		if err != nil {
			return LaunchAgentParams{}, fmt.Errorf("absolute path: %w", err)
		}
		execPath = abs
	}
	return LaunchAgentParams{
		Label:          LaunchAgentLabel,
		ExecutablePath: execPath,
		StdoutPath:     filepath.Join(paths.LogDir, "daemon.stdout.log"),
		StderrPath:     filepath.Join(paths.LogDir, "daemon.stderr.log"),
	}, nil
}

// RenderLaunchAgentPlist returns the plist body for params. The result
// is deterministic so install can compare against an already-installed
// plist and decide whether to skip the write.
func RenderLaunchAgentPlist(params LaunchAgentParams) ([]byte, error) {
	tmpl, err := template.New("plist").Parse(launchAgentTemplate)
	if err != nil {
		return nil, fmt.Errorf("parse plist template: %w", err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, params); err != nil {
		return nil, fmt.Errorf("render plist: %w", err)
	}
	return buf.Bytes(), nil
}

// LaunchAgentPlistDir is the per-user directory macOS scans for
// LaunchAgents at login.
func LaunchAgentPlistDir(home string) string {
	return filepath.Join(home, "Library", "LaunchAgents")
}

// LaunchAgentPlistPath is the absolute path to our installed plist.
func LaunchAgentPlistPath(home string) string {
	return filepath.Join(LaunchAgentPlistDir(home), LaunchAgentFileName)
}

// launchctlRunner is the function used to invoke launchctl. Tests
// override it to capture calls without touching the system. The default
// runs the real binary.
var launchctlRunner = realLaunchctl

func realLaunchctl(args []string) error {
	cmd := exec.Command("launchctl", args...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("launchctl %v: %w", args, err)
	}
	return nil
}

// SetLaunchctlForTest swaps the launchctl invoker for the duration of
// the test and restores the previous one on cleanup. It is exposed for
// cross-package tests (cmd/ofe/cli/daemon_test.go) that exercise the
// install/uninstall/start/stop CLI commands without touching the real
// launchd. Production code must never call it; the parameter `t`
// guarantees that.
func SetLaunchctlForTest(t interface{ Cleanup(func()) }, fn func(args []string) error) {
	prev := launchctlRunner
	launchctlRunner = fn
	t.Cleanup(func() { launchctlRunner = prev })
}

// InstallLaunchAgent writes the plist for the running binary into
// ~/Library/LaunchAgents/ and bootstraps it under launchd. It is
// idempotent: if the plist on disk already matches what we would write
// AND the agent is currently loaded, InstallLaunchAgent does nothing.
//
// home is the user's home directory; pass os.UserHomeDir() in
// production and a t.TempDir() in tests. execPath, when empty, defaults
// to os.Executable(). paths.LogDir is created if missing so the
// stdout/stderr redirection actually works.
func InstallLaunchAgent(home string, paths config.Paths, execPath string) error {
	if home == "" {
		return errors.New("daemon: home directory is required")
	}
	if err := os.MkdirAll(paths.LogDir, 0o700); err != nil {
		return fmt.Errorf("daemon: create log dir: %w", err)
	}
	if err := os.MkdirAll(LaunchAgentPlistDir(home), 0o750); err != nil {
		return fmt.Errorf("daemon: create LaunchAgents dir: %w", err)
	}

	params, err := ResolveLaunchAgentParams(paths, execPath)
	if err != nil {
		return err
	}
	desired, err := RenderLaunchAgentPlist(params)
	if err != nil {
		return err
	}

	plistPath := LaunchAgentPlistPath(home)
	existing, readErr := os.ReadFile(plistPath)
	if readErr != nil || !bytes.Equal(existing, desired) {
		// Either no plist on disk yet, or the existing one is stale.
		// Write the new one before asking launchd to load it.
		if err := writeFileAtomic(plistPath, desired, 0o600); err != nil {
			return fmt.Errorf("daemon: write plist: %w", err)
		}
	}

	target := launchctlTarget()
	// `bootstrap` errors out with "service already loaded" when run
	// twice. We treat that as success because the goal is "loaded
	// after this returns" not "loaded by this call".
	if err := launchctlRunner([]string{"bootstrap", target, plistPath}); err != nil {
		if !isAlreadyBootstrapped(err) {
			return err
		}
	}
	if err := launchctlRunner([]string{"enable", target + "/" + LaunchAgentLabel}); err != nil {
		return err
	}
	return nil
}

// UninstallLaunchAgent unloads the agent and removes its plist. It is
// idempotent: missing plist or already-bootedout agent are both fine.
func UninstallLaunchAgent(home string) error {
	if home == "" {
		return errors.New("daemon: home directory is required")
	}
	plistPath := LaunchAgentPlistPath(home)
	target := launchctlTarget() + "/" + LaunchAgentLabel

	if err := launchctlRunner([]string{"bootout", target}); err != nil {
		if !isNotBootstrapped(err) {
			return err
		}
	}
	if err := os.Remove(plistPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("daemon: remove plist: %w", err)
	}
	return nil
}

// StartLaunchAgent kickstarts the agent, restarting it if already
// running. Useful after `ofe daemon install` to launch the daemon
// without waiting for the next login.
func StartLaunchAgent() error {
	target := launchctlTarget() + "/" + LaunchAgentLabel
	return launchctlRunner([]string{"kickstart", "-k", target})
}

// StopLaunchAgent sends SIGTERM to the running daemon process via
// launchctl. The agent will respawn because of KeepAlive=true; callers
// who want a permanent stop should use UninstallLaunchAgent.
func StopLaunchAgent() error {
	target := launchctlTarget() + "/" + LaunchAgentLabel
	return launchctlRunner([]string{"kill", "SIGTERM", target})
}

// launchctlTarget returns the gui/<uid> domain string launchctl uses on
// macOS Big Sur and later for per-user LaunchAgents.
func launchctlTarget() string {
	return "gui/" + strconv.Itoa(os.Getuid())
}

// isAlreadyBootstrapped recognises the launchctl exit code for "service
// is already loaded" (Input/output error 5 historically, "Service is
// already loaded" textually on modern macOS). We pattern-match on
// substrings because launchctl does not expose a stable code.
func isAlreadyBootstrapped(err error) bool {
	msg := err.Error()
	return containsAny(msg, []string{
		"service already loaded",
		"Service is already loaded",
		"Bootstrap failed: 37",
		"already bootstrapped",
	})
}

// isNotBootstrapped recognises the launchctl exit for "no such
// service". Treated as a successful no-op by UninstallLaunchAgent.
func isNotBootstrapped(err error) bool {
	msg := err.Error()
	return containsAny(msg, []string{
		"Could not find specified service",
		"No such process",
		"Boot-out failed: 5",
		"not loaded",
	})
}

func containsAny(s string, needles []string) bool {
	for _, n := range needles {
		if n != "" && indexOf(s, n) >= 0 {
			return true
		}
	}
	return false
}

// indexOf is the simplest possible substring search; we don't bring in
// strings because the package doesn't otherwise need it and this keeps
// the import block small.
func indexOf(s, sub string) int {
	if len(sub) == 0 {
		return 0
	}
	if len(sub) > len(s) {
		return -1
	}
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

// writeFileAtomic writes data to path via write-temp + rename so a
// crash mid-write cannot leave a half-written plist behind.
func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	tmpName := f.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.Remove(tmpName)
		}
	}()
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	cleanup = false
	return nil
}
