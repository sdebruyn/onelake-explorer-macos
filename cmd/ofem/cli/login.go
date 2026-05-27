package cli

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

func newLoginCmd() *cobra.Command {
	var (
		deviceCode bool
		alias      string
		tenant     string
	)
	cmd := &cobra.Command{
		Use:   "login",
		Short: "Sign in to OneLake (interactive browser by default)",
		Long: `Sign in to a OneLake / Microsoft Fabric tenant.

By default ofem opens the system browser for an interactive sign-in. Use
--device-code on machines without a browser (SSH sessions, headless CI).
After authentication you are prompted for a short alias for the account
(e.g. "work", "client-a"); pick something memorable because it becomes
the Finder entry "OneLake — <alias>" (on disk:
~/Library/CloudStorage/OneLake-<alias>/).`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runLogin(cmd, loginOptions{
				deviceCode: deviceCode,
				alias:      alias,
				tenantHint: tenant,
			})
		},
	}
	cmd.Flags().BoolVar(&deviceCode, "device-code", false, "use the device-code flow instead of the interactive browser")
	cmd.Flags().StringVar(&alias, "account", "", "use this alias instead of prompting")
	cmd.Flags().StringVar(&tenant, "tenant", "", "tenant GUID or domain to sign in to (default: prompt at sign-in time)")
	return cmd
}

// loginOptions is the resolved set of flags passed to runLogin.
type loginOptions struct {
	deviceCode bool
	alias      string
	tenantHint string
}

// runLogin orchestrates the end-to-end login flow: pick a flow, prompt
// for an alias if needed, and persist the result via [auth.Registry.Add].
// Extracted from the cobra command so it can be unit-tested without a
// browser or device-code prompt.
func runLogin(cmd *cobra.Command, opts loginOptions) error {
	store, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	kc, err := auth.NewKeychain()
	if err != nil {
		return fmt.Errorf("open keychain: %w", err)
	}
	registry := auth.NewRegistry(store, kc, auth.EntraClientID, nil)

	// Cancellable context so ctrl-C during a device-code wait shuts the
	// flow down rather than leaving MSAL polling forever.
	ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	stdout := cmd.OutOrStdout()
	stdin := cmd.InOrStdin()

	// The login flows return the public.Account too, but Registry.Add
	// only needs the cacheBytes — the MSAL token cache already holds the
	// data needed for silent refresh under the alias's keychain entry.
	var (
		account    auth.Account
		cacheBytes []byte
	)
	if opts.deviceCode {
		account, _, cacheBytes, err = auth.LoginDeviceCode(ctx, auth.EntraClientID, opts.tenantHint, kc,
			func(verificationURL, userCode string, _ time.Time) {
				fmt.Fprintf(stdout, "To sign in, visit %s and enter the code: %s\n", verificationURL, userCode)
			},
		)
	} else {
		fmt.Fprintln(stdout, "Opening browser to sign in...")
		account, _, cacheBytes, err = auth.LoginInteractive(ctx, auth.EntraClientID, opts.tenantHint, kc)
	}
	if err != nil {
		return fmt.Errorf("sign in: %w", err)
	}

	finalAlias, err := resolveAlias(stdin, stdout, opts.alias, account)
	if err != nil {
		return err
	}
	account.Alias = finalAlias

	if err := registry.Add(account, cacheBytes); err != nil {
		return fmt.Errorf("register account: %w", err)
	}

	tenantLabel := account.TenantName
	if tenantLabel == "" {
		tenantLabel = account.TenantID
	}
	fmt.Fprintf(stdout, "Account %q added (%s, tenant %s)\n", finalAlias, account.Username, tenantLabel)

	// Only the host app can register the File Provider domain
	// (NSFileProviderManager.add lives in the Swift side, not the daemon).
	// Triggering it here saves the user a manual Finder/Spotlight step
	// after a fresh `brew install` + `ofem login`. Skipped on device-code
	// flows because those run in headless contexts (SSH, CI) where there
	// is no GUI to bring forward.
	if !opts.deviceCode {
		launchHostApp(stdout)
	}
	return nil
}

// launchHostApp asks macOS to bring the OneLake host app to the
// foreground via the app's bundle identifier. The host app's
// DomainSyncManager reconciles File Provider domains on launch and on
// applicationDidBecomeActive, so triggering an open is enough to
// register the just-added account's domain.
//
// We use `open -b <bundle-id>` rather than `open -a <name>` because
// Launch Services name lookup depends on its index being warm — a fresh
// `brew install` may not have the display name indexed yet, but the
// bundle id is always resolvable from the installed bundle. The
// function is a var so tests (and future headless callers) can swap it
// for a no-op.
var launchHostApp = func(stdout io.Writer) {
	c := exec.Command("open", "-b", "dev.debruyn.ofem")
	if err := c.Start(); err != nil {
		fmt.Fprintf(stdout, "warning: could not auto-open OneLake Explorer for macOS: %v\n", err)
		return
	}
	fmt.Fprintln(stdout, "Opened OneLake Explorer for macOS — Finder mount will appear shortly.")
}

// resolveAlias returns the alias to use for the new account. It first
// honors --account (if set), otherwise prompts the user. The prompt loop
// re-runs until the user supplies a valid alias.
func resolveAlias(stdin io.Reader, stdout io.Writer, flagAlias string, account auth.Account) (string, error) {
	if flagAlias != "" {
		if err := auth.ValidateAlias(flagAlias); err != nil {
			return "", fmt.Errorf("--account: %w", err)
		}
		return flagAlias, nil
	}

	suggested := suggestAlias(account)
	reader := bufio.NewReader(stdin)
	for {
		fmt.Fprintf(stdout, "Name this account [%s]: ", suggested)
		line, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			return "", fmt.Errorf("read alias: %w", err)
		}
		candidate := strings.TrimSpace(line)
		if candidate == "" {
			candidate = suggested
		}
		if vErr := auth.ValidateAlias(candidate); vErr != nil {
			fmt.Fprintf(stdout, "Invalid alias: %v\n", vErr)
			if err == io.EOF {
				return "", fmt.Errorf("no valid alias provided")
			}
			continue
		}
		return candidate, nil
	}
}

// suggestAlias derives a default alias from the tenant label or the
// local part of the user's UPN. The result is sanitised to satisfy
// [auth.ValidateAlias]; if it ends up empty we fall back to "work" so
// the prompt always shows a usable suggestion.
func suggestAlias(account auth.Account) string {
	candidates := []string{}
	if account.TenantName != "" {
		candidates = append(candidates, account.TenantName)
	}
	if at := strings.IndexByte(account.Username, '@'); at > 0 {
		// Prefer the domain over the local part because the local part
		// is usually a personal name; the domain often matches the
		// tenant well enough for a quick suggestion.
		candidates = append(candidates, account.Username[at+1:])
		candidates = append(candidates, account.Username[:at])
	}
	for _, c := range candidates {
		sanitised := sanitiseAlias(c)
		if sanitised != "" && auth.ValidateAlias(sanitised) == nil {
			return sanitised
		}
	}
	return "work"
}

// sanitiseAlias strips characters that [auth.ValidateAlias] rejects so a
// derived suggestion (from a tenant name or a domain) has a chance to
// pass validation. It deliberately does not lowercase: aliases preserve
// the case the user (implicitly) approves.
func sanitiseAlias(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z',
			r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9',
			r == '-' || r == '_' || r == '.':
			b.WriteRune(r)
		}
	}
	out := b.String()
	out = strings.TrimLeft(out, ".-")
	if len(out) > auth.MaxAliasLength {
		out = out[:auth.MaxAliasLength]
	}
	return out
}
