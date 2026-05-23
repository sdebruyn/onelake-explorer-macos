package cli

import (
	"errors"

	"github.com/spf13/cobra"
)

func newMountCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "mount",
		Short: "Ensure all signed-in accounts are mounted in Finder",
		Long: `Ensure each signed-in OneLake account is mounted as a File Provider
domain so its workspaces appear in Finder under ~/OneLake/<alias>/.

The daemon installed by 'ofe daemon install' mounts on login; this command
forces a re-registration if Finder is stuck.`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — File Provider integration is a Phase 1 deliverable")
		},
	}
}
