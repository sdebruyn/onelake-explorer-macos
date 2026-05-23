package cli

import (
	"errors"

	"github.com/spf13/cobra"
)

func newDaemonCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Manage the OFE background daemon (LaunchAgent)",
	}
	cmd.AddCommand(&cobra.Command{
		Use:   "install",
		Short: "Install the LaunchAgent so OFE starts at login",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — daemon lifecycle pending")
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "uninstall",
		Short: "Unload and remove the LaunchAgent",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — daemon lifecycle pending")
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "start",
		Short: "Start the daemon (no-op if already running)",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — daemon lifecycle pending")
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "stop",
		Short: "Stop the daemon",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — daemon lifecycle pending")
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "run",
		Short: "Run the daemon in the foreground (used by LaunchAgent and for debugging)",
		Args:  cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — daemon run loop pending")
		},
	})
	return cmd
}
