package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "Inspect and modify OFE configuration",
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
			fmt.Fprintf(out, "telemetry                = %s\n", boolWord(f.Telemetry))
			fmt.Fprintf(out, "default_account          = %q\n", f.DefaultAccount)
			fmt.Fprintf(out, "cache.max_size_bytes     = %d\n", f.Cache.MaxSizeBytes)
			fmt.Fprintf(out, "net.max_concurrency_per_account = %d\n", f.Net.MaxConcurrencyPerAccount)
			fmt.Fprintf(out, "log.level                = %q\n", f.Log.Level)
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
			store.Update(func(f *config.File) {
				setErr = applyConfig(f, key, value)
			})
			if setErr != nil {
				return setErr
			}
			if err := store.Save(); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s = %s\n", key, value)
			return nil
		},
	}
}

func lookupConfig(f config.File, key string) (string, bool) {
	switch strings.ToLower(key) {
	case "telemetry":
		return boolWord(f.Telemetry), true
	case "default_account":
		return f.DefaultAccount, true
	case "cache.max_size_bytes":
		return strconv.FormatInt(f.Cache.MaxSizeBytes, 10), true
	case "net.max_concurrency_per_account":
		return strconv.Itoa(f.Net.MaxConcurrencyPerAccount), true
	case "log.level":
		return f.Log.Level, true
	}
	return "", false
}

func applyConfig(f *config.File, key, value string) error {
	switch strings.ToLower(key) {
	case "telemetry":
		v, err := parseBool(value)
		if err != nil {
			return err
		}
		f.Telemetry = v
	case "default_account":
		if value != "" {
			if _, ok := f.Accounts[value]; !ok {
				return fmt.Errorf("no account with alias %q (run `ofe account list`)", value)
			}
		}
		f.DefaultAccount = value
	case "cache.max_size_bytes":
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil || n < 0 {
			return fmt.Errorf("cache.max_size_bytes must be a non-negative integer")
		}
		f.Cache.MaxSizeBytes = n
	case "net.max_concurrency_per_account":
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 32 {
			return fmt.Errorf("net.max_concurrency_per_account must be between 1 and 32")
		}
		f.Net.MaxConcurrencyPerAccount = n
	case "log.level":
		switch strings.ToLower(value) {
		case "debug", "info", "warn", "error":
			f.Log.Level = strings.ToLower(value)
		default:
			return fmt.Errorf("log.level must be debug|info|warn|error")
		}
	default:
		return fmt.Errorf("unknown config key %q", key)
	}
	return nil
}

func parseBool(v string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "on", "yes":
		return true, nil
	case "0", "false", "off", "no":
		return false, nil
	}
	return false, fmt.Errorf("invalid boolean %q (use on/off, true/false, 1/0)", v)
}
