package cli

import (
	"errors"

	"github.com/spf13/cobra"
)

func newLoginCmd() *cobra.Command {
	var (
		deviceCode bool
		alias      string
	)
	cmd := &cobra.Command{
		Use:   "login",
		Short: "Sign in to OneLake (interactive browser by default)",
		Long: `Sign in to a OneLake / Microsoft Fabric tenant.

By default ofe opens the system browser for an interactive sign-in. Use
--device-code on machines without a browser (SSH sessions, headless CI).
After authentication you are prompted for a short alias for the account
(e.g. "work", "client-a"); pick something memorable because you will use
it as the path prefix in Finder under ~/OneLake/<alias>/.`,
		Args: cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			// Implementation lands in internal/auth during the next commit.
			_ = deviceCode
			_ = alias
			return errors.New("not implemented yet — auth module pending")
		},
	}
	cmd.Flags().BoolVar(&deviceCode, "device-code", false, "use the device-code flow instead of the interactive browser")
	cmd.Flags().StringVar(&alias, "account", "", "use this alias instead of prompting")
	return cmd
}
