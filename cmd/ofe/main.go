// Command ofe is the OneLake File Explorer command-line tool. It handles
// account setup, the local daemon lifecycle, and (during development) a
// handful of debug subcommands that exercise the Go core without going
// through the File Provider Extension.
package main

import (
	"fmt"
	"os"

	"github.com/sdebruyn/onelake-explorer-macos/cmd/ofe/cli"
)

func main() {
	if err := cli.NewRoot().Execute(); err != nil {
		// Cobra already prints the error; we add the non-zero exit code.
		fmt.Fprintln(os.Stderr)
		os.Exit(1)
	}
}
