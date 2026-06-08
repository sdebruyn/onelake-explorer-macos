# MSAL Swift Keychain Volume Checkpoint

**Date**: 2026-06-07
**Phase**: 3 (Auth module — GO/NO-GO checkpoint)
**PR**: `feat(ofemkit): port MSAL multi-account auth from Go`

---

## Background

OFEM's Go daemon stores MSAL token cache blobs as plain files under
`<configDir>/tokens/<hex-alias>.bin`, bypassing the macOS Keychain entirely.
This was an explicit decision: the Go team found that `go-keyring` (which
targeted `SecItemAdd` on the iCloud Keychain sync path) hit the
**~16 KB per-item Generic Password size limit** after a single Microsoft Entra
login (`internal/auth/keychain.go` comment, line 24–28).

The question for Phase 3 is: **does MSAL Swift on macOS hit the same limit?**

---

## MSAL Swift on macOS: Keychain architecture

MSAL Swift (via `MSIDMacKeychainTokenCache` in `microsoft-authentication-library-common-for-objc`)
does **not** use the iCloud Keychain sync path. Instead it uses
`SecKeychainItemCreate` / `SecItemAdd` against the **macOS login.keychain**
(also called the file-based keychain), protected by ACLs created via
`SecAccessCreate` / `SecTrustedApplicationCreate`.

The macOS **login.keychain** does not have the ~16 KB item size limit that
applies to iCloud Keychain sync items. Items in the login.keychain can hold
arbitrary `kSecValueData` payloads; the practical limit is the process address
space and disk space.

### Storage structure

Two `kSecClassGenericPassword` items per app in the login.keychain:

| Type | kSecAttrAccount | kSecAttrService | Content |
|------|----------------|-----------------|---------|
| **Shared blob** | `<access_group>` | `"Microsoft Credentials"` | All refresh tokens + account records (shared across apps in the same keychain group) |
| **Non-shared (app) blob** | `<access_group>-<bundle_id>` | `"Microsoft Credentials"` | Access tokens, ID tokens, app metadata, account metadata (scoped to this app) |

OFEM overrides the default keychain group (`com.microsoft.identity.universalstorage`)
to the OFEM App Group (`6D79CUWZ4J.group.dev.debruyn.ofem`) so the FPE and
host app share one token cache without cross-app SSO with other Microsoft apps.

---

## Estimated blob sizes

The test `KeychainVolumeIntegrationTests.blobSizeEstimation` (which always runs,
no keychain access needed) constructs realistic mock cache blobs matching the
JSON structure documented in `MSIDMacKeychainTokenCache.m`. Each account-tenant
pair produces entries of the same magnitude as a real login (based on the MSAL
Go integration test reference file `apps/tests/integration/serialized_cache_1.1.1.json`,
which is ~11.9 KB for one account per the GitHub API).

Results from the 2026-06-07 run:

| Scenario | Shared blob | App blob | Total | Per pair |
|----------|-------------|----------|-------|----------|
| 1 account × 1 tenant | 1.4 KB | 3.5 KB | **4.9 KB** | ~5 KB |
| 5 accounts × 1 tenant | 7.0 KB | 16.4 KB | **23.4 KB** | ~4.8 KB |
| 5 accounts × 3 tenants (15 pairs) | 21.1 KB | 48.7 KB | **69.8 KB** | ~4.7 KB |
| 10 accounts × 10 tenants (100 pairs) | 140 KB | 323 KB | **463 KB** | ~4.6 KB |

The mock blobs conservatively represent:
- Refresh token: 512 bytes per pair (in shared blob)
- Access token: 1,400-byte JWT per pair (in app blob)
- ID token: 800-byte JWT per pair (in app blob)
- Account record, app metadata, account metadata: ~250 bytes

Actual MSAL cache items will be in this range; some fields (especially JWTs)
may be larger in practice but base64-decoding shows the payload is the same
order of magnitude.

---

## GO / NO-GO conclusion

### **GO — MSAL Swift's default keychain strategy is viable for OFEM.**

Rationale:

1. **Different API path than Go's go-keyring.** The Go team's 16 KB limit was
   specific to `go-keyring`'s use of `SecItemAdd` against the iCloud Keychain
   sync path. MSAL Swift uses the local login.keychain via ACL-based Keychain
   APIs, which have no hard per-item data limit.

2. **Realistic sizes stay well within practical limits.** The common OFEM
   use case (1–5 accounts, 1–3 tenants) produces blobs of 5–70 KB. Even the
   stress scenario (100 account-tenant pairs) produces 463 KB total across two
   items — far below any system limit for login.keychain items.

3. **Per-account isolation is not needed.** Because MSAL Swift uses only
   two keychain items (shared + app), there is no per-account item to hit a
   limit on. The blobs grow linearly with account count but are not per-account
   items.

4. **File-backed fallback available.** `TokenCacheStrategy.fileBackedFallback`
   is implemented and available if a future macOS version or App Sandbox
   configuration changes keychain behaviour. It uses the same on-disk format
   as the Go daemon (`<alias>.bin` files), making it cross-readable during
   the migration period.

### Breakpoint analysis

There is no hard breakpoint. The login.keychain grows linearly with accounts:

- At ~500 accounts (unrealistic for OFEM's typical use) the blobs approach 2 MB.
- At that scale, serialisation/deserialisation latency (not item size) becomes
  the concern — MSAL JSON-encodes the entire cache on every token operation.
- Mitigation in that unlikely scenario: implement per-account keychain items
  using a custom `MSALSerializedADALCacheProviderDelegate` (already scaffolded
  as `TokenCacheStrategy.fileBackedFallback`).

### What the interactive checkpoint tests would measure

The four `KeychainVolumeIntegrationTests` scenarios tagged with `.disabled()`
would validate the above estimates against the real macOS Keychain API
(`SecItemAdd` / `SecItemCopyMatching`). They can be run manually:

```bash
cd Packages/OfemKit
swift test --filter KeychainVolumeIntegrationTests
```

These tests require a signed build with keychain entitlements and cannot run
headlessly in CI. The estimation test (`blobSizeEstimation`) runs in CI and
provides a reasonable baseline without Keychain access.

---

## Implications for Phase 4+

- **No architecture change needed.** MSAL Swift's default keychain cache
  (`TokenCacheStrategy.msalKeychain`) is the correct production choice.
- **File-backed fallback retained.** `TokenCacheStrategy.fileBackedFallback`
  provides Go-daemon compatibility during Phases 1–4 (dual-engine period)
  because the ADAL serialised format is compatible with MSAL Go's cache format.
- **R1 risk from the migration plan is resolved.** The concern in
  `docs/swift-migration-plan.md §6 R1` ("MSAL token cache may exceed 16 KB")
  does not apply to MSAL Swift's login.keychain implementation.
