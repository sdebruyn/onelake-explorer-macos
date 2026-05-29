package cli

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "Inspect and modify OFEM configuration",
	}
	cmd.AddCommand(newConfigGetCmd())
	cmd.AddCommand(newConfigSetCmd())
	cmd.AddCommand(newConfigListCmd())
	return cmd
}

func newConfigListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "Print all configurable keys and their current values",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			f := store.Snapshot()
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "telemetry                       = %s\n", boolWord(f.Telemetry))
			fmt.Fprintf(out, "default_account                 = %q\n", f.DefaultAccount)
			fmt.Fprintf(out, "cache.max_size_bytes            = %d\n", f.Cache.MaxSizeBytes)
			fmt.Fprintf(out, "cache.max_size                  = %s   # alias of cache.max_size_bytes, accepts 10GiB / 500MB / etc.\n", humanBytes(f.Cache.MaxSizeBytes))
			fmt.Fprintf(out, "log.level                       = %q\n", f.Log.Level)
			return nil
		},
	}
}

func newConfigGetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "get <key>",
		Short: "Print a single config value",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			store, err := config.Load()
			if err != nil {
				return err
			}
			val, ok := lookupConfig(store.Snapshot(), args[0])
			if !ok {
				return fmt.Errorf("unknown config key %q", args[0])
			}
			fmt.Fprintln(cmd.OutOrStdout(), val)
			return nil
		},
	}
}

func newConfigSetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "set <key> <value>",
		Short: "Update a config value and persist to disk",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			key, value := args[0], args[1]
			store, err := config.Load()
			if err != nil {
				return err
			}
			var setErr error
			if err := store.UpdateAndSave(func(f *config.File) {
				setErr = config.ApplyConfig(f, key, value)
			}); setErr != nil {
				return setErr
			} else if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s = %s\n", key, value)
			return nil
		},
	}
}

func lookupConfig(f config.File, key string) (string, bool) {
	switch config.NormalizeConfigKey(key) {
	case "telemetry":
		return boolWord(f.Telemetry), true
	case "default_account":
		return f.DefaultAccount, true
	case "cache.max_size_bytes":
		return strconv.FormatInt(f.Cache.MaxSizeBytes, 10), true
	case "cache.max_size":
		return humanBytes(f.Cache.MaxSizeBytes), true
	case "log.level":
		return f.Log.Level, true
	}
	return "", false
}
