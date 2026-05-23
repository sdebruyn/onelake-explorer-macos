// Package cli — daemon subcommands.
//
// `ofem daemon` is the user-facing surface for the background process
// described in docs/file-provider.md. `install`/`uninstall` manage the
// LaunchAgent in ~/Library/LaunchAgents/, `start`/`stop` poke launchd
// at runtime, and `run` is the foreground entry point launchd itself
// calls (and the one Sam reaches for during development).
package cli

import (
	"context"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/daemon"
)

func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Manage the OFEM background daemon (LaunchAgent)",
		Long: `Manage the OFEM background daemon.

The daemon owns the SQLite metadata cache, refreshes Microsoft Entra
tokens silently, drives the File Provider Extension via XPC, and serves
local IPC for the CLI and host app. It is normally launched by macOS's
launchd via the per-user LaunchAgent installed under
~/Library/LaunchAgents/.`,
	}
	cmd.AddCommand(newDaemonInstallCmd())
	cmd.AddCommand(newDaemonUninstallCmd())
	cmd.AddCommand(newDaemonStartCmd())
	cmd.AddCommand(newDaemonStopCmd())
	cmd.AddCommand(newDaemonRunCmd())
	return cmd
}

func newDaemonInstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "install",
		Short: "Install the LaunchAgent so OFEM starts at login",
		Long: `Write the OFEM LaunchAgent plist to ~/Library/LaunchAgents/ and
bootstrap it under launchd. The plist points at the currently-running
ofem binary, so re-run this command after any move or upgrade that
relocates the executable.

Idempotent: re-running install when the agent is already loaded with
the same parameters is a no-op.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return fmt.Errorf("resolve home: %w", err)
			}
			paths, err := config.ResolvePaths()
			if err != nil {
				return err
			}
			if err := daemon.InstallLaunchAgent(home, paths, ""); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Installed LaunchAgent %s\n", daemon.LaunchAgentLabel)
			return nil
		},
	}
}

func newDaemonUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "Unload and remove the LaunchAgent",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return fmt.Errorf("resolve home: %w", err)
			}
			if err := daemon.UninstallLaunchAgent(home); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Uninstalled LaunchAgent %s\n", daemon.LaunchAgentLabel)
			return nil
		},
	}
}

func newDaemonStartCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "start",
		Short: "Start (or restart) the daemon now via launchctl",
		Long: `Ask launchd to kickstart the daemon now. If it is already
running, launchctl restarts it; if it has crashed, KeepAlive will pick
it up on its own.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := daemon.StartLaunchAgent(); err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), "Daemon started")
			return nil
		},
	}
}

func newDaemonStopCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stop",
		Short: "Send SIGTERM to the daemon (KeepAlive will restart it)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := daemon.StopLaunchAgent(); err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), "SIGTERM sent to daemon")
			return nil
		},
	}
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
			return daemon.Run(context.Background(), daemon.RunOptions{})
		},
	}
}
