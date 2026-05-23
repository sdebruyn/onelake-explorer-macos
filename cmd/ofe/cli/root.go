// Package cli wires together the cobra command tree for the ofe binary.
// Each command lives in its own file (account.go, mount.go, ...).
package cli

import (
	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
)

// NewRoot builds a fresh command tree. A new tree per invocation makes
// the CLI testable; cobra is otherwise happy to share state.
func NewRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "ofe",
		Short:         "OneLake File Explorer for macOS",
		Long:          longDescription,
		Version:       versionString(),
		SilenceUsage:  true,
		SilenceErrors: false,
	}

	root.AddCommand(newVersionCmd())
	root.AddCommand(newAccountCmd())
	root.AddCommand(newLoginCmd())
	root.AddCommand(newMountCmd())
	root.AddCommand(newStatusCmd())
	root.AddCommand(newConfigCmd())
	root.AddCommand(newDaemonCmd())
	root.AddCommand(newDebugCmd())

	return root
}

func versionString() string {
	v := buildinfo.Version
	if buildinfo.Commit != "" {
		v += " (" + buildinfo.Commit + ")"
	}
	return v
}

const longDescription = `ofe is the command-line tool for the open-source OneLake File Explorer
for macOS. It manages accounts, controls the local sync daemon, and ships
a handful of debug commands for development.

Day-to-day usage is in Finder once the daemon is running; the CLI is for
setup, account management, and troubleshooting.

See https://github.com/sdebruyn/onelake-explorer-macos for documentation.`
