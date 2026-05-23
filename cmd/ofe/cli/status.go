// Package cli — status subcommand.
//
// `ofe status` shows the local OFE configuration and, when the daemon
// is running, fetches live information over the Unix-domain-socket IPC
// described in internal/ipc.
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/daemon"
	"github.com/sdebruyn/onelake-explorer-macos/internal/ipc"
)

// statusIPCTimeout caps how long the CLI will block on the daemon
// before falling back to "not running". 2 seconds is enough for any
// healthy local socket round-trip and short enough that an unresponsive
// daemon does not make `ofe status` feel broken.
const statusIPCTimeout = 2 * time.Second

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

			printDaemonStatus(out, paths.SocketPath)
			return nil
		},
	}
}

// printDaemonStatus dials the daemon over IPC and prints what it tells
// us. If the socket file does not exist (the daemon is not installed)
// or the call fails (it is installed but crashed/blocked), we print a
// terse "not running" line — `ofe status` is informational, not a
// health check, so falling back is the right behaviour.
func printDaemonStatus(out io.Writer, socketPath string) {
	if _, err := os.Stat(socketPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(out, "Daemon:    not running (run `ofe daemon start`)")
			return
		}
		fmt.Fprintf(out, "Daemon:    socket error: %v\n", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), statusIPCTimeout)
	defer cancel()

	client, err := ipc.Dial(socketPath)
	if err != nil {
		fmt.Fprintf(out, "Daemon:    socket present but dial failed: %v\n", err)
		return
	}
	defer func() { _ = client.Close() }()

	var resp daemon.StatusResponse
	if err := client.Call(ctx, "status", nil, &resp); err != nil {
		fmt.Fprintf(out, "Daemon:    socket present but call failed: %v\n", err)
		return
	}

	uptime := time.Since(resp.StartedAt).Round(time.Second)
	fmt.Fprintf(out, "Daemon:    running (v%s, up %s, %d account(s))\n",
		resp.DaemonVersion, uptime, len(resp.Accounts))
	if resp.CacheBytes >= 0 {
		fmt.Fprintf(out, "Cache use: %s / %s\n",
			humanBytes(resp.CacheBytes), humanBytes(resp.CacheMaxBytes))
	}
}

func boolWord(b bool) string {
	if b {
		return "on"
	}
	return "off"
}

// humanBytes is a tiny formatter shared by status output. We avoid
// pulling in a dependency for a 5-line helper. Negative inputs render
// as "?".
func humanBytes(n int64) string {
	if n < 0 {
		return "?"
	}
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	suffix := "KMGTPE"[exp]
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), suffix)
}
