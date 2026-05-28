package daemon

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"text/template"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// LaunchAgentLabel is the launchd label for the OFEM daemon. macOS uses
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
	// ExecutablePath is the absolute path to the ofem binary the agent
	// should run. Normally the binary's own resolved path so an
	// `ofem daemon install` from /usr/local/bin survives a `brew
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
    <string>{{ xml .Label }}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{{ xml .ExecutablePath }}</string>
        <string>daemon</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{{ xml .StdoutPath }}</string>
    <key>StandardErrorPath</key>
    <string>{{ xml .StderrPath }}</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
`

// ResolveLaunchAgentParams builds a [LaunchAgentParams] from the OFEM
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
	// Every interpolated field is piped through `xml` so a path containing
	// '&', '<', or '>' (legal in a macOS file path) produces well-formed
	// XML instead of a plist launchd silently rejects.
	tmpl, err := template.New("plist").Funcs(template.FuncMap{"xml": xmlEscape}).Parse(launchAgentTemplate)
	if err != nil {
		return nil, fmt.Errorf("parse plist template: %w", err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, params); err != nil {
		return nil, fmt.Errorf("render plist: %w", err)
	}
	return buf.Bytes(), nil
}

// xmlEscape returns s with XML metacharacters (&, <, >, quotes, and
// control chars) replaced by entity references, safe to embed in a plist
// <string> element.
func xmlEscape(s string) string {
	var b strings.Builder
	if err := xml.EscapeText(&b, []byte(s)); err != nil {
		// EscapeText only fails if the writer fails; strings.Builder never
		// does. Fall back to the raw value rather than dropping it.
		return s
	}
	return b.String()
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

// launchctlError is the error type returned by [realLaunchctl] when the
// launchctl binary exits non-zero. It carries the captured stderr output
// alongside the raw exit code so callers like [isAlreadyBootstrapped]
// can pattern-match the descriptive message that launchctl prints
// (which would otherwise be lost — *exec.ExitError.Error() is just
// "exit status N").
type launchctlError struct {
	Args     []string
	ExitCode int
	Stderr   string
	Err      error
}

func (e *launchctlError) Error() string {
	if e.Stderr != "" {
		return fmt.Sprintf("launchctl %v: %s: %s", e.Args, e.Err, strings.TrimSpace(e.Stderr))
	}
	return fmt.Sprintf("launchctl %v: %s", e.Args, e.Err)
}

func (e *launchctlError) Unwrap() error { return e.Err }

// realLaunchctl invokes launchctl and captures stderr so the
// descriptive failure text ("Bootstrap failed: 37: service already
// loaded", etc.) is available to [isAlreadyBootstrapped] and friends.
// Without this capture launchctl's stderr would go straight to the
// process's stderr and the returned *exec.ExitError would only carry
// "exit status N", which is not enough to distinguish the "already
// loaded" case from a real failure.
func realLaunchctl(args []string) error {
	cmd := exec.Command("launchctl", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	// stdout is captured separately so launchctl status output, when
	// asked for, doesn't get interleaved into our error message.
	cmd.Stdout = &bytes.Buffer{}
	err := cmd.Run()
	if err == nil {
		return nil
	}
	exitCode := -1
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		exitCode = exitErr.ExitCode()
	}
	return &launchctlError{
		Args:     args,
		ExitCode: exitCode,
		Stderr:   stderr.String(),
		Err:      err,
	}
}

// SetLaunchctlForTest swaps the launchctl invoker for the duration of
// the test and restores the previous one on cleanup. It is exposed for
// cross-package tests (cmd/ofem/cli/daemon_test.go) that exercise the
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

// ErrNotInstalled is returned by StartLaunchAgent/StopLaunchAgent when the
// LaunchAgent plist is missing or unknown to launchd. The CLI maps this to a
// friendly "run 'ofem daemon install' first" message instead of leaking the
// raw launchctl exit code.
var ErrNotInstalled = errors.New("daemon: LaunchAgent is not installed")

// StartLaunchAgent kickstarts the running daemon. If launchd has
// forgotten the service (for example after a previous
// StopLaunchAgent/bootout) but the plist still exists on disk, it is
// re-bootstrapped and enabled before returning. If the plist itself is
// missing, [ErrNotInstalled] is returned so the CLI can print a
// friendly hint rather than leaking a raw launchctl exit code.
func StartLaunchAgent(home string) error {
	if home == "" {
		return errors.New("daemon: home directory is required")
	}
	target := launchctlTarget()
	label := target + "/" + LaunchAgentLabel
	plistPath := LaunchAgentPlistPath(home)
	// Fast path: tell launchd to restart the running service.
	if err := launchctlRunner([]string{"kickstart", "-k", label}); err == nil {
		return nil
	} else if !isNotBootstrapped(err) {
		return err
	}
	// Service is unknown to launchd. Re-bootstrap from the on-disk plist.
	if _, statErr := os.Stat(plistPath); statErr != nil {
		if errors.Is(statErr, os.ErrNotExist) {
			return ErrNotInstalled
		}
		return fmt.Errorf("daemon: stat plist: %w", statErr)
	}
	if err := launchctlRunner([]string{"bootstrap", target, plistPath}); err != nil {
		return err
	}
	if err := launchctlRunner([]string{"enable", label}); err != nil {
		return err
	}
	return nil
}

// StopLaunchAgent asks launchd to bootout the daemon. Bootout tells
// launchd to forget about the service, so KeepAlive=true will not
// immediately respawn it (which is what `launchctl kill SIGTERM` would
// have done). The plist file on disk is preserved — use
// [UninstallLaunchAgent] to remove it. If the service was already not
// loaded, [ErrNotInstalled] is returned.
func StopLaunchAgent() error {
	target := launchctlTarget() + "/" + LaunchAgentLabel
	if err := launchctlRunner([]string{"bootout", target}); err != nil {
		if isNotBootstrapped(err) {
			return ErrNotInstalled
		}
		return err
	}
	return nil
}

// launchctlTarget returns the gui/<uid> domain string launchctl uses on
// macOS Big Sur and later for per-user LaunchAgents.
func launchctlTarget() string {
	return "gui/" + strconv.Itoa(os.Getuid())
}

// isAlreadyBootstrapped recognises the launchctl outcome for "service
// is already loaded". On modern macOS launchctl exits with code 37 and
// prints "Bootstrap failed: 37: Service is already loaded" to stderr;
// we match on both the canonical exit code (when available via
// [launchctlError]) and the descriptive substrings so we stay robust
// across launchctl tweaks.
func isAlreadyBootstrapped(err error) bool {
	var le *launchctlError
	if errors.As(err, &le) && le.ExitCode == 37 {
		return true
	}
	msg := err.Error()
	return containsAny(msg, []string{
		"service already loaded",
		"Service is already loaded",
		"Bootstrap failed: 37",
		"already bootstrapped",
	})
}

// isNotBootstrapped recognises the launchctl outcome for "no such
// service". Treated as a successful no-op by UninstallLaunchAgent and
// translated to [ErrNotInstalled] by StartLaunchAgent/StopLaunchAgent.
// Exit code 113 is the canonical "could not find specified service"
// from `launchctl bootout`/`kickstart` on modern macOS; 36 shows up on
// some macOS releases for the same outcome. We still substring-match
// the descriptive text so we stay robust across launchctl tweaks.
func isNotBootstrapped(err error) bool {
	var le *launchctlError
	if errors.As(err, &le) && (le.ExitCode == 113 || le.ExitCode == 36) {
		return true
	}
	msg := err.Error()
	return containsAny(msg, []string{
		"Could not find specified service",
		"service not bootstrapped",
		"No such process",
		"Boot-out failed: 5",
		"bootout failed: 5: Input/output error",
		"not loaded",
	})
}

func containsAny(s string, needles []string) bool {
	for _, n := range needles {
		if n != "" && strings.Contains(s, n) {
			return true
		}
	}
	return false
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
