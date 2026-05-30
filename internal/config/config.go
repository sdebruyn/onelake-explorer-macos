// Package config holds the on-disk OFEM configuration and the per-account
// registry. The shape mirrors the docs/auth.md and docs/telemetry.md
// designs. All on-disk state lives under the macOS App Group container at
// ~/Library/Group Containers/group.dev.debruyn.ofem/ so the daemon, the
// host app, and the sandboxed File Provider Extension can share it. See
// docs/file-provider.md for the rationale.
package config

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sync"

	"github.com/BurntSushi/toml"
)

// BundleID is the reverse-DNS identifier shared by every OFEM process
// (daemon, host app, File Provider Extension). It anchors the
// LaunchAgent label and the Apple bundle identifiers.
const BundleID = "dev.debruyn.ofem"

// GroupID is the App Group identifier shared by the host app, the File
// Provider Extension, and the daemon. It controls (a) the shared
// container directory at ~/Library/Group Containers/<GroupID>/ and (b)
// the keychain-access-group used to share the MSAL token cache.
//
// Conventionally, App Group identifiers are prefixed with "group." so
// they are recognisable to other tooling (codesign, profiles, …).
const GroupID = "group." + BundleID

// File is the TOML config schema. New fields must be backwards-compatible:
// add with sensible zero-value defaults rather than removing or renaming.
type File struct {
	// InstallID is a locally generated UUIDv4 that pseudonymously identifies
	// this OFEM installation in telemetry. Removed when the user runs
	// `brew uninstall --zap ofem`.
	InstallID string `toml:"install_id"`

	// Telemetry toggles opt-out telemetry. Default true. `OFEM_TELEMETRY=0`
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
//
// Wire/disk schema: the LRU eviction threshold is expressed in whole
// gigabytes (1 GB = 1_073_741_824 bytes — binary, matching what Finder /
// `du -h` show). Fractional GBs are intentionally not supported; the
// menubar Stepper writes integer GBs and the cache layer converts to
// bytes at the seam (see [CacheConfig.MaxBytes]).
//
// Backwards compatibility: the previous schema used `max_size_bytes`
// (raw int64). Existing configs in the wild are migrated on first read
// by [Store.normalise] — `max_size_bytes` is converted to whole GBs (with
// `math.Ceil` to avoid silently shrinking a user's customised limit
// below what they set) and rewritten as `max_size_gb` on the next save.
// `max_size_bytes` is preserved on the struct only to detect the legacy
// shape; it is omitted from any future save (see omitempty).
type CacheConfig struct {
	// MaxSizeGB is the LRU eviction threshold in gigabytes (binary).
	// Default 10. A value of 0 means "no limit" (eviction is a no-op).
	MaxSizeGB int `toml:"max_size_gb"`

	// MaxSizeBytes is the legacy, byte-precision threshold. Kept ONLY to
	// recognise pre-migration configs on disk; new code should read
	// [MaxSizeGB] (or [CacheConfig.MaxBytes] for byte-precision needs).
	// omitzero drops the legacy key on save once migration has happened
	// (BurntSushi/toml's omitempty does NOT skip zero ints — only empty
	// strings/slices/maps — so omitzero is required to actually remove
	// the key from the rewritten config).
	MaxSizeBytes int64 `toml:"max_size_bytes,omitzero"`
}

// bytesPerGB is the binary gigabyte multiplier (1 GiB = 2^30 bytes).
// CacheConfig.MaxSizeGB uses binary GBs to match what Finder, `du -h`
// and macOS storage reports show.
const bytesPerGB int64 = 1024 * 1024 * 1024

// MaxBytes returns the cache size limit in bytes for callers that need
// byte-precision (the cache package's eviction sums byte counts from the
// blob table). 0 means "no limit".
func (c CacheConfig) MaxBytes() int64 {
	return int64(c.MaxSizeGB) * bytesPerGB
}

// NetConfig controls HTTP behavior to OneLake / Fabric.
type NetConfig struct {
	// MaxConcurrentUploadsPerAccount caps parallel sync.Put calls per
	// account. Default 4. Lower this when running on metered networks.
	MaxConcurrentUploadsPerAccount int `toml:"max_concurrent_uploads_per_account"`

	// MaxConcurrentDownloadsPerAccount caps parallel sync.Open calls
	// per account. Default 8. Raise this when Finder users routinely
	// open many cloud-only files at once.
	MaxConcurrentDownloadsPerAccount int `toml:"max_concurrent_downloads_per_account"`
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

	// ClientID is the Entra App Registration client GUID this account
	// authenticated against. Empty/absent means "use the built-in OFEM
	// registration"; only present for Bring Your Own App Registration
	// setups. Persisted because MSAL's token cache is keyed on
	// (client, tenant, account), so silent refresh on the next daemon
	// start must reach for the same client ID the original login used.
	ClientID string `toml:"client_id,omitempty"`
}

// MinCacheSizeGB is the lower bound enforced by [ApplyConfig] on the
// cache.max_size_gb key. 1 GB is small enough that a curious user can
// experiment without breaking the cache; smaller values produce a cache
// that thrashes on the smallest of file downloads.
const MinCacheSizeGB = 1

// MaxCacheSizeGB is the upper bound enforced by [ApplyConfig] on the
// cache.max_size_gb key. 1024 GB (1 TiB) is well past any realistic
// laptop SSD; it exists mainly to catch typos in the menubar Stepper.
const MaxCacheSizeGB = 1024

// DefaultCacheSizeGB is the seeded value for new installations. 10 GB
// matches the pre-refactor default (10 GiB == 10 binary GB).
const DefaultCacheSizeGB = 10

// Default returns the zero-but-sensible config used the first time OFEM
// starts on a machine. Callers persist this via Save once they have
// populated InstallID.
func Default() File {
	return File{
		Telemetry: true,
		Cache: CacheConfig{
			MaxSizeGB: DefaultCacheSizeGB,
		},
		Net: NetConfig{
			MaxConcurrentUploadsPerAccount:   4,
			MaxConcurrentDownloadsPerAccount: 8,
		},
		Log: LogConfig{
			Level: "info",
		},
		Accounts: map[string]Account{},
	}
}

// Paths resolves the canonical OFEM locations on macOS. They all sit
// under the shared App Group container so the sandboxed File Provider
// Extension can read and write them alongside the daemon and the host
// app. Callers should treat them as read-only.
type Paths struct {
	// ConfigDir is the App Group container root. All other paths are
	// derived from it.
	ConfigDir string // ~/Library/Group Containers/group.dev.debruyn.ofem
	// ConfigFile is the TOML config file with accounts and settings.
	ConfigFile string // <ConfigDir>/config.toml
	// CacheDir holds cache.sqlite and the blob shards.
	CacheDir string // <ConfigDir>/cache
	// LogDir holds rotated daemon logs.
	LogDir string // <ConfigDir>/log
	// SocketPath is the host-app ↔ daemon Unix-domain socket. The
	// sandboxed extension never talks to it (it goes over XPC); colocating
	// it with the rest keeps the path layout uniform.
	SocketPath string // <ConfigDir>/ofem.sock
}

// ResolvePaths returns the OFEM paths for the current user. It does not
// create the directories; Save and the daemon do that on demand.
func ResolvePaths() (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, fmt.Errorf("resolve home dir: %w", err)
	}
	cfgDir := filepath.Join(home, "Library", "Group Containers", GroupID)
	return Paths{
		ConfigDir:  cfgDir,
		ConfigFile: filepath.Join(cfgDir, "config.toml"),
		CacheDir:   filepath.Join(cfgDir, "cache"),
		LogDir:     filepath.Join(cfgDir, "log"),
		SocketPath: filepath.Join(cfgDir, "ofem.sock"),
	}, nil
}

// Store wraps a File with thread-safe load/save. The zero value is not
// usable; construct via Load or NewStore.
type Store struct {
	mu    sync.Mutex
	paths Paths
	file  File
}

// Load reads config.toml from the canonical paths returned by
// ResolvePaths. It is the right entry point for the daemon, which runs
// unsandboxed and can resolve $HOME directly. Sandboxed callers (the
// host app / File Provider Extension) must use LoadFrom with an App
// Group container path instead, because os.UserHomeDir returns the
// per-app sandbox container there rather than the real home.
func Load() (*Store, error) {
	paths, err := ResolvePaths()
	if err != nil {
		return nil, err
	}
	return LoadFrom(paths)
}

// LoadFrom reads config.toml from the supplied paths. If the file does
// not exist, it returns a Store seeded with Default(). The caller should
// persist the store after the first run (which is when InstallID is
// generated). Use this from sandboxed processes that resolve their App
// Group container through Apple's API rather than $HOME.
func LoadFrom(paths Paths) (*Store, error) {
	s := &Store{paths: paths, file: Default()}

	data, err := os.ReadFile(paths.ConfigFile)
	switch {
	case os.IsNotExist(err):
		return s, nil
	case err != nil:
		return nil, fmt.Errorf("read config: %w", err)
	}

	// Zero the Cache block before unmarshal so migrateCacheConfig can
	// distinguish "file omits [cache] entirely → keep the Default()
	// seed" from "file has [cache] with legacy max_size_bytes only →
	// migrate". With BurntSushi/toml, missing keys preserve struct
	// defaults, so without this reset both shapes would look identical.
	s.file.Cache = CacheConfig{}

	if err := toml.Unmarshal(data, &s.file); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if s.file.Accounts == nil {
		s.file.Accounts = map[string]Account{}
	}
	migrateCacheConfig(&s.file)
	return s, nil
}

// migrateCacheConfig promotes the legacy `max_size_bytes` key to the new
// `max_size_gb` representation on read so existing on-disk configs from
// pre-2026.06 OFEM installations keep working. The conversion uses
// math.Ceil so a 10 GiB customisation never shrinks below what the user
// originally asked for. The legacy field is zeroed so the next Save
// drops the key from disk (it carries omitempty).
//
// When both fields are absent the file omitted the `[cache]` table
// entirely and the seeded Default() value already populated max_size_gb;
// this function leaves that case untouched.
func migrateCacheConfig(f *File) {
	if f.Cache.MaxSizeGB > 0 {
		// New schema present — clear legacy bytes if both somehow coexist
		// (e.g. user hand-edited the file) to ensure subsequent saves
		// emit only the canonical key.
		f.Cache.MaxSizeBytes = 0
		return
	}
	if f.Cache.MaxSizeBytes > 0 {
		gbFloat := float64(f.Cache.MaxSizeBytes) / float64(bytesPerGB)
		f.Cache.MaxSizeGB = int(math.Ceil(gbFloat))
		if f.Cache.MaxSizeGB < MinCacheSizeGB {
			f.Cache.MaxSizeGB = MinCacheSizeGB
		}
		f.Cache.MaxSizeBytes = 0
		return
	}
	// Both zero. Two sub-cases collapse to the same fix:
	//   1. The file omits [cache] entirely (fresh install or pre-2026.05
	//      config without cache settings).
	//   2. The file has [cache] with max_size_bytes = 0 (the legacy
	//      "unlimited" sentinel, supported only by the byte-precision
	//      parser). The GB schema does not offer an unlimited option;
	//      seeding the default keeps the cache bounded.
	// In both cases, seeding the default is the safe choice.
	f.Cache.MaxSizeGB = DefaultCacheSizeGB
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
// the live file; changes are persisted by a subsequent Save.
//
// Prefer [Store.UpdateAndSave] when the mutation must be persisted: a
// separate Update + Save pair releases the lock between the two, so a
// concurrent mutation can interleave and the on-disk file can reflect a
// state no single caller intended.
func (s *Store) Update(mutator func(*File)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	mutator(&s.file)
}

// UpdateAndSave applies mutator and persists the result while holding the
// lock across BOTH steps, so concurrent writers cannot interleave between
// the mutation and the encode+rename and leave the file in a state no
// caller intended (M-1). The mutator must not call back into the Store.
func (s *Store) UpdateAndSave(mutator func(*File)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	mutator(&s.file)
	return s.saveLocked()
}

// Paths returns the resolved OFEM paths.
func (s *Store) Paths() Paths { return s.paths }

// Save writes the current config to disk atomically (write-temp + rename).
// It creates the parent directory if needed.
func (s *Store) Save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.saveLocked()
}

// saveLocked encodes and atomically renames the config. The caller MUST
// hold s.mu.
func (s *Store) saveLocked() error {
	if err := os.MkdirAll(s.paths.ConfigDir, 0o700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	tmp, err := os.CreateTemp(s.paths.ConfigDir, "config.toml.*")
	if err != nil {
		return fmt.Errorf("create temp config: %w", err)
	}
	tmpName := tmp.Name()
	// best-effort cleanup if rename fails; the rename below makes it moot otherwise.
	defer func() { _ = os.Remove(tmpName) }()

	enc := toml.NewEncoder(tmp)
	if err := enc.Encode(s.file); err != nil {
		_ = tmp.Close()
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
