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
/// https://learn.microsoft.com/azure/azure-monitor/app/sdk-connection-string?WT.mc_id=MVP_310840
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

    let trackURL: URL // Validated at init; never force-unwrapped (store-21)
    let iKey: String // InstrumentationKey
    let role: String // ai.cloud.role
    let installID: String // ai.cloud.roleInstance
    let sdkTag: String // ai.internal.sdkVersion ("ofem:2026.05.1")
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
        // store-21: validate and construct the track URL at init time so a
        // bad endpoint string fails fast here, not at send time with a crash.
        let (trackURL, key) = try Self.parseConnectionString(connectionString)
        self.trackURL = trackURL
        self.iKey = key
        self.role = "ofem"
        self.installID = installID
        self.sdkTag = appVersion.isEmpty ? "ofem" : "ofem:\(appVersion)"
        self.session = session ?? Self.defaultSession
    }

    // MARK: - TelemetrySink

    /// POSTs `events` to `<endpoint>v2/track`.
    ///
    /// On a 206 partial rejection, only the events identified in the
    /// `errors[]` array as retriable are thrown back; already-accepted events
    /// are not re-sent. (store-20)
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
        var request = URLRequest(url: trackURL, timeoutInterval: 30)
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

        // 4xx client errors: non-retriable — drop the batch entirely.
        if statusCode >= 400, statusCode < 500 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppInsightsSinkError.ingestion(statusCode: statusCode, body: body)
        }

        // Other non-2xx (e.g. 5xx): retriable as a unit.
        guard statusCode >= 200, statusCode < 300 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppInsightsSinkError.ingestion(statusCode: statusCode, body: body)
        }

        // 200 full success: nothing to do.
        guard statusCode == 206 else { return }

        // store-20: 206 partial rejection — re-send only the retriable rejected
        // items, not the whole batch. Accepted events must not be re-sent to
        // avoid duplicating counts in App Insights dashboards.
        if let tr = try? JSONDecoder().decode(TrackResponse.self, from: data),
           tr.itemsReceived > 0, tr.itemsAccepted < events.count
        {
            // Collect indices of retriable rejected items.
            let retriableIndices: [Int] = (tr.errors ?? [])
                .filter { Self.isRetriableStatusCode($0.statusCode) }
                .map { $0.index }
                .filter { $0 >= 0 && $0 < events.count }

            if retriableIndices.isEmpty { return }

            let retriable = retriableIndices.map { events[$0] }
            throw AppInsightsSinkError.partialReject(
                accepted: tr.itemsAccepted,
                received: events.count,
                retriable: retriable
            )
        }
    }

    // MARK: - Connection-string parser

    /// Parses a connection string and returns `(trackURL, instrumentationKey)`.
    ///
    /// - Throws: `AppInsightsSinkError` when the string is empty, a key=value
    ///   pair is malformed, `InstrumentationKey` is absent, or the resulting
    ///   URL is not a valid URL.
    static func parseConnectionString(_ s: String) throws -> (trackURL: URL, iKey: String) {
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

        // store-21: validate the URL at parse time so init fails fast on a
        // bad endpoint value, rather than crashing on the first send().
        guard let url = URL(string: endpoint + "v2/track") else {
            throw AppInsightsSinkError.invalidEndpointURL(endpoint)
        }
        return (url, iKey)
    }

    // MARK: - Retriable status codes

    /// App Insights per-item status codes that are worth retrying.
    /// 408 (timeout) and 503 (service unavailable) are retriable;
    /// 400 (bad request) is a permanent rejection.
    private static func isRetriableStatusCode(_ code: Int) -> Bool {
        code == 408 || code == 429 || code == 500 || code == 503
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
    let errors: [ItemError]?
}

// periphery:ignore - Decodable; `message` is decoded from JSON response body
private struct ItemError: Decodable {
    let index: Int
    let statusCode: Int
    let message: String?
}

// MARK: - Errors

/// Errors thrown by `AppInsightsSink`.
public enum AppInsightsSinkError: Error, LocalizedError {
    case emptyConnectionString
    case malformedConnectionString(String)
    case missingInstrumentationKey
    case invalidEndpointURL(String)
    case transport(any Error)
    case ingestion(statusCode: Int, body: String)
    case partialReject(accepted: Int, received: Int, retriable: [TelemetryEvent])

    public var errorDescription: String? {
        switch self {
        case .emptyConnectionString:
            "App Insights connection string is empty"
        case let .malformedConnectionString(entry):
            "Malformed App Insights connection-string entry: \(entry)"
        case .missingInstrumentationKey:
            "App Insights connection string missing InstrumentationKey"
        case let .invalidEndpointURL(ep):
            "App Insights IngestionEndpoint is not a valid URL: \(ep)"
        case let .transport(err):
            "App Insights transport error: \(err.localizedDescription)"
        case let .ingestion(code, body):
            "App Insights ingestion HTTP \(code): \(body)"
        case let .partialReject(accepted, received, _):
            "App Insights ingestion accepted \(accepted)/\(received) events"
        }
    }
}
