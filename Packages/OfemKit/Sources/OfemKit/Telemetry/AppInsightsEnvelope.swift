import Foundation

/// Wire-format types for the Application Insights v2/track HTTP endpoint.
///
/// The JSON key names are snake_case / camelCase as required by the App
/// Insights ingestion API — they must not be changed without bumping the
/// API version.
///
/// Every property value that enters these structs has already been routed
/// through `TelemetryRedaction.scrubProperty` / `safeErrorCode` in
/// `splitFields(_:)`, making the privacy guarantee structural. The `tags`
/// dictionary is constructed inside `from(event:…)` after that boundary
/// (store-22), so the invariant is total.

// MARK: - Envelope (top-level)

struct AppInsightsEnvelope: Encodable {
    let name: String
    let time: String
    let iKey: String
    let tags: [String: String]
    let data: EnvelopeData

    enum CodingKeys: String, CodingKey {
        case name, time, iKey, tags, data
    }
}

// MARK: - Data wrapper

struct EnvelopeData: Encodable {
    let baseType: String
    let baseData: EventBaseData
}

// MARK: - Event payload

struct EventBaseData: Encodable {
    let ver: Int
    let name: String
    let properties: [String: String]?
    let measurements: [String: Double]?
}

// MARK: - Builder

extension AppInsightsEnvelope {
    /// Builds an `AppInsightsEnvelope` from a `TelemetryEvent`, merging in
    /// the sink-level metadata (instrumentation key, role, install ID, SDK tag).
    ///
    /// All string property values are passed through `scrubProperty` /
    /// `safeErrorCode` at this boundary — the single place where an event
    /// becomes outbound data. The `tags` dictionary is constructed here
    /// (inside the boundary) so the privacy invariant is total. (store-22)
    static func from(
        event: TelemetryEvent,
        iKey: String,
        role: String,
        installID: String,
        sdkTag: String
    ) -> AppInsightsEnvelope {
        let ts = event.time ?? Date()
        let (props, meas) = splitFields(event)

        // store-22: construct tags inside the redaction boundary so any
        // corrupted or user-supplied installID value is scrubbed before it
        // leaves the device.
        var tags: [String: String] = [
            "ai.cloud.role": TelemetryRedaction.scrubProperty(role),
            "ai.internal.sdkVersion": TelemetryRedaction.scrubProperty(sdkTag),
        ]
        if !installID.isEmpty {
            tags["ai.cloud.roleInstance"] = TelemetryRedaction.scrubProperty(installID)
        }

        return AppInsightsEnvelope(
            name: "Microsoft.ApplicationInsights.Event",
            time: SharedFormatter.isoTimestamp(ts),
            iKey: iKey,
            tags: tags,
            data: EnvelopeData(
                baseType: "EventData",
                baseData: EventBaseData(
                    ver: 2,
                    name: event.name,
                    properties: props.isEmpty ? nil : props,
                    measurements: meas.isEmpty ? nil : meas
                )
            )
        )
    }
}

// MARK: - Shared ISO 8601 formatter (store-15)

/// A single static `ISO8601DateFormatter` shared across all telemetry
/// envelope timestamps. `ISO8601DateFormatter` is thread-safe once its
/// format options are configured.
/// Note: logging uses a separate formatter in `OfemLogger`; this enum is
/// scoped to the telemetry package only.
enum SharedFormatter {
    // ISO8601DateFormatter is documented as thread-safe after configuration;
    // nonisolated(unsafe) suppresses the Swift concurrency check.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    /// Returns an RFC 3339 / ISO 8601 string with milliseconds, e.g.
    /// `"2026-06-08T15:04:05.000Z"`.
    static func isoTimestamp(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Field split (mirrors splitFields in fields.go)

/// Converts a `TelemetryEvent` into the App Insights `properties` +
/// `measurements` split, applying redaction at the boundary.
///
///
/// **only** producer of the property map the sink sends, so privacy
/// guarantees are structural — even a PII value smuggled into CommonProps
/// is collapsed to `"redacted"` here.
func splitFields(_ event: TelemetryEvent) -> (props: [String: String], meas: [String: Double]) {
    var props: [String: String] = [:]

    // Merge CommonProps under the allowlist. Unknown keys are dropped so
    // no caller can smuggle a workspace name, path, or UPN as a prop key.
    for (k, v) in event.commonProps where allowedCommonPropKeys.contains(k) {
        let scrubbed = TelemetryRedaction.scrubProperty(v)
        if !scrubbed.isEmpty { props[k] = scrubbed }
    }

    props["event"] = TelemetryRedaction.scrubProperty(event.name)

    if !event.tenantID.isEmpty {
        props["tenantId"] = TelemetryRedaction.scrubProperty(event.tenantID)
    }
    if !event.accountAliasHash.isEmpty {
        props["accountAliasHash"] = TelemetryRedaction.scrubProperty(event.accountAliasHash)
    }
    if !event.errorCode.isEmpty {
        props["errorCode"] = TelemetryRedaction.safeErrorCode(event.errorCode)
    }
    if let success = event.success {
        props["success"] = success ? "true" : "false"
    }

    var meas: [String: Double] = [:]
    if event.durationMs != 0 {
        meas["durationMs"] = Double(event.durationMs)
    }
    if event.bytesTransferred != 0 {
        meas["bytesTransferred"] = Double(event.bytesTransferred)
    }
    if event.itemsChanged != 0 {
        meas["itemsChanged"] = Double(event.itemsChanged)
    }

    return (props, meas)
}

// MARK: - Allowlist

/// The exhaustive set of keys permitted in `TelemetryEvent.commonProps`.
///
///
/// Any key not in this set is silently dropped at the `splitFields` step.
let allowedCommonPropKeys: Set<String> = [
    "installId",
    "appVersion",
    "platform",
    "arch",
    "osVersion",
    "failedOp",
]
