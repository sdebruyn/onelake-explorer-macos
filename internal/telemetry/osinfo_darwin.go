//go:build darwin

package telemetry

import (
	"strings"
	"sync"
	"syscall"
)

// osVersionOnce caches the kern.osproductversion sysctl result for the
// process lifetime so a daemon that restarts the telemetry client (or a
// test that constructs multiple Clients) does not repeat the syscall.
var (
	osVersionOnce sync.Once
	osVersionVal  string
)

// OSVersion returns the macOS ProductVersion (e.g. "14.5.1") via the
// kern.osproductversion sysctl. It returns an empty string on failure —
// telemetry treats osVersion as best-effort. The result is cached after
// the first successful call.
//
// syscall.Sysctl is used instead of exec.Command("sw_vers", ...) because
// os/exec subprocess invocations are blocked under App Sandbox.
func OSVersion() string {
	osVersionOnce.Do(func() {
		ver, err := syscall.Sysctl("kern.osproductversion")
		if err != nil {
			return
		}
		osVersionVal = strings.TrimRight(strings.TrimSpace(ver), "\x00")
	})
	return osVersionVal
}
