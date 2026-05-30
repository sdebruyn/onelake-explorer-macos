package auth

import (
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
)

// Keychain stores per-account secrets on disk under
// ~/Library/Group Containers/group.dev.debruyn.ofem/tokens/, one file
// per account with 0600 permissions. The App Group container is shared
// with the sandboxed File Provider Extension, so a single token cache
// serves the daemon, the host app, and the extension.
//
// An earlier implementation used the macOS Keychain via go-keyring; we
// moved off it because the MSAL token cache after a single Microsoft
// Entra login already exceeds the ~16 KB Generic Password size limit
// imposed by SecItemAdd, and chunking that across Keychain entries was
// more code than it was worth. File-system permissions on the per-user
// Group Container directory provide equivalent access control: only the
// same UNIX user (or root) can read the cache, the same boundary the
// Keychain itself enforces for non-iCloud items.
//
// The byte payload is opaque: the auth/MSAL layer serialises its token
// cache into the value, but the keychain layer does not interpret it.
// Implementations must:
//   - Accept arbitrary byte content, including non-UTF-8 bytes.
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

// NewKeychain returns a file-backed [Keychain] rooted at
// <ConfigDir>/tokens/ — i.e. inside the shared App Group container at
// ~/Library/Group Containers/group.dev.debruyn.ofem/tokens/. It resolves
// the path through config.ResolvePaths, which is correct for the
// unsandboxed daemon. Sandboxed callers (host app / File Provider
// Extension) must use NewKeychainAt with the App Group token dir instead,
// because os.UserHomeDir returns the per-app sandbox container there
// rather than the real home.
func NewKeychain() (Keychain, error) {
	paths, err := config.ResolvePaths()
	if err != nil {
		return nil, fmt.Errorf("keychain: resolve paths: %w", err)
	}
	return NewKeychainAt(filepath.Join(paths.ConfigDir, "tokens"))
}

// NewKeychainAt returns a file-backed [Keychain] rooted at the supplied
// directory, creating it (0700) if needed. Use this from sandboxed
// processes that resolve their App Group container through Apple's API.
func NewKeychainAt(dir string) (Keychain, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("keychain: create token dir %q: %w", dir, err)
	}
	return &fileKeychain{root: dir}, nil
}

type fileKeychain struct {
	root string
}

// path returns the on-disk location for an account's token blob. The
// account name is hex-encoded so any byte (including slashes) maps to
// a safe filename, and the same account always maps to the same file.
func (f *fileKeychain) path(account string) string {
	return filepath.Join(f.root, hex.EncodeToString([]byte(account))+".bin")
}

func (f *fileKeychain) Get(account string) ([]byte, error) {
	data, err := os.ReadFile(f.path(account))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("keychain: no entry for %q: %w", account, os.ErrNotExist)
		}
		return nil, fmt.Errorf("keychain get %q: %w", account, err)
	}
	return data, nil
}

func (f *fileKeychain) Set(account string, value []byte) error {
	if len(value) == 0 {
		return f.Delete(account)
	}
	dest := f.path(account)
	// Write to a temp file and atomically rename so a crash mid-write
	// can never leave a half-written token cache at the canonical path.
	tmp, err := os.CreateTemp(f.root, ".tmp-*")
	if err != nil {
		return fmt.Errorf("keychain set %q: create temp: %w", account, err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.Write(value); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("keychain set %q: write: %w", account, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("keychain set %q: close temp: %w", account, err)
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return fmt.Errorf("keychain set %q: chmod temp: %w", account, err)
	}
	if err := os.Rename(tmpName, dest); err != nil {
		return fmt.Errorf("keychain set %q: rename: %w", account, err)
	}
	return nil
}

func (f *fileKeychain) Delete(account string) error {
	err := os.Remove(f.path(account))
	if err == nil || errors.Is(err, os.ErrNotExist) {
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
