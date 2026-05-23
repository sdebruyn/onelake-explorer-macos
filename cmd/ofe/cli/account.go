package cli

import (
	"errors"
	"fmt"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

func newAccountCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "account",
		Short: "Manage signed-in OneLake accounts",
	}
	cmd.AddCommand(newAccountListCmd())
	cmd.AddCommand(newAccountRemoveCmd())
	cmd.AddCommand(newAccountDefaultCmd())
	return cmd
}

func newAccountListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List signed-in accounts",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			f := store.Snapshot()
			if len(f.Accounts) == 0 {
				fmt.Fprintln(cmd.OutOrStdout(), "No accounts. Run `ofe login` to add one.")
				return nil
			}
			tw := tabwriter.NewWriter(cmd.OutOrStdout(), 0, 0, 2, ' ', 0)
			fmt.Fprintln(tw, "ALIAS\tUSER\tTENANT\tDEFAULT")
			for _, a := range f.Accounts {
				def := ""
				if a.Alias == f.DefaultAccount {
					def = "✓"
				}
				tenant := a.TenantName
				if tenant == "" {
					tenant = a.TenantID
				}
				fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", a.Alias, a.Username, tenant, def)
			}
			return tw.Flush()
		},
	}
}

func newAccountRemoveCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "remove <alias>",
		Short: "Remove a signed-in account (token, cache, mount)",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, _ []string) error {
			// Implementation lands once internal/auth and the daemon are in.
			return errors.New("not implemented yet — pending auth module")
		},
	}
}

func newAccountDefaultCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "default <alias>",
		Short: "Set the default account used when a command omits --account",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			alias := args[0]
			store, err := config.Load()
			if err != nil {
				return err
			}
			snap := store.Snapshot()
			if _, ok := snap.Accounts[alias]; !ok {
				return fmt.Errorf("no account with alias %q (try `ofe account list`)", alias)
			}
			store.Update(func(f *config.File) {
				f.DefaultAccount = alias
			})
			if err := store.Save(); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Default account is now %q\n", alias)
			return nil
		},
	}
}
