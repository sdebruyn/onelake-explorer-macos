//go:build darwin

package telemetry

import (
	"os/exec"
	"strings"
)

// OSVersion returns the macOS ProductVersion (e.g. "14.5.1") via
// `sw_vers -productVersion`. It returns an empty string when sw_vers is
// missing or fails — telemetry treats osVersion as best-effort.
func OSVersion() string {
	out, err := exec.Command("sw_vers", "-productVersion").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
