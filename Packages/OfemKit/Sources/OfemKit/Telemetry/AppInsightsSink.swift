import Foundation

/// A `TelemetrySink` that POSTs events to the Application Insights v2/track
/// ingestion endpoint.
///
/// This is the Swift equivalent of `AppInsightsSink` in
/// accepted by the same App Insights resource.
///
/// ### Connection string
///
/// App Insights connection strings are semicolon-separated `Key=Value` pairs
/// (case-insensitive keys). We need `InstrumentationKey` and
/// `IngestionEndpoint`. See:
/// https://learn.microsoft.com/azure/azure-monitor/app/sdk-connection-string
///
/// ### HTTP client
///
/// `AppInsightsSink` uses a plain `URLSession` rather than the `HTTPClient`
/// from `OfemKit/Net` to avoid the token-injection and gate logic that is
/// only appropriate for authenticated OneLake/Fabric calls. Telemetry
/// POSTs are unauthenticated (the instrumentation key in the payload is
/// the only credential).
public struct AppInsightsSink: TelemetrySink {
    // MARK: - State

    let endpoint: String     // IngestionEndpoint, trailing-slash normalised
    let iKey: String         // InstrumentationKey
    let role: String         // ai.cloud.role
    let installID: String    // ai.cloud.roleInstance
    let sdkTag: String       // ai.internal.sdkVersion ("ofem:2026.05.1")
    let session: URLSession

    // MARK: - Init

    /// Creates an `AppInsightsSink` from an App Insights connection string.
    ///
    /// - Parameters:
    /// - connectionString: Full App Insights connection string.
    /// - installID: The per-install UUID (becomes `ai.cloud.roleInstance`).
    /// - appVersion: OFEM version (becomes `ai.internal.sdkVersion`).
    /// - session: URL session. Defaults to a 30-second timeout session.
    /// - Throws: `AppInsightsSinkError` when the connection string is
    /// malformed or missing required keys.
    public init(
        connectionString: String,
        installID: String = "",
        appVersion: String = "",
        session: URLSession? = nil
    ) throws {
        let (ep, key) = try Self.parseConnectionString(connectionString)
        self.endpoint = ep
        self.iKey = key
        self.role = "ofem"
        self.installID = installID
        self.sdkTag = appVersion.isEmpty ? "ofem" : "ofem:\(appVersion)"
        self.session = session ?? Self.defaultSession
    }

    // MARK: - TelemetrySink

    /// POSTs `events` to `<endpoint>v2/track`.
    ///
    /// Throws `AppInsightsSinkError` when the HTTP layer fails or the
    /// ingestion endpoint rejects events.
    public func send(_ events: [TelemetryEvent]) async throws {
        guard !events.isEmpty else { return }

        let envelopes = events.map { ev in
            AppInsightsEnvelope.from(
                event: ev,
                iKey: iKey,
                role: role,
                installID: installID,
                sdkTag: sdkTag
            )
        }

        let body = try JSONEncoder().encode(envelopes)
        var request = URLRequest(
            url: URL(string: endpoint + "v2/track")!,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppInsightsSinkError.transport(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppInsightsSinkError.transport(URLError(.badServerResponse))
        }

        let statusCode = httpResponse.statusCode
        guard statusCode >= 200, statusCode < 300 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppInsightsSinkError.ingestion(statusCode: statusCode, body: body)
        }

        // Parse the itemsAccepted field; a partial rejection is treated as
        // a failure so the caller re-queues. Mirrors the Go behaviour.
        if !data.isEmpty,
           let tr = try? JSONDecoder().decode(TrackResponse.self, from: data),
           tr.itemsReceived > 0, tr.itemsAccepted < events.count
        {
            throw AppInsightsSinkError.partialReject(
                accepted: tr.itemsAccepted,
                received: events.count
            )
        }
    }

    // MARK: - Connection-string parser

    ///
    static func parseConnectionString(_ s: String) throws -> (endpoint: String, iKey: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppInsightsSinkError.emptyConnectionString
        }

        var endpoint = ""
        var iKey = ""

        for raw in trimmed.split(separator: ";") {
            let pair = raw.trimmingCharacters(in: .whitespaces)
            guard let eqIdx = pair.firstIndex(of: "=") else {
                throw AppInsightsSinkError.malformedConnectionString(String(pair))
            }
            let key = pair[..<eqIdx].lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "ingestionendpoint": endpoint = value
            case "instrumentationkey": iKey = value
            default: break
            }
        }

        guard !iKey.isEmpty else {
            throw AppInsightsSinkError.missingInstrumentationKey
        }
        if endpoint.isEmpty {
            // Legacy global endpoint (plain `InstrumentationKey=…` string).
            endpoint = "https://dc.services.visualstudio.com/"
        }
        if !endpoint.hasSuffix("/") {
            endpoint += "/"
        }
        return (endpoint, iKey)
    }

    // MARK: - Default session

    private static var defaultSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }
}

// MARK: - Response shape

private struct TrackResponse: Decodable {
    let itemsReceived: Int
    let itemsAccepted: Int
}

// MARK: - Errors

/// Errors thrown by `AppInsightsSink`.
public enum AppInsightsSinkError: Error, LocalizedError {
    case emptyConnectionString
    case malformedConnectionString(String)
    case missingInstrumentationKey
    case transport(any Error)
    case ingestion(statusCode: Int, body: String)
    case partialReject(accepted: Int, received: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyConnectionString:
            return "App Insights connection string is empty"
        case .malformedConnectionString(let entry):
            return "Malformed App Insights connection-string entry: \(entry)"
        case .missingInstrumentationKey:
            return "App Insights connection string missing InstrumentationKey"
        case .transport(let err):
            return "App Insights transport error: \(err.localizedDescription)"
        case .ingestion(let code, let body):
            return "App Insights ingestion HTTP \(code): \(body)"
        case .partialReject(let accepted, let received):
            return "App Insights ingestion accepted \(accepted)/\(received) events"
        }
    }
}
