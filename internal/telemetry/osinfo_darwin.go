//go:build darwin

package telemetry

import (
	"os/exec"
	"strings"
	"sync"
)

// osVersionOnce caches the sw_vers result for the process lifetime so a
// daemon that restarts the telemetry client (or a test that constructs
// multiple Clients) does not re-fork the subprocess.
var (
	osVersionOnce sync.Once
	osVersionVal  string
)

// OSVersion returns the macOS ProductVersion (e.g. "14.5.1") via
// `sw_vers -productVersion`. It returns an empty string when sw_vers is
// missing or fails — telemetry treats osVersion as best-effort. The
// result is cached after the first successful call.
func OSVersion() string {
	osVersionOnce.Do(func() {
		out, err := exec.Command("sw_vers", "-productVersion").Output()
		if err != nil {
			return
		}
		osVersionVal = strings.TrimSpace(string(out))
	})
	return osVersionVal
}
