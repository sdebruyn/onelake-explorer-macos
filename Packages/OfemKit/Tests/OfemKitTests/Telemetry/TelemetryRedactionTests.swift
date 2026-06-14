import Testing
@testable import OfemKit

/// Tests for the structural privacy boundary in `TelemetryRedaction`.
@Suite("TelemetryRedaction")
struct TelemetryRedactionTests {
    // MARK: - hashAlias

    @Test("hashAlias is stable for the same input")
    func hashAliasStable() {
        let a = TelemetryRedaction.hashAlias("work")
        let b = TelemetryRedaction.hashAlias("work")
        #expect(!a.isEmpty)
        #expect(a == b)
    }

    @Test("hashAlias produces 8-hex-character output")
    func hashAliasLength() {
        let h = TelemetryRedaction.hashAlias("work")
        #expect(h.count == 8, "expected 8 chars, got \(h.count)")
        #expect(h.allSatisfy { $0.isHexDigit }, "expected hex chars, got: \(h)")
    }

    @Test("hashAlias distinguishes different inputs")
    func hashAliasDifferentInputs() {
        #expect(TelemetryRedaction.hashAlias("work") != TelemetryRedaction.hashAlias("home"))
    }

    @Test("hashAlias maps empty string to empty string")
    func hashAliasEmpty() {
        #expect(TelemetryRedaction.hashAlias("") == "")
    }

    // MARK: - safeErrorCode

    @Test("safeErrorCode passes clean codes unchanged")
    func safeErrorCodeClean() {
        #expect(TelemetryRedaction.safeErrorCode("AADSTS50079") == "AADSTS50079")
        #expect(TelemetryRedaction.safeErrorCode("read_failed") == "read_failed")
        #expect(TelemetryRedaction.safeErrorCode("write_failed") == "write_failed")
        #expect(TelemetryRedaction.safeErrorCode("capacity_paused") == "capacity_paused")
    }

    @Test("safeErrorCode passes empty string unchanged")
    func safeErrorCodeEmpty() {
        #expect(TelemetryRedaction.safeErrorCode("") == "")
    }

    @Test("safeErrorCode rejects strings longer than 32 characters")
    func safeErrorCodeTooLong() {
        let long = String(repeating: "X", count: 33)
        #expect(TelemetryRedaction.safeErrorCode(long) == "redacted")
    }

    @Test("safeErrorCode passes exactly 32 characters")
    func safeErrorCodeMaxLen() {
        let exactly32 = "abcdefghijabcdefghijabcdefghij12"
        #expect(exactly32.count == 32)
        #expect(TelemetryRedaction.safeErrorCode(exactly32) == exactly32)
    }

    @Test("safeErrorCode rejects UPN-like strings with @")
    func safeErrorCodeUPN() {
        #expect(TelemetryRedaction.safeErrorCode("user@example.com") == "redacted")
    }

    @Test("safeErrorCode rejects path-like strings with /")
    func safeErrorCodePath() {
        #expect(TelemetryRedaction.safeErrorCode("Sales/budget_2026.csv") == "redacted")
    }

    @Test("safeErrorCode rejects NSError domain containing a path segment (PII-domain pin)")
    func safeErrorCodePIIDomainPin() {
        // A custom NSError whose domain embeds a path segment or UPN —
        // e.g. "dev.debruyn.ofem/auth failed for sam@x.y" — must not pass
        // through safeErrorCode verbatim.  The slash makes it unsafe; the
        // result must be "redacted", not the raw domain:code string.
        let domain = "dev.debruyn.ofem/auth failed for sam@x.y"
        let composed = "\(domain):-1"
        #expect(
            TelemetryRedaction.safeErrorCode(composed) == "redacted",
            "domain containing '/' must be redacted, got: \(TelemetryRedaction.safeErrorCode(composed))"
        )
    }

    @Test("safeErrorCode rejects backslash")
    func safeErrorCodeBackslash() {
        #expect(TelemetryRedaction.safeErrorCode("a\\b") == "redacted")
    }

    @Test("safeErrorCode rejects whitespace")
    func safeErrorCodeSpace() {
        #expect(TelemetryRedaction.safeErrorCode("server busy") == "redacted")
    }

    @Test("safeErrorCode rejects unicode")
    func safeErrorCodeUnicode() {
        #expect(TelemetryRedaction.safeErrorCode("café") == "redacted")
    }

    @Test("safeErrorCode rejects control characters")
    func safeErrorCodeControlChars() {
        #expect(TelemetryRedaction.safeErrorCode("line1\nline2") == "redacted")
    }

    // MARK: - scrubProperty

    @Test("scrubProperty passes tenant GUID unchanged")
    func scrubPropertyTenantGuid() {
        let guid = "9064c167-4885-40ef-9f34-1853218aea86"
        #expect(TelemetryRedaction.scrubProperty(guid) == guid)
    }

    @Test("scrubProperty passes alias hash unchanged")
    func scrubPropertyAliasHash() {
        #expect(TelemetryRedaction.scrubProperty("a1b2c3d4") == "a1b2c3d4")
    }

    @Test("scrubProperty passes snake_case event names")
    func scrubPropertyEventName() {
        #expect(TelemetryRedaction.scrubProperty("folder_list") == "folder_list")
        #expect(TelemetryRedaction.scrubProperty("file_download") == "file_download")
    }

    @Test("scrubProperty passes CalVer strings")
    func scrubPropertyCalVer() {
        #expect(TelemetryRedaction.scrubProperty("2026.05.1") == "2026.05.1")
    }

    @Test("scrubProperty passes bool strings")
    func scrubPropertyBool() {
        #expect(TelemetryRedaction.scrubProperty("true") == "true")
        #expect(TelemetryRedaction.scrubProperty("false") == "false")
    }

    @Test("scrubProperty passes empty string unchanged")
    func scrubPropertyEmpty() {
        #expect(TelemetryRedaction.scrubProperty("") == "")
    }

    @Test("scrubProperty rejects file path with /")
    func scrubPropertyFilePath() {
        #expect(TelemetryRedaction.scrubProperty("Files/raw/sales-2026.csv") == "redacted")
    }

    @Test("scrubProperty rejects Windows path with backslash")
    func scrubPropertyWindowsPath() {
        #expect(TelemetryRedaction.scrubProperty("C:\\Users\\sam") == "redacted")
    }

    @Test("scrubProperty rejects UPN with @")
    func scrubPropertyUPN() {
        #expect(TelemetryRedaction.scrubProperty("sam@debruyn.dev") == "redacted")
    }

    @Test("scrubProperty rejects workspace name with space")
    func scrubPropertyWorkspaceName() {
        #expect(TelemetryRedaction.scrubProperty("My Workspace") == "redacted")
    }

    @Test("scrubProperty rejects non-ASCII")
    func scrubPropertyNonAscii() {
        #expect(TelemetryRedaction.scrubProperty("wörkspace") == "redacted")
    }

    @Test("scrubProperty rejects strings over 128 characters")
    func scrubPropertyOverMax() {
        let long = String(repeating: "a", count: 129)
        #expect(TelemetryRedaction.scrubProperty(long) == "redacted")
    }

    // MARK: - splitFields redaction boundary

    /// This is the structural privacy guarantee test — even if CommonProps
    /// somehow contains PII values, `splitFields` must not emit them verbatim.
    ///
    @Test("splitFields redacts leaked PII values in CommonProps")
    func splitFieldsRedactsPII() {
        let event = TelemetryEvent(
            name: "file_download",
            tenantID: "9064c167-4885-40ef-9f34-1853218aea86",
            accountAliasHash: "a1b2c3d4",
            errorCode: "Sales/budget_2026.csv",   // path — must be redacted
            commonProps: [
                "leakedPath":      "Files/raw/sales-2026.csv",
                "leakedUPN":       "sam@debruyn.dev",
                "leakedWorkspace": "My Workspace",
            ]
        )

        let (props, _) = splitFields(event)

        // Legitimate values pass through.
        #expect(props["tenantId"] == "9064c167-4885-40ef-9f34-1853218aea86")
        #expect(props["event"] == "file_download")
        #expect(props["accountAliasHash"] == "a1b2c3d4")

        // The error code contains a path separator — must be redacted.
        #expect(props["errorCode"] == "redacted",
                "errorCode with path separator must be redacted")

        // PII in CommonProps must be redacted (value-level scrub).
        for key in ["leakedPath", "leakedUPN", "leakedWorkspace"] {
            let v = props[key] ?? ""
            #expect(v == "redacted" || v.isEmpty,
                    "props[\(key)] = \(v) — must be redacted or absent")
        }
    }

    /// Verify that unknown CommonProp keys are dropped entirely, not just
    /// scrubbed. This is the key-level allowlist enforced by `splitFields`.
    ///
    @Test("splitFields drops unknown CommonProp keys (allowlist enforcement)")
    func splitFieldsDropsUnknownKeys() {
        let event = TelemetryEvent(
            name: "error",
            commonProps: [
                "failedOp":      "file_download",  // allowed
                "unknownKey":    "some-value",     // NOT in allowlist — must be absent
                "workspaceName": "SalesData",      // NOT in allowlist — must be absent
            ]
        )

        let (props, _) = splitFields(event)

        #expect(props["failedOp"] == "file_download", "known key must survive")
        #expect(props["unknownKey"] == nil,    "unknown key must be dropped")
        #expect(props["workspaceName"] == nil, "unknown key must be dropped")
    }

    // MARK: - Measurements

    @Test("splitFields maps numeric fields to measurements")
    func splitFieldsMeasurements() {
        let event = TelemetryEvent(
            name: "file_download",
            durationMs: 423,
            bytesTransferred: 1024,
            itemsChanged: 0
        )

        let (_, meas) = splitFields(event)
        #expect(meas["durationMs"] == 423.0)
        #expect(meas["bytesTransferred"] == 1024.0)
        #expect(meas["itemsChanged"] == nil, "zero itemsChanged must be absent")
    }

    @Test("splitFields maps success bool to string property")
    func splitFieldsSuccess() {
        let successTrue = TelemetryEvent(name: "op", success: true)
        let successFalse = TelemetryEvent(name: "op", success: false)
        let successNil = TelemetryEvent(name: "op")

        let (propsTrue, _) = splitFields(successTrue)
        let (propsFalse, _) = splitFields(successFalse)
        let (propsNil, _) = splitFields(successNil)

        #expect(propsTrue["success"] == "true")
        #expect(propsFalse["success"] == "false")
        #expect(propsNil["success"] == nil)
    }

    // MARK: - safeTenantID (telemetry-03 / telemetry-02)

    @Test("safeTenantID passes a valid lowercase GUID unchanged")
    func safeTenantIDValid() {
        let guid = "9064c167-4885-40ef-9f34-1853218aea86"
        #expect(TelemetryRedaction.safeTenantID(guid) == guid)
    }

    @Test("safeTenantID passes a valid uppercase GUID unchanged")
    func safeTenantIDUppercase() {
        // All-uppercase: charset check passes; GUID check passes.
        let guid = "9064C167-4885-40EF-9F34-1853218AEA86"
        #expect(TelemetryRedaction.safeTenantID(guid) == guid)
    }

    @Test("safeTenantID rejects a workspace name")
    func safeTenantIDWorkspaceName() {
        #expect(TelemetryRedaction.safeTenantID("My Workspace") == "redacted")
    }

    @Test("safeTenantID rejects a short hex string that is not a GUID")
    func safeTenantIDShortHex() {
        // 8-char hex alias hash — passes charset but fails GUID format.
        #expect(TelemetryRedaction.safeTenantID("a1b2c3d4") == "redacted")
    }

    @Test("safeTenantID rejects a string with wrong group lengths")
    func safeTenantIDWrongGroups() {
        // Length is 36 chars with dashes but wrong segment sizes.
        #expect(TelemetryRedaction.safeTenantID("9064c167-488-40ef9-f34-1853218aea86a") == "redacted")
    }

    @Test("safeTenantID maps empty string to empty string")
    func safeTenantIDEmpty() {
        #expect(TelemetryRedaction.safeTenantID("") == "")
    }

    @Test("safeTenantID rejects a UPN")
    func safeTenantIDUPN() {
        #expect(TelemetryRedaction.safeTenantID("sam@debruyn.dev") == "redacted")
    }

    @Test("splitFields uses safeTenantID — non-GUID tenant is redacted")
    func splitFieldsRejectsNonGUIDTenantID() {
        let event = TelemetryEvent(
            name: "workspace_list",
            tenantID: "My-Tenant-Name"   // not a GUID
        )
        let (props, _) = splitFields(event)
        #expect(props["tenantId"] == "redacted",
                "non-GUID tenantID must be redacted; got: \(props["tenantId"] ?? "nil")")
    }

    @Test("splitFields preserves a valid GUID tenant ID")
    func splitFieldsPreservesGUIDTenantID() {
        let guid = "9064c167-4885-40ef-9f34-1853218aea86"
        let event = TelemetryEvent(name: "workspace_list", tenantID: guid)
        let (props, _) = splitFields(event)
        #expect(props["tenantId"] == guid)
    }

    // MARK: - Privacy.isGUID (logging-01 / telemetry-03 shared helper)

    @Test("Privacy.isGUID accepts canonical 8-4-4-4-12 format")
    func privacyIsGUIDValid() {
        #expect(Privacy.isGUID("9064c167-4885-40ef-9f34-1853218aea86"))
        #expect(Privacy.isGUID("00000000-0000-0000-0000-000000000000"))
        #expect(Privacy.isGUID("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
    }

    @Test("Privacy.isGUID rejects strings that are too short or too long")
    func privacyIsGUIDWrongLength() {
        #expect(!Privacy.isGUID("9064c167-4885-40ef-9f34"))
        #expect(!Privacy.isGUID("9064c167-4885-40ef-9f34-1853218aea860000"))
    }

    @Test("Privacy.isGUID rejects strings without dashes in correct positions")
    func privacyIsGUIDNoDashes() {
        #expect(!Privacy.isGUID("9064c16748854085-9f34-1853218aea86"))
    }

    @Test("Privacy.isGUID rejects a non-hex character")
    func privacyIsGUIDNonHex() {
        // 'z' is not a hex digit.
        #expect(!Privacy.isGUID("9064c167-4885-40ef-9z34-1853218aea86"))
    }

    // MARK: - Privacy.scrubLogValue (logging-01 shared boundary)

    @Test("Privacy.scrubLogValue passes GUID unchanged")
    func privacyScrubLogValueGUID() {
        let guid = "9064c167-4885-40ef-9f34-1853218aea86"
        #expect(Privacy.scrubLogValue(guid) == guid)
    }

    @Test("Privacy.scrubLogValue redacts a file path")
    func privacyScrubLogValuePath() {
        #expect(Privacy.scrubLogValue("/Users/sam/Files/budget.csv") == "redacted")
    }

    @Test("Privacy.scrubLogValue redacts a UPN")
    func privacyScrubLogValueUPN() {
        #expect(Privacy.scrubLogValue("sam@debruyn.dev") == "redacted")
    }

    @Test("Privacy.scrubLogValue redacts a workspace name with space")
    func privacyScrubLogValueWorkspace() {
        #expect(Privacy.scrubLogValue("Sales Data") == "redacted")
    }

    @Test("Privacy.scrubLogValue passes empty string unchanged")
    func privacyScrubLogValueEmpty() {
        #expect(Privacy.scrubLogValue("") == "")
    }

    @Test("Privacy.scrubLogValue redacts values exceeding max length")
    func privacyScrubLogValueTooLong() {
        let long = String(repeating: "a", count: Privacy.maxMetaValueLen + 1)
        #expect(Privacy.scrubLogValue(long) == "redacted")
    }

    @Test("Privacy.scrubLogValue passes safe structured values unchanged")
    func privacyScrubLogValueSafe() {
        #expect(Privacy.scrubLogValue("file_download") == "file_download")
        #expect(Privacy.scrubLogValue("2026.05.1") == "2026.05.1")
        #expect(Privacy.scrubLogValue("true") == "true")
    }
}
