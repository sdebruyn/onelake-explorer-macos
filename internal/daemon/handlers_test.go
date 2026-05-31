package daemon

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/httpgate"
)

// newTestHandlers wires a Handlers instance over an in-memory keychain
// and a fresh on-disk cache rooted in t.TempDir(). It points HOME at the
// temp dir so config.Load reads and writes into a sandboxed location and
// the test never touches the user's real ~/Library. The engine is left
// nil; tests that need a refresher set h.engine themselves.
func newTestHandlers(t *testing.T) *Handlers {
	t.Helper()

	dir := t.TempDir()
	t.Setenv("HOME", dir)

	store, err := config.Load()
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	if err := store.UpdateAndSave(func(_ *config.File) {}); err != nil {
		t.Fatalf("config.UpdateAndSave: %v", err)
	}

	kc := auth.NewMemoryKeychain()
	reg := auth.NewRegistry(store, kc, auth.EntraClientID, nil)

	cacheRoot := filepath.Join(dir, "cache")
	c, err := cache.Open(cache.Options{Root: cacheRoot, MaxBlobBytes: 1024})
	if err != nil {
		t.Fatalf("cache.Open: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })

	return NewHandlers(store, reg, kc, c, nil, nil, nil)
}

// seedAccount persists an account directly via the registry so tests that
// need a populated config (account.list, config.snapshot, account.setDefault)
// don't depend on an IPC-level handler to do the wiring.
func seedAccount(t *testing.T, h *Handlers, alias, homeAccountID, username, tenantID, tenantName string) {
	t.Helper()
	if err := h.registry.Add(auth.Account{
		Alias:         alias,
		HomeAccountID: homeAccountID,
		Username:      username,
		TenantID:      tenantID,
		TenantName:    tenantName,
		AddedAt:       time.Now().UTC(),
	}, []byte("opaque-msal-cache")); err != nil {
		t.Fatalf("seedAccount(%q): %v", alias, err)
	}
}

func TestHandleStatus(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp, ok := got.(StatusResponse)
	if !ok {
		t.Fatalf("type: got %T", got)
	}
	if resp.StartedAt.IsZero() {
		t.Errorf("StartedAt should be set")
	}
	if resp.CacheMaxBytes <= 0 {
		// We seeded MaxBlobBytes=1024 in the cache but the config's
		// MaxSizeGB default is 10 GB → handlers must return the
		// converted byte value (10 * 1<<30); ensure non-zero is returned.
		t.Errorf("CacheMaxBytes should be > 0, got %d", resp.CacheMaxBytes)
	}
	if want := int64(config.DefaultCacheSizeGB) * 1024 * 1024 * 1024; resp.CacheMaxBytes != want {
		t.Errorf("CacheMaxBytes = %d, want %d (GB→bytes conversion at the daemon seam)", resp.CacheMaxBytes, want)
	}
	if resp.CacheBytes < 0 {
		t.Errorf("CacheBytes should be measured (>=0), got %d", resp.CacheBytes)
	}
}

// TestHandleStatusIncludesGates verifies the IPC status payload carries
// the per-host gate snapshots when the daemon is wired with a registry.
func TestHandleStatusIncludesGates(t *testing.T) {
	h := newTestHandlers(t)
	h.gates = httpgate.DefaultRegistry()

	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp := got.(StatusResponse)
	if len(resp.Gates) != 2 {
		t.Fatalf("Gates = %d entries, want 2", len(resp.Gates))
	}
	hosts := map[string]bool{}
	for _, g := range resp.Gates {
		hosts[g.Host] = true
	}
	for _, want := range []string{httpgate.HostFabric, httpgate.HostOneLake} {
		if !hosts[want] {
			t.Errorf("missing host %q in gates output", want)
		}
	}
}

// TestHandleStatusEmptyGatesWhenUnwired confirms the no-registry path
// returns an empty Gates list (not nil-vs-empty panic, etc).
func TestHandleStatusEmptyGatesWhenUnwired(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp := got.(StatusResponse)
	if len(resp.Gates) != 0 {
		t.Errorf("Gates = %d, want 0 (no registry wired)", len(resp.Gates))
	}
}

func TestHandleAccountListEmpty(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleAccountList: %v", err)
	}
	resp, ok := got.(AccountListResponse)
	if !ok {
		t.Fatalf("type: got %T", got)
	}
	if len(resp.Accounts) != 0 {
		t.Errorf("expected zero accounts, got %d", len(resp.Accounts))
	}
}

func TestHandleAccountListReturnsSeededAccount(t *testing.T) {
	h := newTestHandlers(t)
	seedAccount(t, h, "work", "oid.tid", "sam@contoso.com",
		"11111111-1111-1111-1111-111111111111", "Contoso")

	listed, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	lr := listed.(AccountListResponse)
	if len(lr.Accounts) != 1 || lr.Accounts[0].Alias != "work" {
		t.Fatalf("unexpected list: %+v", lr)
	}
	if lr.Accounts[0].Username != "sam@contoso.com" {
		t.Errorf("username not propagated: %+v", lr.Accounts[0])
	}
}

func TestHandleAccountRemove(t *testing.T) {
	h := newTestHandlers(t)
	seedAccount(t, h, "work", "h", "u", "t", "")
	if _, err := h.handleAccountRemove(context.Background(), mustJSON(t, AccountRemoveRequest{Alias: "work"})); err != nil {
		t.Fatalf("remove: %v", err)
	}
	res, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got := res.(AccountListResponse).Accounts; len(got) != 0 {
		t.Errorf("expected empty after remove, got %+v", got)
	}
}

func TestHandleAccountRemoveMissingAliasErrors(t *testing.T) {
	h := newTestHandlers(t)
	_, err := h.handleAccountRemove(context.Background(), mustJSON(t, AccountRemoveRequest{}))
	if err == nil {
		t.Fatalf("expected error for empty alias")
	}
}

func TestHandleConfigSnapshotOmitsInstallID(t *testing.T) {
	h := newTestHandlers(t)
	// Set an install ID via the store so we know it's set.
	if err := h.store.UpdateAndSave(func(f *config.File) { f.InstallID = "should-not-appear" }); err != nil {
		t.Fatalf("UpdateAndSave: %v", err)
	}
	res, err := h.handleConfigSnapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	out, _ := json.Marshal(res)
	if got := string(out); strings.Contains(got, "should-not-appear") || strings.Contains(got, "install_id") {
		t.Errorf("config.snapshot leaked InstallID: %s", got)
	}
}

// TestHandleConfigSnapshotScrubsUPN verifies that config.snapshot does not
// expose HomeAccountID (AAD objectId) or Username (UPN) in its Accounts map.
// Both fields are present in config.Account but must be stripped before the
// response reaches any IPC client, consistent with docs/telemetry.md.
func TestHandleConfigSnapshotScrubsUPN(t *testing.T) {
	h := newTestHandlers(t)
	// Seed an account that carries a UPN and HomeAccountID.
	seedAccount(t, h, "work", "secret-oid.tid", "secret@contoso.com",
		"11111111-1111-1111-1111-111111111111", "")
	res, err := h.handleConfigSnapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	out, _ := json.Marshal(res)
	got := string(out)
	if strings.Contains(got, "secret-oid.tid") {
		t.Errorf("config.snapshot leaked HomeAccountID: %s", got)
	}
	if strings.Contains(got, "secret@contoso.com") {
		t.Errorf("config.snapshot leaked UPN (Username): %s", got)
	}
}

// TestHandleConfigSnapshotScrubsMultipleAccounts verifies that config.snapshot
// scrubs HomeAccountID and Username for every account in the response, not
// just the first one.
func TestHandleConfigSnapshotScrubsMultipleAccounts(t *testing.T) {
	h := newTestHandlers(t)
	seedAccount(t, h, "work", "secret-oid-work.tid", "secret-work@contoso.com",
		"11111111-1111-1111-1111-111111111111", "")
	seedAccount(t, h, "personal", "secret-oid-personal.tid", "secret-personal@fabrikam.com",
		"22222222-2222-2222-2222-222222222222", "")

	res, err := h.handleConfigSnapshot(context.Background(), nil)
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	out, _ := json.Marshal(res)
	got := string(out)
	for _, secret := range []string{
		"secret-oid-work.tid",
		"secret-work@contoso.com",
		"secret-oid-personal.tid",
		"secret-personal@fabrikam.com",
	} {
		if strings.Contains(got, secret) {
			t.Errorf("config.snapshot leaked sensitive value %q: %s", secret, got)
		}
	}
}

func TestHandleSyncPollChangesNilFeedReturnsEmpty(t *testing.T) {
	h := newTestHandlers(t)
	// feed is nil in newTestHandlers; handler must return an empty, non-nil
	// event list and a non-zero anchor.
	res, err := h.handleSyncPollChanges(context.Background(), nil)
	if err != nil {
		t.Fatalf("sync.pollChanges: %v", err)
	}
	r, ok := res.(PollChangesResult)
	if !ok {
		t.Fatalf("type: got %T", res)
	}
	if r.Events == nil {
		t.Errorf("Events should be non-nil empty slice for stable JSON, got nil")
	}
	if len(r.Events) != 0 {
		t.Errorf("expected 0 events with nil feed, got %d", len(r.Events))
	}
	if r.Anchor.IsZero() {
		t.Errorf("Anchor should be non-zero even with nil feed")
	}
}

func TestHandleSyncPollChangesReturnsFeedEvents(t *testing.T) {
	h := newTestHandlers(t)
	h.feed = NewChangefeed()

	base := time.Now().UTC()
	h.feed.Publish("ofem.work", "work/.rootContainer", base.Add(time.Second))
	h.feed.Publish("ofem.work", "work/ws-1/item-A", base.Add(2*time.Second))

	params, _ := json.Marshal(PollChangesRequest{Anchor: base})
	res, err := h.handleSyncPollChanges(context.Background(), params)
	if err != nil {
		t.Fatalf("sync.pollChanges: %v", err)
	}
	r := res.(PollChangesResult)
	if len(r.Events) != 2 {
		t.Errorf("events = %d, want 2", len(r.Events))
	}
	if r.FullResync {
		t.Errorf("FullResync should be false on first poll")
	}

	// Second poll at the returned anchor should yield no events.
	params2, _ := json.Marshal(PollChangesRequest{Anchor: r.Anchor})
	res2, err := h.handleSyncPollChanges(context.Background(), params2)
	if err != nil {
		t.Fatalf("sync.pollChanges (second): %v", err)
	}
	r2 := res2.(PollChangesResult)
	if len(r2.Events) != 0 {
		t.Errorf("second poll events = %d, want 0", len(r2.Events))
	}
}

// TestChangeEventJSONShape verifies the exact JSON field names that the Swift
// DaemonClient decodes. Any rename of a Go field without a matching JSON tag
// update will be caught here before it silently breaks the cross-language
// contract.
func TestChangeEventJSONShape(t *testing.T) {
	ts, _ := time.Parse(time.RFC3339, "2025-06-01T12:00:00Z")
	ev := ChangeEvent{
		Domain:      "ofem.work",
		ContainerID: "work/.rootContainer",
		OccurredAt:  ts,
	}
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal ChangeEvent: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, key := range []string{"domain", "containerId", "occurredAt"} {
		if _, ok := m[key]; !ok {
			t.Errorf("ChangeEvent JSON missing key %q; got %v", key, m)
		}
	}
	for _, badKey := range []string{"Domain", "ContainerID", "OccurredAt"} {
		if _, ok := m[badKey]; ok {
			t.Errorf("ChangeEvent JSON has Pascal-case key %q; want camelCase", badKey)
		}
	}
}

// TestPollChangesResultJSONShape verifies the response-envelope field names
// match what Swift's PollChangesResponse CodingKeys expect: events, anchor,
// fullResync.
func TestPollChangesResultJSONShape(t *testing.T) {
	ts, _ := time.Parse(time.RFC3339, "2025-06-01T12:00:00Z")
	res := PollChangesResult{
		Events: []ChangeEvent{
			{Domain: "ofem.work", ContainerID: "work/.rootContainer", OccurredAt: ts},
		},
		Anchor:     ts,
		FullResync: true,
	}
	b, err := json.Marshal(res)
	if err != nil {
		t.Fatalf("marshal PollChangesResult: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	for _, key := range []string{"events", "anchor", "fullResync"} {
		if _, ok := m[key]; !ok {
			t.Errorf("PollChangesResult JSON missing key %q; got %v", key, m)
		}
	}
	events, ok := m["events"].([]any)
	if !ok || len(events) != 1 {
		t.Fatalf("events field malformed: %v", m["events"])
	}
	ev0 := events[0].(map[string]any)
	for _, key := range []string{"domain", "containerId", "occurredAt"} {
		if _, ok := ev0[key]; !ok {
			t.Errorf("nested ChangeEvent JSON missing key %q; got %v", key, ev0)
		}
	}
}

// TestHandleSyncPollChangesMalformedSinceErrors verifies that passing a
// malformed since/anchor value returns a JSON-RPC-level error rather than
// panicking or returning a zero-value result.
func TestHandleSyncPollChangesMalformedSinceErrors(t *testing.T) {
	h := newTestHandlers(t)
	h.feed = NewChangefeed()

	// Provide a params object whose "anchor" value is not a valid timestamp.
	badParams := json.RawMessage(`{"anchor":"not-a-timestamp"}`)
	_, err := h.handleSyncPollChanges(context.Background(), badParams)
	if err == nil {
		t.Fatal("expected error for malformed anchor, got nil")
	}
}

// TestHandleAccountSetDefault verifies that account.setDefault persists the
// alias and that a subsequent account.list reflects it.
func TestHandleAccountSetDefault(t *testing.T) {
	h := newTestHandlers(t)
	// Seed two accounts first.
	seedAccount(t, h, "work", "h", "u", "t", "")
	seedAccount(t, h, "personal", "h", "u", "t", "")

	res, err := h.handleAccountSetDefault(context.Background(), mustJSON(t, AccountSetDefaultRequest{Alias: "work"}))
	if err != nil {
		t.Fatalf("setDefault: %v", err)
	}
	r, ok := res.(AccountSetDefaultResponse)
	if !ok || r.DefaultAccount != "work" {
		t.Fatalf("response: %+v", res)
	}

	listed, err := h.handleAccountList(context.Background(), nil)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if lr := listed.(AccountListResponse); lr.DefaultAccount != "work" {
		t.Errorf("DefaultAccount = %q, want %q", lr.DefaultAccount, "work")
	}
}

// TestHandleAccountSetDefaultUnknownErrors verifies that setting the default
// to an alias that does not exist returns an error.
func TestHandleAccountSetDefaultUnknownErrors(t *testing.T) {
	h := newTestHandlers(t)
	_, err := h.handleAccountSetDefault(context.Background(), mustJSON(t, AccountSetDefaultRequest{Alias: "ghost"}))
	if err == nil {
		t.Fatal("expected error for unknown alias")
	}
}

// TestHandleAccountSetDefaultEmptyAliasErrors verifies that an empty alias
// returns an error before touching the registry.
func TestHandleAccountSetDefaultEmptyAliasErrors(t *testing.T) {
	h := newTestHandlers(t)
	_, err := h.handleAccountSetDefault(context.Background(), mustJSON(t, AccountSetDefaultRequest{}))
	if err == nil {
		t.Fatal("expected error for empty alias")
	}
}

// TestHandleCacheEvictReturnsBytes verifies that cache.evict returns the
// post-eviction byte total (may be 0 on an empty cache).
func TestHandleCacheEvictReturnsBytes(t *testing.T) {
	h := newTestHandlers(t)
	res, err := h.handleCacheEvict(context.Background(), nil)
	if err != nil {
		t.Fatalf("cache.evict: %v", err)
	}
	r, ok := res.(CacheEvictResponse)
	if !ok {
		t.Fatalf("type: got %T", res)
	}
	if r.CacheBytes < 0 {
		t.Errorf("CacheBytes = %d, want >= 0", r.CacheBytes)
	}
}

// TestHandleCacheClearReturnZero verifies that cache.clear always returns 0
// as the post-clear byte total.
func TestHandleCacheClearReturnsZero(t *testing.T) {
	h := newTestHandlers(t)
	res, err := h.handleCacheClear(context.Background(), nil)
	if err != nil {
		t.Fatalf("cache.clear: %v", err)
	}
	r, ok := res.(CacheClearResponse)
	if !ok {
		t.Fatalf("type: got %T", res)
	}
	if r.CacheBytes != 0 {
		t.Errorf("CacheBytes = %d, want 0", r.CacheBytes)
	}
}

// TestHandleConfigSetTelemetry verifies that config.set can toggle
// telemetry and that the normalised key+value are echoed back.
func TestHandleConfigSetTelemetry(t *testing.T) {
	h := newTestHandlers(t)

	res, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "telemetry", Value: "off"}))
	if err != nil {
		t.Fatalf("config.set telemetry=off: %v", err)
	}
	r, ok := res.(ConfigSetResponse)
	if !ok {
		t.Fatalf("type: got %T", res)
	}
	if r.Key != "telemetry" {
		t.Errorf("key = %q, want %q", r.Key, "telemetry")
	}
	if h.store.Snapshot().Telemetry {
		t.Errorf("telemetry should be false after config.set telemetry=off")
	}
}

// TestHandleConfigSetCacheMaxSizeGB verifies that the canonical GB key
// the menubar Stepper writes is accepted and resolves to the right
// backing field and byte conversion.
func TestHandleConfigSetCacheMaxSizeGB(t *testing.T) {
	h := newTestHandlers(t)
	res, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "cache.max_size_gb", Value: "25"}))
	if err != nil {
		t.Fatalf("config.set cache.max_size_gb=25: %v", err)
	}
	if _, ok := res.(ConfigSetResponse); !ok {
		t.Fatalf("type: got %T", res)
	}
	snap := h.store.Snapshot()
	if got := snap.Cache.MaxSizeGB; got != 25 {
		t.Errorf("MaxSizeGB = %d, want 25", got)
	}
	if got := snap.Cache.MaxBytes(); got != 25*(1<<30) {
		t.Errorf("MaxBytes() = %d, want %d (GB→bytes conversion)", got, int64(25)*(1<<30))
	}
}

// TestHandleConfigSetCacheMaxSizeGBRejectsOutOfRange confirms the
// daemon refuses Stepper writes outside the [MinCacheSizeGB,
// MaxCacheSizeGB] bounds even if a buggy client manages to send them.
func TestHandleConfigSetCacheMaxSizeGBRejectsOutOfRange(t *testing.T) {
	h := newTestHandlers(t)
	for _, bad := range []string{"0", "-1", "9999"} {
		_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "cache.max_size_gb", Value: bad}))
		if err == nil {
			t.Errorf("config.set cache.max_size_gb=%s expected error", bad)
		}
	}
}

// TestHandleConfigSetUnknownKeyErrors verifies that an unknown key returns
// an error without mutating the config.
func TestHandleConfigSetUnknownKeyErrors(t *testing.T) {
	h := newTestHandlers(t)
	_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "does.not.exist", Value: "x"}))
	if err == nil {
		t.Fatal("expected error for unknown key")
	}
}

// TestHandleConfigSetKeyNormalization verifies that dash-separated key
// variants are accepted (e.g. "cache.max-size-gb" == "cache.max_size_gb").
func TestHandleConfigSetKeyNormalization(t *testing.T) {
	h := newTestHandlers(t)
	_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "cache.max-size-gb", Value: "7"}))
	if err != nil {
		t.Fatalf("config.set cache.max-size-gb: %v", err)
	}
	if got := h.store.Snapshot().Cache.MaxSizeGB; got != 7 {
		t.Errorf("MaxSizeGB = %d, want 7", got)
	}
}

// TestHandleConfigSetNetConcurrency verifies the Settings → Network
// tab's two Steppers can write valid in-range values for both
// concurrency knobs and they round-trip into the right config fields.
func TestHandleConfigSetNetConcurrency(t *testing.T) {
	h := newTestHandlers(t)
	cases := []struct {
		key     string
		value   string
		check   func(snap config.File) int
		wantInt int
	}{
		{"net.max_concurrent_uploads_per_account", "6",
			func(f config.File) int { return f.Net.MaxConcurrentUploadsPerAccount }, 6},
		{"net.max_concurrent_downloads_per_account", "20",
			func(f config.File) int { return f.Net.MaxConcurrentDownloadsPerAccount }, 20},
	}
	for _, c := range cases {
		_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: c.key, Value: c.value}))
		if err != nil {
			t.Fatalf("config.set %s=%s: %v", c.key, c.value, err)
		}
		if got := c.check(h.store.Snapshot()); got != c.wantInt {
			t.Errorf("after %s=%s field = %d, want %d", c.key, c.value, got, c.wantInt)
		}
	}
}

// TestHandleConfigSetNetConcurrencyRejectsOutOfRange confirms the daemon
// refuses values outside the documented bounds for both net.* keys, so
// a buggy Settings build that broadens the Stepper range cannot ship an
// invalid value.
func TestHandleConfigSetNetConcurrencyRejectsOutOfRange(t *testing.T) {
	h := newTestHandlers(t)
	cases := []struct {
		key    string
		values []string
	}{
		// uploads bound [1, 16]
		{"net.max_concurrent_uploads_per_account", []string{"0", "-1", "17", "9999"}},
		// downloads bound [1, 32]
		{"net.max_concurrent_downloads_per_account", []string{"0", "-1", "33", "9999"}},
	}
	for _, c := range cases {
		for _, bad := range c.values {
			_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: c.key, Value: bad}))
			if err == nil {
				t.Errorf("config.set %s=%s expected error", c.key, bad)
			}
		}
	}
}

// TestHandleConfigSetLogLevel verifies the Settings → Advanced tab's
// log level Picker can persist each of the four accepted levels and
// rejects garbage.
func TestHandleConfigSetLogLevel(t *testing.T) {
	h := newTestHandlers(t)
	for _, level := range []string{"debug", "info", "warn", "error"} {
		_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "log.level", Value: level}))
		if err != nil {
			t.Fatalf("config.set log.level=%s: %v", level, err)
		}
		if got := h.store.Snapshot().Log.Level; got != level {
			t.Errorf("Log.Level = %q, want %q", got, level)
		}
	}
	for _, bad := range []string{"", "verbose", "trace", "DEBUG-x"} {
		_, err := h.handleConfigSet(context.Background(), mustJSON(t, ConfigSetRequest{Key: "log.level", Value: bad}))
		if err == nil {
			t.Errorf("config.set log.level=%q expected error", bad)
		}
	}
}

// TestHandleStatusIncludesPaths verifies the status response carries
// the config file, cache directory, and log directory paths.
func TestHandleStatusIncludesPaths(t *testing.T) {
	h := newTestHandlers(t)
	got, err := h.handleStatus(context.Background(), nil)
	if err != nil {
		t.Fatalf("handleStatus: %v", err)
	}
	resp := got.(StatusResponse)
	if resp.Paths.ConfigFile == "" {
		t.Error("Paths.ConfigFile should be set")
	}
	if resp.Paths.CacheDir == "" {
		t.Error("Paths.CacheDir should be set")
	}
	if resp.Paths.LogDir == "" {
		t.Error("Paths.LogDir should be set")
	}
}

// TestHandleAuthLoginNilKeychainErrors verifies that auth.login returns a
// descriptive error when the handler was constructed without a keychain
// (i.e. in a test that did not wire a full engine).
func TestHandleAuthLoginNilKeychainErrors(t *testing.T) {
	h := newTestHandlers(t)
	h.kc = nil // simulate a daemon built without a keychain
	_, err := h.handleAuthLogin(context.Background(), mustJSON(t, AuthLoginRequest{Alias: "work"}))
	if err == nil {
		t.Fatal("expected error when kc is nil")
	}
}

// TestHandleAuthLoginInvalidAliasErrors verifies that auth.login validates
// the alias before attempting any network I/O.
func TestHandleAuthLoginInvalidAliasErrors(t *testing.T) {
	h := newTestHandlers(t)
	cases := []string{
		"",          // empty
		"-leading",  // starts with dash
		".leading",  // starts with dot
		"has space", // disallowed character
		"has/slash", // disallowed character
	}
	for _, alias := range cases {
		_, err := h.handleAuthLogin(context.Background(), mustJSON(t, AuthLoginRequest{Alias: alias}))
		if err == nil {
			t.Errorf("alias=%q: expected error, got nil", alias)
		}
	}
}

// TestHandleAuthLoginCancelledContextErrors verifies that a cancelled context
// causes auth.login to return promptly with an error rather than hanging.
// This exercises the ctx-forwarding path through LoginInteractive.
func TestHandleAuthLoginCancelledContextErrors(t *testing.T) {
	h := newTestHandlers(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancelled before the call

	done := make(chan error, 1)
	go func() {
		_, err := h.handleAuthLogin(ctx, mustJSON(t, AuthLoginRequest{Alias: "work"}))
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Error("expected error for cancelled context, got nil")
		}
	case <-time.After(15 * time.Second):
		t.Fatal("auth.login did not return within 15s after ctx cancel")
	}
}

func mustJSON(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
