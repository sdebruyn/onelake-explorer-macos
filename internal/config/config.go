// Package config holds the on-disk OFE configuration and the per-account
// registry. The shape mirrors the docs/auth.md and docs/telemetry.md
// designs. All paths live under the macOS Application Support directory
// at ~/Library/Application Support/dev.debruyn.ofe/.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/BurntSushi/toml"
)

// BundleID is the reverse-DNS identifier shared by every OFE process
// (CLI, daemon, host app, File Provider Extension). It anchors the macOS
// paths and the LaunchAgent label.
const BundleID = "dev.debruyn.ofe"

// File is the TOML config schema. New fields must be backwards-compatible:
// add with sensible zero-value defaults rather than removing or renaming.
type File struct {
	// InstallID is a locally generated UUIDv4 that pseudonymously identifies
	// this OFE installation in telemetry. Removed when the user runs
	// `brew uninstall --zap ofe`.
	InstallID string `toml:"install_id"`

	// Telemetry toggles opt-out telemetry. Default true. `OFE_TELEMETRY=0`
	// in the environment overrides this at runtime.
	Telemetry bool `toml:"telemetry"`

	// DefaultAccount is the alias used when a command omits an explicit
	// account. Empty means "no default; require explicit alias".
	DefaultAccount string `toml:"default_account"`

	// Cache holds blob-cache settings.
	Cache CacheConfig `toml:"cache"`

	// Net holds HTTP-client settings.
	Net NetConfig `toml:"net"`

	// Log holds logging settings.
	Log LogConfig `toml:"log"`

	// Accounts is the per-account registry. The key is the user-chosen alias.
	Accounts map[string]Account `toml:"accounts"`
}

// CacheConfig controls the on-disk blob cache.
type CacheConfig struct {
	// MaxSizeBytes is the LRU eviction threshold. Default 10 GiB.
	MaxSizeBytes int64 `toml:"max_size_bytes"`
}

// NetConfig controls HTTP behavior to OneLake / Fabric.
type NetConfig struct {
	// MaxConcurrencyPerAccount caps in-flight HTTP requests per account.
	// Default 4 (conservative; tuned by user preference, see docs/auth.md).
	MaxConcurrencyPerAccount int `toml:"max_concurrency_per_account"`
}

// LogConfig controls slog output.
type LogConfig struct {
	// Level is one of "debug", "info", "warn", "error". Default "info".
	Level string `toml:"level"`
}

// Account is one signed-in OneLake account, scoped to a single tenant.
// Multiple accounts in the same tenant are allowed (different aliases).
type Account struct {
	// Alias is the user-chosen short name (e.g. "work", "client-a"). It
	// matches the map key and is duplicated here for convenience.
	Alias string `toml:"alias"`

	// TenantID is the Microsoft Entra tenant GUID.
	TenantID string `toml:"tenant_id"`

	// TenantName is a human-friendly tenant label, if known. Display only.
	TenantName string `toml:"tenant_name,omitempty"`

	// HomeAccountID is MSAL's unique per-user-per-tenant identifier.
	HomeAccountID string `toml:"home_account_id"`

	// Username is the UPN (e.g. "sam@contoso.com"). Display only — we never
	// emit it to telemetry.
	Username string `toml:"username"`

	// AddedAt is the wall-clock timestamp of the first successful login.
	AddedAt string `toml:"added_at"`
}

// Default returns the zero-but-sensible config used the first time OFE
// starts on a machine. Callers persist this via Save once they have
// populated InstallID.
func Default() File {
	return File{
		Telemetry: true,
		Cache: CacheConfig{
			MaxSizeBytes: 10 * 1024 * 1024 * 1024, // 10 GiB
		},
		Net: NetConfig{
			MaxConcurrencyPerAccount: 4,
		},
		Log: LogConfig{
			Level: "info",
		},
		Accounts: map[string]Account{},
	}
}

// Paths resolves the canonical OFE locations on macOS. They are derived
// from $HOME and BundleID. Callers should treat them as read-only.
type Paths struct {
	ConfigDir  string // ~/Library/Application Support/dev.debruyn.ofe
	ConfigFile string // <ConfigDir>/config.toml
	CacheDir   string // ~/Library/Caches/dev.debruyn.ofe
	LogDir     string // ~/Library/Logs/dev.debruyn.ofe
	SocketPath string // <ConfigDir>/ofe.sock
}

// ResolvePaths returns the OFE paths for the current user. It does not
// create the directories; Save and the daemon do that on demand.
func ResolvePaths() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, fmt.Errorf("resolve home dir: %w", err)
	}
	cfgDir := filepath.Join(home, "Library", "Application Support", BundleID)
	return Paths{
		ConfigDir:  cfgDir,
		ConfigFile: filepath.Join(cfgDir, "config.toml"),
		CacheDir:   filepath.Join(home, "Library", "Caches", BundleID),
		LogDir:     filepath.Join(home, "Library", "Logs", BundleID),
		SocketPath: filepath.Join(cfgDir, "ofe.sock"),
	}, nil
}

// Store wraps a File with thread-safe load/save. The zero value is not
// usable; construct via Load or NewStore.
type Store struct {
	mu    sync.Mutex
	paths Paths
	file  File
}

// Load reads config.toml from disk. If the file does not exist, it
// returns a Store seeded with Default(). The caller should persist the
// store after the first run (which is when InstallID is generated).
func Load() (*Store, error) {
	paths, err := ResolvePaths()
	if err != nil {
		return nil, err
	}
	s := &Store{paths: paths, file: Default()}

	data, err := os.ReadFile(paths.ConfigFile)
	switch {
	case os.IsNotExist(err):
		return s, nil
	case err != nil:
		return nil, fmt.Errorf("read config: %w", err)
	}

	if err := toml.Unmarshal(data, &s.file); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if s.file.Accounts == nil {
		s.file.Accounts = map[string]Account{}
	}
	return s, nil
}

// Snapshot returns a copy of the current file. Mutations on the returned
// value do not affect the store.
func (s *Store) Snapshot() File {
	s.mu.Lock()
	defer s.mu.Unlock()

	out := s.file
	out.Accounts = make(map[string]Account, len(s.file.Accounts))
	for k, v := range s.file.Accounts {
		out.Accounts[k] = v
	}
	return out
}

// Update mutates the file under lock. The mutator receives a pointer to
// the live file; changes are persisted by Save.
func (s *Store) Update(mutator func(*File)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	mutator(&s.file)
}

// Paths returns the resolved OFE paths.
func (s *Store) Paths() Paths { return s.paths }

// Save writes the current config to disk atomically (write-temp + rename).
// It creates the parent directory if needed.
func (s *Store) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(s.paths.ConfigDir, 0o700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	tmp, err := os.CreateTemp(s.paths.ConfigDir, "config.toml.*")
	if err != nil {
		return fmt.Errorf("create temp config: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // best-effort cleanup if rename fails

	enc := toml.NewEncoder(tmp)
	if err := enc.Encode(s.file); err != nil {
		tmp.Close()
		return fmt.Errorf("encode config: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp config: %w", err)
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return fmt.Errorf("chmod temp config: %w", err)
	}
	if err := os.Rename(tmpName, s.paths.ConfigFile); err != nil {
		return fmt.Errorf("rename temp config: %w", err)
	}
	return nil
}
