package auth

import (
	"context"
	"testing"
	"time"
)

func TestLoginDeviceCodeRejectsEmptyClientID(t *testing.T) {
	_, _, _, err := LoginDeviceCode(context.Background(), "", "", NewMemoryKeychain(), func(string, string, time.Time) {})
	if err == nil {
		t.Fatal("expected error for empty clientID")
	}
}

func TestLoginDeviceCodeRejectsNilKeychain(t *testing.T) {
	_, _, _, err := LoginDeviceCode(context.Background(), PlaceholderClientID, "", nil, func(string, string, time.Time) {})
	if err == nil {
		t.Fatal("expected error for nil keychain")
	}
}

func TestLoginDeviceCodeRejectsNilPrompt(t *testing.T) {
	_, _, _, err := LoginDeviceCode(context.Background(), PlaceholderClientID, "", NewMemoryKeychain(), nil)
	if err == nil {
		t.Fatal("expected error for nil prompt")
	}
}

// TestLoginDeviceCodeCancelsCleanlyOnContextCancel verifies the same
// cancellation behaviour as LoginInteractive. The full happy path
// requires a real Entra App Registration and the Microsoft devicecode
// endpoint, so we only cover the argument-validation and cancel path
// here; the integration test suite (OFE_INTEGRATION=1) is where the end
// to end flow lives.
func TestLoginDeviceCodeCancelsCleanlyOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	done := make(chan error, 1)
	go func() {
		_, _, _, err := LoginDeviceCode(ctx, PlaceholderClientID, "", NewMemoryKeychain(), func(string, string, time.Time) {})
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Errorf("expected error when ctx is cancelled, got nil")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("LoginDeviceCode did not return within 10s after ctx cancel")
	}
}
