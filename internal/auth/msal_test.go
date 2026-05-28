package auth

import (
	"context"
	"errors"
	"testing"

	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/cache"
	"github.com/AzureAD/microsoft-authentication-library-for-go/apps/public"
)

// stubMarshaler is a hand-rolled cache.Marshaler / cache.Unmarshaler that
// captures or yields bytes for KeychainCache tests. Using a stub instead
// of MSAL's real *storage.Manager keeps the test independent of MSAL
// internals.
type stubMarshaler struct {
	marshalData     []byte
	marshalErr      error
	unmarshaledIn   []byte
	unmarshalErr    error
	marshalCalled   int
	unmarshalCalled int
}

func (s *stubMarshaler) Marshal() ([]byte, error) {
	s.marshalCalled++
	if s.marshalErr != nil {
		return nil, s.marshalErr
	}
	return s.marshalData, nil
}

func (s *stubMarshaler) Unmarshal(b []byte) error {
	s.unmarshalCalled++
	s.unmarshaledIn = append([]byte(nil), b...)
	return s.unmarshalErr
}

func TestKeychainCacheExportThenReplaceRoundTrip(t *testing.T) {
	kc := NewMemoryKeychain()
	cc := NewKeychainCache(kc, "work")

	payload := []byte(`{"AccessToken":{"x":1}}`)
	exporter := &stubMarshaler{marshalData: payload}
	if err := cc.Export(context.Background(), exporter, cache.ExportHints{}); err != nil {
		t.Fatalf("Export: %v", err)
	}

	stored, err := kc.Get("work")
	if err != nil {
		t.Fatalf("kc.Get: %v", err)
	}
	if string(stored) != string(payload) {
		t.Errorf("stored = %s, want %s", stored, payload)
	}

	replacer := &stubMarshaler{}
	if err := cc.Replace(context.Background(), replacer, cache.ReplaceHints{}); err != nil {
		t.Fatalf("Replace: %v", err)
	}
	if string(replacer.unmarshaledIn) != string(payload) {
		t.Errorf("Replace fed Unmarshal %s, want %s", replacer.unmarshaledIn, payload)
	}
}

func TestKeychainCacheReplaceMissingIsNoop(t *testing.T) {
	kc := NewMemoryKeychain()
	cc := NewKeychainCache(kc, "work")
	target := &stubMarshaler{}
	if err := cc.Replace(context.Background(), target, cache.ReplaceHints{}); err != nil {
		t.Fatalf("Replace empty: %v", err)
	}
	if target.unmarshalCalled != 0 {
		t.Errorf("Unmarshal called %d times for missing entry, want 0", target.unmarshalCalled)
	}
}

func TestKeychainCacheReplaceEmptyBytesIsNoop(t *testing.T) {
	kc := NewMemoryKeychain()
	// Seed an explicit zero-length entry by going through Export with
	// empty bytes; the keychain treats that as Delete, so the subsequent
	// Replace must still be a no-op.
	cc := NewKeychainCache(kc, "work")
	if err := cc.Export(context.Background(), &stubMarshaler{marshalData: nil}, cache.ExportHints{}); err != nil {
		t.Fatalf("Export empty: %v", err)
	}
	target := &stubMarshaler{}
	if err := cc.Replace(context.Background(), target, cache.ReplaceHints{}); err != nil {
		t.Fatalf("Replace: %v", err)
	}
	if target.unmarshalCalled != 0 {
		t.Errorf("Unmarshal called %d times, want 0", target.unmarshalCalled)
	}
}

func TestKeychainCacheRespectsCancelledContext(t *testing.T) {
	kc := NewMemoryKeychain()
	cc := NewKeychainCache(kc, "work")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := cc.Export(ctx, &stubMarshaler{marshalData: []byte("x")}, cache.ExportHints{}); !errors.Is(err, context.Canceled) {
		t.Errorf("Export(cancelled) err = %v, want context.Canceled", err)
	}
	if err := cc.Replace(ctx, &stubMarshaler{}, cache.ReplaceHints{}); !errors.Is(err, context.Canceled) {
		t.Errorf("Replace(cancelled) err = %v, want context.Canceled", err)
	}
}

func TestKeychainCachePropagatesMarshalError(t *testing.T) {
	kc := NewMemoryKeychain()
	cc := NewKeychainCache(kc, "work")
	boom := errors.New("boom")
	err := cc.Export(context.Background(), &stubMarshaler{marshalErr: boom}, cache.ExportHints{})
	if !errors.Is(err, boom) {
		t.Errorf("Export err = %v, want errors.Is boom", err)
	}
}

func TestKeychainCachePropagatesUnmarshalError(t *testing.T) {
	kc := NewMemoryKeychain()
	if err := kc.Set("work", []byte("data")); err != nil {
		t.Fatalf("seed: %v", err)
	}
	cc := NewKeychainCache(kc, "work")
	boom := errors.New("boom")
	err := cc.Replace(context.Background(), &stubMarshaler{unmarshalErr: boom}, cache.ReplaceHints{})
	if !errors.Is(err, boom) {
		t.Errorf("Replace err = %v, want errors.Is boom", err)
	}
}

// stubMSALClient is a minimal MSALClient that returns canned AcquireTokenSilent
// results, used by both SilentToken tests below and Registry.Token tests in
// registry_test.go.
//
// lastScopes captures the scopes slice passed to the most recent
// AcquireTokenSilent call so tests can assert scope-forwarding without
// reaching into MSAL internals.
type stubMSALClient struct {
	silentResult public.AuthResult
	silentErr    error
	accounts     []public.Account
	accountsErr  error
	silentCalls  int
	lastScopes   []string
}

func (s *stubMSALClient) AcquireTokenSilent(_ context.Context, scopes []string, _ public.Account) (public.AuthResult, error) {
	s.silentCalls++
	s.lastScopes = append([]string{}, scopes...)
	return s.silentResult, s.silentErr
}

func (s *stubMSALClient) Accounts(_ context.Context) ([]public.Account, error) {
	return s.accounts, s.accountsErr
}

func TestSilentTokenReturnsAccessToken(t *testing.T) {
	client := &stubMSALClient{silentResult: public.AuthResult{AccessToken: "abc123"}}
	token, err := SilentToken(context.Background(), client, "work", public.Account{HomeAccountID: "h.t"}, OneLakeScopes)
	if err != nil {
		t.Fatalf("SilentToken: %v", err)
	}
	if token != "abc123" {
		t.Errorf("token = %q, want abc123", token)
	}
	if client.silentCalls != 1 {
		t.Errorf("silentCalls = %d, want 1", client.silentCalls)
	}
}

func TestSilentTokenMapsInteractionRequired(t *testing.T) {
	cases := []struct {
		name string
		err  error
	}{
		{"interaction_required", errors.New("interaction_required: The user must sign in.")},
		{"invalid_grant", errors.New("invalid_grant: refresh token expired")},
		{"AADSTS50076", errors.New("AADSTS50076: Due to a configuration change made by your administrator, or because you moved to a new location, you must use multi-factor authentication to access ...")},
		{"AADSTS70043", errors.New("AADSTS70043: The refresh token has expired due to inactivity.")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &stubMSALClient{silentErr: tc.err}
			_, err := SilentToken(context.Background(), client, "work", public.Account{HomeAccountID: "h.t"}, OneLakeScopes)
			if !errors.Is(err, ErrInteractionRequired) {
				t.Errorf("err = %v, want errors.Is ErrInteractionRequired", err)
			}
		})
	}
}

func TestSilentTokenWrapsOtherErrors(t *testing.T) {
	boom := errors.New("network unreachable")
	client := &stubMSALClient{silentErr: boom}
	_, err := SilentToken(context.Background(), client, "work", public.Account{HomeAccountID: "h.t"}, OneLakeScopes)
	if err == nil {
		t.Fatal("expected error")
	}
	if errors.Is(err, ErrInteractionRequired) {
		t.Errorf("err = %v, must NOT be ErrInteractionRequired", err)
	}
	if !errors.Is(err, boom) {
		t.Errorf("err = %v, want errors.Is boom", err)
	}
}

func TestSilentTokenRejectsNilClient(t *testing.T) {
	if _, err := SilentToken(context.Background(), nil, "work", public.Account{}, OneLakeScopes); err == nil {
		t.Fatal("expected error for nil client")
	}
}

func TestDefaultClientFactoryRejectsEmptyArguments(t *testing.T) {
	kc := NewMemoryKeychain()
	cases := []struct {
		name     string
		clientID string
		tenantID string
		alias    string
		kc       Keychain
	}{
		{"missing clientID", "", "tid", "work", kc},
		{"missing tenantID", "cid", "", "work", kc},
		{"missing alias", "cid", "tid", "", kc},
		{"missing kc", "cid", "tid", "work", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := DefaultClientFactory(tc.clientID, tc.tenantID, tc.kc, tc.alias); err == nil {
				t.Errorf("DefaultClientFactory(%q,%q,%v,%q) = nil err, want error", tc.clientID, tc.tenantID, tc.kc, tc.alias)
			}
		})
	}
}

func TestDefaultClientFactoryReturnsClient(t *testing.T) {
	kc := NewMemoryKeychain()
	c, err := DefaultClientFactory(EntraClientID, "11111111-2222-3333-4444-555555555555", kc, "work")
	if err != nil {
		t.Fatalf("DefaultClientFactory: %v", err)
	}
	if c == nil {
		t.Fatal("expected non-nil client")
	}
	// Calling Accounts on a fresh client with no cache must succeed and
	// return an empty list (it does not hit the network).
	accs, err := c.Accounts(context.Background())
	if err != nil {
		t.Fatalf("Accounts: %v", err)
	}
	if len(accs) != 0 {
		t.Errorf("Accounts() = %v, want empty", accs)
	}
}

func TestSilentTokenRejectsEmptyScopes(t *testing.T) {
	client := &stubMSALClient{silentResult: public.AuthResult{AccessToken: "tok"}}
	_, err := SilentToken(context.Background(), client, "work", public.Account{HomeAccountID: "h.t"}, nil)
	if err == nil {
		t.Fatal("expected error for nil scopes")
	}
	if client.silentCalls != 0 {
		t.Errorf("AcquireTokenSilent called %d times, want 0 (error before network call)", client.silentCalls)
	}

	_, err = SilentToken(context.Background(), client, "work", public.Account{HomeAccountID: "h.t"}, []string{})
	if err == nil {
		t.Fatal("expected error for empty scopes slice")
	}
	if client.silentCalls != 0 {
		t.Errorf("AcquireTokenSilent called %d times, want 0 (error before network call)", client.silentCalls)
	}
}
