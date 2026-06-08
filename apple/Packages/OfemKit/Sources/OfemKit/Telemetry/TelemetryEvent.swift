import Foundation

/// A single telemetry data point.
///
/// Mirrors `internal/telemetry/types.go` — `Event`. Optional fields use
/// their zero / nil value to mean "not applicable", exactly as the Go struct
/// does. Common fields (`installId`, `appVersion`, `platform`, `arch`,
/// `osVersion`) are injected by `TelemetryClient.track(_:)` and therefore
/// live on the client rather than on `TelemetryEvent`.
///
/// See `docs/telemetry.md` for the full schema and privacy model.
public struct TelemetryEvent: Sendable {
    // MARK: - Required fields

    /// App Insights custom event name (e.g. `"file_download"`).
    public let name: String

    // MARK: - Optional event-level fields

    /// Wall-clock timestamp. When `nil`, `TelemetryClient` fills it with
    /// `Date()` at enqueue time.
    public var time: Date?

    /// The Microsoft Entra tenant GUID associated with this operation.
    /// Empty for app-lifecycle events.
    public var tenantID: String

    /// Redacted account-alias correlator (`sha256(alias)[:8]`).
    /// Use `TelemetryRedaction.hashAlias(_:)` to compute it.
    public var accountAliasHash: String

    /// Operation duration in milliseconds. Zero means "not applicable".
    public var durationMs: Int64

    /// Whether the operation completed successfully. `nil` means "not applicable".
    public var success: Bool?

    /// Short, PII-free backend/library error code (max 32 chars).
    /// Use `TelemetryRedaction.safeErrorCode(_:)` before storing.
    public var errorCode: String

    /// I/O volume for `file_download` / `file_upload`. Zero = not applicable.
    public var bytesTransferred: Int64

    /// Items changed count for `sync_pulled`. Zero = not applicable.
    public var itemsChanged: Int

    /// Extra properties merged by `TelemetryClient.track(_:)`.
    ///
    /// Only keys in `TelemetryClient.allowedCommonPropKeys` survive the
    /// allowlist filter — unknown keys are silently dropped so no caller
    /// can smuggle a workspace name or path as a property key.
    public var commonProps: [String: String]

    // MARK: - Init

    /// Creates a `TelemetryEvent` with the required event name.
    public init(
        name: String,
        time: Date? = nil,
        tenantID: String = "",
        accountAliasHash: String = "",
        durationMs: Int64 = 0,
        success: Bool? = nil,
        errorCode: String = "",
        bytesTransferred: Int64 = 0,
        itemsChanged: Int = 0,
        commonProps: [String: String] = [:]
    ) {
        self.name = name
        self.time = time
        self.tenantID = tenantID
        self.accountAliasHash = accountAliasHash
        self.durationMs = durationMs
        self.success = success
        self.errorCode = errorCode
        self.bytesTransferred = bytesTransferred
        self.itemsChanged = itemsChanged
        self.commonProps = commonProps
    }
}
