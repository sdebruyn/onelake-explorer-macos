package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

func newStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show daemon, accounts, and sync status",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()

			store, err := config.Load()
			if err != nil {
				return err
			}
			f := store.Snapshot()
			paths := store.Paths()

			fmt.Fprintf(out, "Config:    %s\n", paths.ConfigFile)
			fmt.Fprintf(out, "Cache:     %s\n", paths.CacheDir)
			fmt.Fprintf(out, "Logs:      %s\n", paths.LogDir)
			fmt.Fprintf(out, "Telemetry: %s\n", boolWord(f.Telemetry))
			fmt.Fprintf(out, "Accounts:  %d\n", len(f.Accounts))
			if f.DefaultAccount != "" {
				fmt.Fprintf(out, "Default:   %s\n", f.DefaultAccount)
			}

			// Daemon status will land once internal/ipc is wired up.
			fmt.Fprintln(out, "Daemon:    (unknown — IPC pending)")
			return nil
		},
	}
}

func boolWord(b bool) string {
	if b {
		return "on"
	}
	return "off"
}
