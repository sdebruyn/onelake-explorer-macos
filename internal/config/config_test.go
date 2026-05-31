package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

func TestDefault(t *testing.T) {
	d := Default()
	if !d.Telemetry {
		t.Error("telemetry should default to true (opt-out)")
	}
	if d.Cache.MaxSizeGB != DefaultCacheSizeGB {
		t.Errorf("Cache.MaxSizeGB = %d, want %d", d.Cache.MaxSizeGB, DefaultCacheSizeGB)
	}
	if d.Cache.MaxBytes() != int64(DefaultCacheSizeGB)*1024*1024*1024 {
		t.Errorf("Cache.MaxBytes() = %d, want 10 GiB", d.Cache.MaxBytes())
	}
	if d.Log.Level != "info" {
		t.Errorf("Log.Level = %q, want %q", d.Log.Level, "info")
	}
	if d.Accounts == nil {
		t.Error("Accounts map must be non-nil")
	}
}

// TestMigrateLegacyMaxSizeBytes verifies that a config carrying only the
// legacy max_size_bytes key is migrated to max_size_gb on read, and that
// the next save drops the legacy key from disk. This is the critical
// backwards-compat path for users upgrading from pre-2026.06 OFEM.
func TestMigrateLegacyMaxSizeBytes(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{
		ConfigDir:  dir,
		ConfigFile: filepath.Join(dir, "config.toml"),
	}

	// Hand-write a legacy-shaped config. 5 GiB exactly so the ceil math
	// is verifiable. Also include a non-default account so we can assert
	// the migration doesn't clobber unrelated user customisations.
	legacy := []byte(`install_id = "legacy-install"
telemetry = false
default_account = "work"

[cache]
max_size_bytes = 5368709120

[accounts.work]
alias = "work"
tenant_id = "t1"
home_account_id = "h1"
username = "u@example.com"
added_at = "2026-05-01T00:00:00Z"
`)
	if err := os.WriteFile(paths.ConfigFile, legacy, 0o600); err != nil {
		t.Fatalf("seed legacy config: %v", err)
	}

	store, err := LoadFrom(paths)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	f := store.Snapshot()
	if f.Cache.MaxSizeGB != 5 {
		t.Errorf("MaxSizeGB after migration = %d, want 5", f.Cache.MaxSizeGB)
	}
	if f.Cache.MaxSizeBytes != 0 {
		t.Errorf("MaxSizeBytes after migration = %d, want 0 (legacy key cleared)", f.Cache.MaxSizeBytes)
	}
	if f.InstallID != "legacy-install" {
		t.Errorf("InstallID = %q, want %q (migration must preserve unrelated keys)", f.InstallID, "legacy-install")
	}
	if f.Telemetry {
		t.Errorf("Telemetry = true, want false (migration must preserve unrelated keys)")
	}
	if _, ok := f.Accounts["work"]; !ok {
		t.Errorf("accounts.work was dropped during migration")
	}

	// Save and re-read raw bytes: the legacy key must be gone.
	if err := store.UpdateAndSave(func(_ *File) {}); err != nil {
		t.Fatalf("UpdateAndSave: %v", err)
	}
	raw, err := os.ReadFile(paths.ConfigFile)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	rawStr := string(raw)
	if strings.Contains(rawStr, "max_size_bytes") {
		t.Errorf("saved config still contains legacy max_size_bytes key:\n%s", rawStr)
	}
	if !strings.Contains(rawStr, "max_size_gb = 5") {
		t.Errorf("saved config missing canonical max_size_gb = 5:\n%s", rawStr)
	}
}

// TestMigrateLegacyMaxSizeBytesCeils verifies the migration rounds up
// (math.Ceil) rather than truncating, so a 10737418241-byte limit (just
// over 10 GiB) becomes 11 GB rather than shrinking to 10.
func TestMigrateLegacyMaxSizeBytesCeils(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{
		ConfigDir:  dir,
		ConfigFile: filepath.Join(dir, "config.toml"),
	}
	legacy := []byte("[cache]\nmax_size_bytes = 10737418241\n")
	if err := os.WriteFile(paths.ConfigFile, legacy, 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	store, err := LoadFrom(paths)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	if got := store.Snapshot().Cache.MaxSizeGB; got != 11 {
		t.Errorf("MaxSizeGB = %d, want 11 (ceil of 10 GiB + 1 byte)", got)
	}
}

// TestMigrateLegacyZeroBecomesDefault verifies that the legacy
// `max_size_bytes = 0` ("unlimited") sentinel — which the new GB schema
// does not support — is replaced by the default rather than silently
// disabling eviction.
func TestMigrateLegacyZeroBecomesDefault(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{
		ConfigDir:  dir,
		ConfigFile: filepath.Join(dir, "config.toml"),
	}
	legacy := []byte("[cache]\nmax_size_bytes = 0\n")
	if err := os.WriteFile(paths.ConfigFile, legacy, 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	store, err := LoadFrom(paths)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	if got := store.Snapshot().Cache.MaxSizeGB; got != DefaultCacheSizeGB {
		t.Errorf("MaxSizeGB = %d, want %d", got, DefaultCacheSizeGB)
	}
}

// TestLoadFromHonorsNewMaxSizeGB confirms a config already on the new
// schema is loaded verbatim (no migration logic interferes).
func TestLoadFromHonorsNewMaxSizeGB(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{
		ConfigDir:  dir,
		ConfigFile: filepath.Join(dir, "config.toml"),
	}
	if err := os.WriteFile(paths.ConfigFile, []byte("[cache]\nmax_size_gb = 25\n"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	store, err := LoadFrom(paths)
	if err != nil {
		t.Fatalf("LoadFrom: %v", err)
	}
	if got := store.Snapshot().Cache.MaxSizeGB; got != 25 {
		t.Errorf("MaxSizeGB = %d, want 25", got)
	}
}

// TestMaxBytesConversion verifies the GB → bytes seam, the contract
// that the daemon hands to the cache package.
func TestMaxBytesConversion(t *testing.T) {
	cases := []struct {
		gb   int
		want int64
	}{
		{1, 1 << 30},
		{10, 10 * (1 << 30)},
		{1024, 1024 * (1 << 30)},
		{0, 0},
	}
	for _, tc := range cases {
		got := CacheConfig{MaxSizeGB: tc.gb}.MaxBytes()
		if got != tc.want {
			t.Errorf("CacheConfig{MaxSizeGB: %d}.MaxBytes() = %d, want %d", tc.gb, got, tc.want)
		}
	}
}

func TestStoreRoundtrip(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{
		ConfigDir:  dir,
		ConfigFile: filepath.Join(dir, "config.toml"),
	}

	s := &Store{paths: paths, file: Default()}
	if err := s.UpdateAndSave(func(f *File) {
		f.InstallID = "abc-123"
		f.DefaultAccount = "work"
		f.Accounts["work"] = Account{
			Alias:         "work",
			TenantID:      "tenant-guid",
			HomeAccountID: "user.tenant",
			Username:      "user@example.com",
			AddedAt:       "2026-05-23T12:00:00Z",
		}
	}); err != nil {
		t.Fatalf("UpdateAndSave: %v", err)
	}

	// Verify file permissions and content via a second store.
	raw, err := os.ReadFile(paths.ConfigFile)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	var reloaded File
	if err := toml.Unmarshal(raw, &reloaded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if reloaded.InstallID != "abc-123" {
		t.Errorf("InstallID = %q, want abc-123", reloaded.InstallID)
	}
	if got, ok := reloaded.Accounts["work"]; !ok || got.TenantID != "tenant-guid" {
		t.Errorf("work account not round-tripped: %+v", reloaded.Accounts)
	}

	info, err := os.Stat(paths.ConfigFile)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Errorf("config perm = %#o, want 0600", mode)
	}
}

func TestResolvePathsUnderGroupContainer(t *testing.T) {
	p, err := ResolvePaths()
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("home dir: %v", err)
	}
	wantRoot := filepath.Join(home, "Library", "Group Containers", GroupID)

	if p.ConfigDir != wantRoot {
		t.Errorf("ConfigDir = %q, want %q", p.ConfigDir, wantRoot)
	}

	// Every other path must be a direct descendant of the App Group
	// container root — that is what pins the new layout (the old layout
	// scattered paths across Application Support, Caches, and Logs).
	for name, path := range map[string]string{
		"CacheDir":   p.CacheDir,
		"LogDir":     p.LogDir,
		"SocketPath": p.SocketPath,
		"ConfigFile": p.ConfigFile,
	} {
		if !strings.HasPrefix(path, wantRoot+string(filepath.Separator)) {
			t.Errorf("%s = %q is not a descendant of ConfigDir %q", name, path, wantRoot)
		}

		// Every path must reference the full GroupID, not just the
		// BundleID — otherwise the old layout would also satisfy the
		// assertion (BundleID is a substring of GroupID).
		if !strings.Contains(path, GroupID) {
			t.Errorf("%s = %q does not contain GroupID %q", name, path, GroupID)
		}

		// Negative assertions: none of the legacy macOS locations may
		// appear in any resolved path.
		for _, legacy := range []string{
			"Application Support",
			filepath.Join("Library", "Caches"),
			filepath.Join("Library", "Logs"),
		} {
			if strings.Contains(path, legacy) {
				t.Errorf("%s = %q still references legacy location %q", name, path, legacy)
			}
		}
	}
}
