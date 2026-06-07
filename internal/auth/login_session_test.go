package auth

import (
	"errors"
	"testing"
	"time"
)

func TestLoginSessionStoreRegisterAndClaim(t *testing.T) {
	store := NewLoginSessionStore()
	sess := &LoginSession{
		ID:       "test-session-id",
		AuthURL:  "https://login.microsoftonline.com/oauth2/authorize?...",
		ResultCh: make(chan LoginSessionResult, 1),
	}
	store.Register(sess)

	got, err := store.Claim("test-session-id")
	if err != nil {
		t.Fatalf("Claim: %v", err)
	}
	if got != sess {
		t.Errorf("Claim returned different session pointer")
	}
}

func TestLoginSessionStoreClaimRemovesSession(t *testing.T) {
	store := NewLoginSessionStore()
	sess := &LoginSession{
		ID:       "once-only",
		ResultCh: make(chan LoginSessionResult, 1),
	}
	store.Register(sess)

	if _, err := store.Claim("once-only"); err != nil {
		t.Fatalf("first Claim: %v", err)
	}
	// Second Claim must fail — session is consumed.
	_, err := store.Claim("once-only")
	if err == nil {
		t.Fatal("expected error on second Claim of the same session")
	}
	if !errors.Is(err, ErrSessionNotFound) {
		t.Errorf("want ErrSessionNotFound, got %v", err)
	}
}

func TestLoginSessionStoreClaimUnknownIDErrors(t *testing.T) {
	store := NewLoginSessionStore()
	_, err := store.Claim("does-not-exist")
	if err == nil {
		t.Fatal("expected error for unknown session id")
	}
	if !errors.Is(err, ErrSessionNotFound) {
		t.Errorf("want ErrSessionNotFound, got %v", err)
	}
}

func TestLoginSessionStoreClaimEmptyIDErrors(t *testing.T) {
	store := NewLoginSessionStore()
	_, err := store.Claim("")
	if err == nil {
		t.Fatal("expected error for empty session id")
	}
}

func TestLoginSessionStoreRegisterEvictsExpiredSessions(t *testing.T) {
	store := NewLoginSessionStore()
	expired := &LoginSession{
		ID:       "old-session",
		ResultCh: make(chan LoginSessionResult, 1),
	}
	store.Register(expired)
	// Back-date the createdAt so it looks expired.
	store.mu.Lock()
	store.sessions["old-session"].createdAt = time.Now().Add(-(LoginSessionTTL + time.Second))
	store.mu.Unlock()

	// Registering a new session triggers the sweep.
	fresh := &LoginSession{
		ID:       "fresh-session",
		ResultCh: make(chan LoginSessionResult, 1),
	}
	store.Register(fresh)

	// The expired session should be gone.
	if _, err := store.Claim("old-session"); !errors.Is(err, ErrSessionNotFound) {
		t.Errorf("expired session should have been evicted, got %v", err)
	}
	// The fresh session should still be claimable.
	if _, err := store.Claim("fresh-session"); err != nil {
		t.Errorf("fresh session should be claimable: %v", err)
	}
}

func TestLoginSessionStoreRegisterPanicsOnNilSession(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for nil session")
		}
	}()
	store := NewLoginSessionStore()
	store.Register(nil)
}

func TestLoginSessionStoreRegisterPanicsOnEmptyID(t *testing.T) {
	defer func() {
		if r := recover(); r == nil {
			t.Error("expected panic for empty session ID")
		}
	}()
	store := NewLoginSessionStore()
	store.Register(&LoginSession{ID: "", ResultCh: make(chan LoginSessionResult, 1)})
}
