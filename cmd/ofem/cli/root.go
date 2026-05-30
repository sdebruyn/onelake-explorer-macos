// Package cli wires together the cobra command tree for the ofem binary.
//
// The user-facing CLI has been removed; the menu bar app is the
// supported end-user surface. What remains is the daemon entry point
// that SMAppService launches under launchd (see
// apple/OneLake/LoginItemManager.swift) and that the IPC integration
// test spawns directly against a temp socket.
package cli

import (
	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
)

// NewRoot builds a fresh command tree. A new tree per invocation makes
// the binary testable; cobra is otherwise happy to share state.
func NewRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "ofem",
		Short:         "OneLake Explorer for macOS daemon entry point",
		Long:          longDescription,
		Version:       versionString(),
		SilenceUsage:  true,
		SilenceErrors: false,
		CompletionOptions: cobra.CompletionOptions{
			// No shell-completion surface: this binary is bundled inside
			// OneLake.app and not meant to be invoked interactively.
			DisableDefaultCmd: true,
		},
	}

	root.AddCommand(newDaemonCmd())

	return root
}

func versionString() string {
	v := buildinfo.Version
	if buildinfo.Commit != "" {
		v += " (" + buildinfo.Commit + ")"
	}
	return v
}

const longDescription = `ofem is the helper binary bundled inside OneLake.app.

It exposes the daemon entry point that the host app's SMAppService
registration launches under launchd. End users interact with OneLake
through the menu bar app and Finder; this binary is not a user-facing
tool.`
