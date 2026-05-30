// Command ofem is the helper binary bundled inside OneLake.app. It
// exposes the daemon entry point that the host app's SMAppService
// registration launches under launchd; end users interact with OneLake
// through the menu bar app, not this binary.
package main

import (
	"fmt"
	"os"

	"github.com/sdebruyn/onelake-explorer-macos/cmd/ofem/cli"
)

func main() {
	if err := cli.NewRoot().Execute(); err != nil {
		// Cobra already prints the error; we add the non-zero exit code.
		fmt.Fprintln(os.Stderr)
		os.Exit(1)
	}
}
