package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
)

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version, commit, and build date",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "ofem %s\n", buildinfo.Version)
			if buildinfo.Commit != "" {
				fmt.Fprintf(out, "commit: %s\n", buildinfo.Commit)
			}
			if buildinfo.Date != "" {
				fmt.Fprintf(out, "built:  %s\n", buildinfo.Date)
			}
			return nil
		},
	}
}
