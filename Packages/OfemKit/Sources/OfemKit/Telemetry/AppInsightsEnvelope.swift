import Foundation

/// Wire-format types for the Application Insights v2/track HTTP endpoint.
///
/// The JSON key names are snake_case / camelCase as required by the App
/// Insights ingestion API — they must not be changed without bumping the
/// API version.
///
/// Every property value that enters these structs has already been routed
/// through `TelemetryRedaction.scrubProperty` / `safeErrorCode` in
/// `splitFields(_:)`, making the privacy guarantee structural.

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
    /// becomes outbound data.
    static func from(
        event: TelemetryEvent,
        iKey: String,
        role: String,
        installID: String,
        sdkTag: String
    ) -> AppInsightsEnvelope {
        let ts = event.time ?? Date()
        let (props, meas) = splitFields(event)

        var tags: [String: String] = [
            "ai.cloud.role": role,
            "ai.internal.sdkVersion": sdkTag,
        ]
        if !installID.isEmpty {
            tags["ai.cloud.roleInstance"] = installID
        }

        return AppInsightsEnvelope(
            name: "Microsoft.ApplicationInsights.Event",
            time: Self.formatTime(ts),
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

    private static func formatTime(_ date: Date) -> String {
        // RFC 3339 with milliseconds, e.g. "2026-06-08T15:04:05.000Z".
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: date)
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
