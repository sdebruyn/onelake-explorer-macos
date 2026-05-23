package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/BurntSushi/toml"
)

func TestDefault(t *testing.T) {
	d := Default()
	if !d.Telemetry {
		t.Error("telemetry should default to true (opt-out)")
	}
	if d.Net.MaxConcurrencyPerAccount != 4 {
		t.Errorf("MaxConcurrencyPerAccount = %d, want 4", d.Net.MaxConcurrencyPerAccount)
	}
	if d.Cache.MaxSizeBytes != 10*1024*1024*1024 {
		t.Errorf("Cache.MaxSizeBytes = %d, want 10 GiB", d.Cache.MaxSizeBytes)
	}
	if d.Log.Level != "info" {
		t.Errorf("Log.Level = %q, want %q", d.Log.Level, "info")
	}
	if d.Accounts == nil {
		t.Error("Accounts map must be non-nil")
	}
}

func TestStoreRoundtrip(t *testing.T) {
	dir := t.TempDir()
	paths := Paths{
		ConfigDir:  dir,
		ConfigFile: filepath.Join(dir, "config.toml"),
	}

	s := &Store{paths: paths, file: Default()}
	s.Update(func(f *File) {
		f.InstallID = "abc-123"
		f.DefaultAccount = "work"
		f.Accounts["work"] = Account{
			Alias:         "work",
			TenantID:      "tenant-guid",
			HomeAccountID: "user.tenant",
			Username:      "user@example.com",
			AddedAt:       "2026-05-23T12:00:00Z",
		}
	})

	if err := s.Save(); err != nil {
		t.Fatalf("save: %v", err)
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

func TestResolvePathsContainsBundleID(t *testing.T) {
	p, err := ResolvePaths()
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	for name, path := range map[string]string{
		"ConfigDir":  p.ConfigDir,
		"CacheDir":   p.CacheDir,
		"LogDir":     p.LogDir,
		"SocketPath": p.SocketPath,
		"ConfigFile": p.ConfigFile,
	} {
		if !filepathContains(path, BundleID) {
			t.Errorf("%s = %q does not contain %q", name, path, BundleID)
		}
	}
}

func filepathContains(p, needle string) bool {
	for _, seg := range filepath.SplitList(p + ":") {
		_ = seg
	}
	return stringContains(p, needle)
}

func stringContains(s, substr string) bool {
	return len(substr) == 0 || (len(s) >= len(substr) && indexOf(s, substr) >= 0)
}

func indexOf(s, substr string) int {
	for i := 0; i+len(substr) <= len(s); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}
