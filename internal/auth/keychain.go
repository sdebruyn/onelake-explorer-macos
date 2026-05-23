package auth

import (
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"sync"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"

	keyring "github.com/zalando/go-keyring"
)

// Keychain stores small per-account secrets in the macOS Keychain under
// the service name "dev.debruyn.ofem" (taken from [config.BundleID]).
//
// The byte payload is treated as opaque: the auth/MSAL layer (added in a
// follow-up change) serialises its token cache into the value, but the
// keychain layer itself does not interpret it. Implementations must:
//   - Accept arbitrary byte content, including bytes that are not valid
//     UTF-8.
//   - Treat a Set with an empty value (nil or zero-length) as a Delete,
//     so callers do not need a separate code path for "clear this
//     account".
//   - Return an error that satisfies errors.Is(err, os.ErrNotExist) when
//     Get is called for an account that has no stored value, so callers
//     can distinguish "missing" from real errors.
type Keychain interface {
	// Get returns the bytes previously stored for account, or an error
	// wrapping os.ErrNotExist if no value is stored.
	Get(account string) ([]byte, error)

	// Set stores value under account. An empty value deletes the entry.
	Set(account string, value []byte) error

	// Delete removes the entry for account. Deleting a missing entry is
	// not an error.
	Delete(account string) error
}

// keychainService is the Keychain service name shared by all OFEM
// processes. It matches the reverse-DNS bundle identifier so that
// Keychain Access.app groups OFEM items together.
const keychainService = config.BundleID

// NewKeychain returns a [Keychain] backed by the macOS Keychain via
// github.com/zalando/go-keyring. Bytes are base64-encoded internally
// because go-keyring's public API is string-only.
func NewKeychain() Keychain {
	return &systemKeychain{}
}

type systemKeychain struct{}

func (s *systemKeychain) Get(account string) ([]byte, error) {
	encoded, err := keyring.Get(keychainService, account)
	if err != nil {
		if errors.Is(err, keyring.ErrNotFound) {
			return nil, fmt.Errorf("keychain: no entry for %q: %w", account, os.ErrNotExist)
		}
		return nil, fmt.Errorf("keychain get %q: %w", account, err)
	}
	raw, decErr := base64.StdEncoding.DecodeString(encoded)
	if decErr != nil {
		return nil, fmt.Errorf("keychain decode %q: %w", account, decErr)
	}
	return raw, nil
}

func (s *systemKeychain) Set(account string, value []byte) error {
	if len(value) == 0 {
		return s.Delete(account)
	}
	encoded := base64.StdEncoding.EncodeToString(value)
	if err := keyring.Set(keychainService, account, encoded); err != nil {
		return fmt.Errorf("keychain set %q: %w", account, err)
	}
	return nil
}

func (s *systemKeychain) Delete(account string) error {
	err := keyring.Delete(keychainService, account)
	if err == nil || errors.Is(err, keyring.ErrNotFound) {
		return nil
	}
	return fmt.Errorf("keychain delete %q: %w", account, err)
}

// MemoryKeychain is an in-memory implementation of [Keychain] for tests.
// It is safe for concurrent use.
type MemoryKeychain struct {
	mu      sync.Mutex
	entries map[string][]byte
}

// NewMemoryKeychain returns an empty in-memory [Keychain].
func NewMemoryKeychain() *MemoryKeychain {
	return &MemoryKeychain{entries: make(map[string][]byte)}
}

// Get returns the bytes for account, or an error wrapping os.ErrNotExist
// if no value is stored.
func (m *MemoryKeychain) Get(account string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.entries[account]
	if !ok {
		return nil, fmt.Errorf("memory keychain: no entry for %q: %w", account, os.ErrNotExist)
	}
	out := make([]byte, len(v))
	copy(out, v)
	return out, nil
}

// Set stores a copy of value under account. An empty value deletes the
// entry.
func (m *MemoryKeychain) Set(account string, value []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(value) == 0 {
		delete(m.entries, account)
		return nil
	}
	cp := make([]byte, len(value))
	copy(cp, value)
	m.entries[account] = cp
	return nil
}

// Delete removes the entry for account. Deleting a missing entry is not
// an error.
func (m *MemoryKeychain) Delete(account string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.entries, account)
	return nil
}
