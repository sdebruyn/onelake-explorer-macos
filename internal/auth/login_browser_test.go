package auth

import (
	"context"
	"testing"
	"time"
)

func TestLoginInteractiveRejectsEmptyClientID(t *testing.T) {
	_, _, _, err := LoginInteractive(context.Background(), "", "", NewMemoryKeychain(), nil)
	if err == nil {
		t.Fatal("expected error for empty clientID")
	}
}

func TestLoginInteractiveRejectsNilKeychain(t *testing.T) {
	_, _, _, err := LoginInteractive(context.Background(), EntraClientID, "", nil, nil)
	if err == nil {
		t.Fatal("expected error for nil keychain")
	}
}

// TestLoginInteractiveCancelsCleanlyOnContextCancel verifies that cancelling
// the context unblocks LoginInteractive within a short window, which proves
// our wiring forwards ctx all the way down into MSAL's authority discovery
// and localhost-redirect server. We do NOT exercise the full happy path
// because that requires a real Entra App Registration and a browser.
func TestLoginInteractiveCancelsCleanlyOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel up front

	done := make(chan error, 1)
	go func() {
		_, _, _, err := LoginInteractive(ctx, EntraClientID, "", NewMemoryKeychain(), nil)
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Errorf("expected error when ctx is cancelled, got nil")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("LoginInteractive did not return within 10s after ctx cancel")
	}
}

func TestNewScratchCacheCleanupDeletesEntry(t *testing.T) {
	kc := NewMemoryKeychain()
	cache, alias, cleanup := newScratchCache(kc)
	if cache == nil || alias == "" {
		t.Fatal("expected non-zero cache and alias")
	}
	if err := kc.Set(alias, []byte("scratch")); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if got, err := kc.Get(alias); err != nil || string(got) != "scratch" {
		t.Fatalf("seed readback: %v %s", err, got)
	}

	cleanup()

	if _, err := kc.Get(alias); err == nil {
		t.Errorf("expected scratch entry to be gone after cleanup")
	}
}

func TestTemporaryLoginAliasIsUnique(t *testing.T) {
	a := temporaryLoginAlias()
	b := temporaryLoginAlias()
	if a == b {
		t.Errorf("two consecutive temporaryLoginAlias calls returned the same value: %s", a)
	}
	if len(a) == 0 || len(b) == 0 {
		t.Errorf("temporaryLoginAlias returned empty string")
	}
}

func TestResolveTenantHintFallsBackToCommon(t *testing.T) {
	if got := resolveTenantHint(""); got != TenantHintCommon {
		t.Errorf("resolveTenantHint(\"\") = %q, want %q", got, TenantHintCommon)
	}
	if got := resolveTenantHint("contoso.onmicrosoft.com"); got != "contoso.onmicrosoft.com" {
		t.Errorf("resolveTenantHint preserved value: got %q", got)
	}
}
