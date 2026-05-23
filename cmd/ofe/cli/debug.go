package cli

import (
	"errors"

	"github.com/spf13/cobra"
)

func newDebugCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "debug",
		Short:  "Internal commands for development",
		Hidden: true,
	}
	cmd.AddCommand(&cobra.Command{
		Use:   "ls <alias:/workspace[/item[/path]]>",
		Short: "List a OneLake path via the core library (bypasses Finder)",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — Phase 0 OneLake client pending")
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "cat <alias:/workspace/item/path/file>",
		Short: "Print a OneLake file to stdout via the core library",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — Phase 0 OneLake client pending")
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "stat <alias:/workspace/item/path>",
		Short: "Show metadata for a OneLake path",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, _ []string) error {
			return errors.New("not implemented yet — Phase 0 OneLake client pending")
		},
	})
	return cmd
}
