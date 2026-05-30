// Package cli — daemon subcommand.
//
// `ofem daemon run` is the foreground entry point launchd itself calls
// (via the SMAppService-registered LaunchAgent in OneLake.app) and the
// one the IPC integration test spawns against a temp socket. The
// command is intentionally minimal: it owns no flags and runs the
// daemon's Run loop until the process is signalled.
package cli

import (
	"context"
	"os"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/daemon"
)

func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Daemon entry point invoked by launchd",
	}
	cmd.AddCommand(newDaemonRunCmd())
	return cmd
}

func newDaemonRunCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "run",
		Short: "Run the daemon in the foreground (used by LaunchAgent and for debugging)",
		Long: `Run the daemon process in the foreground. The LaunchAgent invokes
this entry point under launchd; developers can also run it manually to
tail the log via stdout.`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			// OFEM_SOCKET_PATH overrides the default socket path under the
			// App Group container. Used by the IPC integration test that
			// spawns a real daemon against a temp socket; intentionally
			// undocumented in --help because end users should not need it.
			return daemon.Run(context.Background(), daemon.RunOptions{
				SocketPath: os.Getenv("OFEM_SOCKET_PATH"),
			})
		},
	}
}
