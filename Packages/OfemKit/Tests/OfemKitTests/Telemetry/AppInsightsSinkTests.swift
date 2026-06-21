import Foundation
@testable import OfemKit
import Testing

/// Reads a request's body. Inside a `URLProtocol` handler the body always
/// arrives as `httpBodyStream` (URLSession converts `httpBody` to a stream
/// before handing the request to the protocol), so drain the stream.
private func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

// MARK: - Stub URL protocol

/// A `URLProtocol` subclass that returns a pre-configured stub response
/// without hitting the network.
///
/// **Global-handler scope (tests-05):** `currentHandler` is a process-global
/// mutable static. A second suite that also registered `StubURLProtocol` on
/// its own `URLSession` would clobber this handler. Currently `StubURLProtocol`
/// is only used by `AppInsightsSinkHTTPTests`; no other suite in this package
/// registers it. `AppInsightsSinkHTTPTests` is annotated `@Suite(.serialized)`
/// to prevent intra-suite handler races. If a future suite also needs this
/// stub, migrate to the global-registration pattern used by
/// `MockURLProtocol` in `NetTestHelpers.swift`.
///
/// Call `reset()` at the start of each test to clear stale handler state left
/// by a previous test.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var currentHandler: ((URLRequest) -> (Data, HTTPURLResponse))?
    static let lock = NSLock()

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let h = Self.lock.withLock { Self.currentHandler }
        guard let handler = h else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Clears the current handler, resetting state between tests so that stale
    /// state from a prior test cannot leak into the next one.
    static func reset() {
        lock.withLock { currentHandler = nil }
    }

    /// Creates a `URLSession` backed by this protocol and sets the response stub.
    static func makeSession(statusCode: Int, body: String = "") -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        lock.withLock {
            currentHandler = { request in
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (body.data(using: .utf8)!, resp)
            }
        }
        return session
    }
}

// MARK: - Helpers

private let validConnectionString =
    "InstrumentationKey=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;" +
    "IngestionEndpoint=https://eastus.in.applicationinsights.azure.com/"

private func makeSink(
    connectionString: String = validConnectionString,
    session: URLSession = StubURLProtocol.makeSession(statusCode: 200)
) throws -> AppInsightsSink {
    try AppInsightsSink(
        connectionString: connectionString,
        installID: "test-install",
        appVersion: "2026.06.1",
        session: session
    )
}

private func makeEvents(_ count: Int) -> [TelemetryEvent] {
    (0 ..< count).map { TelemetryEvent(name: "ev\($0)") }
}

// MARK: - Connection-string parsing tests

@Suite("AppInsightsSink — connection-string parsing")
struct AppInsightsSinkParsingTests {
    @Test("valid full connection string parses successfully")
    func validFullString() throws {
        let sink = try makeSink()
        #expect(sink.iKey == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(sink.trackURL.absoluteString ==
            "https://eastus.in.applicationinsights.azure.com/v2/track")
    }

    @Test("legacy InstrumentationKey-only string uses global endpoint")
    func legacyKeyOnly() throws {
        let sink = try makeSink(
            connectionString: "InstrumentationKey=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        #expect(sink.iKey == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(sink.trackURL.host == "dc.services.visualstudio.com")
    }

    @Test("keys are matched case-insensitively")
    func caseInsensitiveKeys() throws {
        let sink = try makeSink(
            connectionString:
            "instrumentationkey=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;" +
                "INGESTIONENDPOINT=https://westus.in.applicationinsights.azure.com/"
        )
        #expect(sink.iKey == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(sink.trackURL.host == "westus.in.applicationinsights.azure.com")
    }

    @Test("endpoint without trailing slash is normalised")
    func trailingSlashNormalised() throws {
        let sink = try makeSink(
            connectionString:
            "InstrumentationKey=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;" +
                "IngestionEndpoint=https://eastus.in.applicationinsights.azure.com"
        )
        #expect(sink.trackURL.absoluteString ==
            "https://eastus.in.applicationinsights.azure.com/v2/track")
    }

    @Test("empty connection string throws emptyConnectionString")
    func emptyStringThrows() throws {
        do {
            _ = try makeSink(connectionString: "")
            Issue.record("Expected emptyConnectionString, but no error was thrown")
        } catch AppInsightsSinkError.emptyConnectionString {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("missing InstrumentationKey throws missingInstrumentationKey")
    func missingKeyThrows() throws {
        do {
            _ = try makeSink(
                connectionString: "IngestionEndpoint=https://eastus.in.applicationinsights.azure.com/"
            )
            Issue.record("Expected missingInstrumentationKey, but no error was thrown")
        } catch AppInsightsSinkError.missingInstrumentationKey {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("malformed pair without = throws malformedConnectionString")
    func malformedPairThrows() throws {
        do {
            _ = try makeSink(connectionString: "InvalidPairWithoutEquals")
            Issue.record("Expected malformedConnectionString, but no error was thrown")
        } catch AppInsightsSinkError.malformedConnectionString {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("invalid endpoint URL throws invalidEndpointURL")
    func invalidEndpointURLThrows() throws {
        // A space in the scheme ("htt p://") makes URL(string:) return nil;
        // plain spaces elsewhere are percent-encoded and silently accepted.
        do {
            _ = try makeSink(
                connectionString:
                "InstrumentationKey=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;" +
                    "IngestionEndpoint=htt p://bad.endpoint.example.com/"
            )
            Issue.record("Expected invalidEndpointURL error, but no error was thrown")
        } catch AppInsightsSinkError.invalidEndpointURL {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("unknown keys are silently ignored")
    func unknownKeysIgnored() throws {
        let sink = try makeSink(
            connectionString:
            "InstrumentationKey=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee;" +
                "UnknownKey=something"
        )
        #expect(sink.iKey == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    }
}

// MARK: - Envelope wire-format tests

@Suite("AppInsightsEnvelope — wire format")
struct AppInsightsEnvelopeTests {
    @Test("envelope JSON contains required top-level keys")
    func topLevelKeys() throws {
        let event = TelemetryEvent(
            name: "app_start",
            time: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let envelope = AppInsightsEnvelope.from(
            event: event,
            iKey: "test-ikey",
            role: "ofem",
            installID: "install-abc",
            sdkTag: "ofem:2026.06.1"
        )

        let data = try JSONEncoder().encode(envelope)
        // tests-06: use as? + #require so a shape regression fails THIS test, not the whole run.
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "envelope JSON must be a dictionary"
        )

        #expect(json["name"] as? String == "Microsoft.ApplicationInsights.Event")
        #expect(json["iKey"] as? String == "test-ikey")
        #expect(json["time"] != nil)
        #expect(json["tags"] != nil)
        #expect(json["data"] != nil)
    }

    @Test("envelope data baseType and ver are correct")
    func baseTypeAndVer() throws {
        let event = TelemetryEvent(name: "app_start")
        let envelope = AppInsightsEnvelope.from(
            event: event, iKey: "k", role: "r", installID: "", sdkTag: "s"
        )

        let data = try JSONEncoder().encode(envelope)
        // tests-06: guarded casts so shape regressions fail this test only.
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "envelope JSON must be a dictionary"
        )
        let dataDict = try #require(json["data"] as? [String: Any], "'data' key must be a dictionary")
        let baseData = try #require(dataDict["baseData"] as? [String: Any], "'baseData' key must be a dictionary")

        #expect(dataDict["baseType"] as? String == "EventData")
        #expect(baseData["ver"] as? Int == 2)
        #expect(baseData["name"] as? String == "app_start")
    }

    @Test("envelope tags contain role and sdkVersion (store-22: scrubbed)")
    func tagsArePresent() {
        let event = TelemetryEvent(name: "app_start")
        let envelope = AppInsightsEnvelope.from(
            event: event,
            iKey: "k",
            role: "ofem",
            installID: "inst-123",
            sdkTag: "ofem:2026.06.1"
        )

        #expect(envelope.tags["ai.cloud.role"] == "ofem")
        #expect(envelope.tags["ai.internal.sdkVersion"] == "ofem:2026.06.1")
        #expect(envelope.tags["ai.cloud.roleInstance"] == "inst-123")
    }

    @Test("envelope tags installID is scrubbed (store-22)")
    func tagsInstallIDIsScrubbed() {
        // A PII-containing install ID (e.g. user edited the TOML) must be
        // collapsed to "redacted" before it reaches the wire.
        let event = TelemetryEvent(name: "app_start")
        let envelope = AppInsightsEnvelope.from(
            event: event,
            iKey: "k",
            role: "ofem",
            installID: "user@example.com", // contains @, must be scrubbed
            sdkTag: "ofem"
        )
        #expect(envelope.tags["ai.cloud.roleInstance"] == "redacted",
                "PII in installID must be scrubbed in tags")
    }

    @Test("time field is ISO 8601 with milliseconds")
    func timeFieldFormat() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let event = TelemetryEvent(name: "app_start", time: date)
        let envelope = AppInsightsEnvelope.from(
            event: event, iKey: "k", role: "r", installID: "", sdkTag: "s"
        )
        // Must parse back to a valid Date via ISO8601.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(fmt.date(from: envelope.time) != nil,
                "time field must be valid ISO 8601: \(envelope.time)")
    }

    @Test("event properties are nil when empty")
    func nilPropertiesWhenEmpty() throws {
        // A bare event with no fields should have nil measurements.
        let event = TelemetryEvent(name: "app_start")
        let envelope = AppInsightsEnvelope.from(
            event: event, iKey: "k", role: "r", installID: "", sdkTag: "s"
        )
        let data = try JSONEncoder().encode(envelope)
        // tests-06: guarded casts so shape regressions fail this test only.
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "envelope JSON must be a dictionary"
        )
        let dataDict = try #require(json["data"] as? [String: Any], "'data' key must be a dictionary")
        let baseData = try #require(dataDict["baseData"] as? [String: Any], "'baseData' key must be a dictionary")
        #expect(baseData["measurements"] == nil, "measurements must be nil for bare event")
    }
}

// MARK: - HTTP status handling tests

// Serialized to ensure the shared StubURLProtocol handler is not overwritten
// by a concurrently running test.

@Suite("AppInsightsSink — HTTP status handling", .serialized)
struct AppInsightsSinkHTTPTests {
    /// Reset any stale handler before each test so prior-test state cannot
    /// leak forward (tests-05: per-test handler reset).
    init() {
        StubURLProtocol.reset()
    }

    @Test("200 OK completes without throwing")
    func status200() async throws {
        let session = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"{"itemsReceived":1,"itemsAccepted":1,"errors":[]}"#
        )
        let sink = try makeSink(session: session)
        try await sink.send(makeEvents(1)) // Must not throw.
    }

    @Test("400 client error throws ingestion error (non-retriable)")
    func status400() async throws {
        let session = StubURLProtocol.makeSession(statusCode: 400, body: "Bad Request")
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected ingestion error, but no error was thrown")
        } catch let AppInsightsSinkError.ingestion(code, _) {
            #expect(code == 400)
        }
    }

    @Test("500 server error throws ingestion error (retriable)")
    func status500() async throws {
        let session = StubURLProtocol.makeSession(statusCode: 500, body: "Internal Server Error")
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected ingestion error, but no error was thrown")
        } catch let AppInsightsSinkError.ingestion(code, _) {
            #expect(code == 500)
        }
    }

    // MARK: - 206 partial reject

    @Test("206 with all events accepted does not throw")
    func status206AllAccepted() async throws {
        let session = StubURLProtocol.makeSession(
            statusCode: 206,
            body: #"{"itemsReceived":2,"itemsAccepted":2,"errors":[]}"#
        )
        let sink = try makeSink(session: session)
        try await sink.send(makeEvents(2)) // Must not throw.
    }

    @Test("206 partial reject throws partialReject with only retriable events (store-20)")
    func status206PartialReject() async throws {
        // Item 0 accepted; item 1 rejected with a retriable 503.
        let body = """
        {
          "itemsReceived": 2,
          "itemsAccepted": 1,
          "errors": [{"index": 1, "statusCode": 503, "message": "Service unavailable"}]
        }
        """
        let session = StubURLProtocol.makeSession(statusCode: 206, body: body)
        let events = makeEvents(2)
        let sink = try makeSink(session: session)
        do {
            try await sink.send(events)
            Issue.record("Expected partialReject, but no error was thrown")
        } catch let AppInsightsSinkError.partialReject(accepted, received, retriable) {
            #expect(accepted == 1)
            #expect(received == 2)
            // Only the rejected item (index 1) should be in retriable.
            #expect(retriable.count == 1)
            #expect(retriable[0].name == events[1].name,
                    "accepted event (index 0) must not be in retriable list")
        }
    }

    @Test("206 partial reject with non-retriable error does not re-queue (store-20)")
    func status206NonRetriableError() async throws {
        // Item 0 rejected with 400 (non-retriable), item 1 accepted.
        let body = """
        {
          "itemsReceived": 2,
          "itemsAccepted": 1,
          "errors": [{"index": 0, "statusCode": 400, "message": "Bad request"}]
        }
        """
        let session = StubURLProtocol.makeSession(statusCode: 206, body: body)
        let sink = try makeSink(session: session)
        // Should NOT throw because there are no retriable items.
        try await sink.send(makeEvents(2))
    }

    @Test("accepted events are not in the retriable list (store-20 anti-duplicate)")
    func acceptedEventsNotRetried() async throws {
        // Items 0 and 2 accepted; item 1 rejected with retriable 503.
        let body = """
        {
          "itemsReceived": 3,
          "itemsAccepted": 2,
          "errors": [{"index": 1, "statusCode": 503, "message": "Unavailable"}]
        }
        """
        let session = StubURLProtocol.makeSession(statusCode: 206, body: body)
        let events = makeEvents(3)
        let sink = try makeSink(session: session)
        do {
            try await sink.send(events)
            Issue.record("Expected partialReject")
        } catch let AppInsightsSinkError.partialReject(_, _, retriable) {
            #expect(retriable.count == 1)
            #expect(retriable[0].name == events[1].name)
            // Events 0 and 2 must NOT appear in retriable.
            let names = retriable.map { $0.name }
            #expect(!names.contains(events[0].name))
            #expect(!names.contains(events[2].name))
        }
    }

    @Test("empty events array is a no-op — no HTTP request is made")
    func emptyBatchIsNoop() async throws {
        // Set the handler to nil so any actual POST would trigger a transport
        // error via the "no handler" path in StubURLProtocol.startLoading().
        StubURLProtocol.lock.withLock { StubURLProtocol.currentHandler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let sink = try makeSink(session: session)
        // Must complete without throwing even though no stub is installed.
        try await sink.send([])
    }

    @Test("transport error wraps the underlying error in AppInsightsSinkError.transport")
    func transportErrorWrapped() async throws {
        // Nil handler → StubURLProtocol fires URLError(.unknown), which must
        // be caught and rethrown as .transport(_).
        StubURLProtocol.lock.withLock { StubURLProtocol.currentHandler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected transport error")
        } catch {
            if case AppInsightsSinkError.transport = error {
                // Correct — underlying URLError is wrapped.
            } else {
                Issue.record("Expected .transport, got \(error)")
            }
        }
    }

    @Test("404 client error throws ingestion error (non-retriable 4xx)")
    func status404() async throws {
        let session = StubURLProtocol.makeSession(statusCode: 404, body: "Not Found")
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected ingestion error")
        } catch let AppInsightsSinkError.ingestion(code, body) {
            #expect(code == 404)
            #expect(body == "Not Found")
        }
    }

    @Test("503 server error throws ingestion error with body")
    func status503() async throws {
        let session = StubURLProtocol.makeSession(statusCode: 503, body: "Service Unavailable")
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected ingestion error")
        } catch let AppInsightsSinkError.ingestion(code, body) {
            #expect(code == 503)
            #expect(body == "Service Unavailable")
        }
    }

    @Test("3xx response throws ingestion error (not a 2xx)")
    func status302() async throws {
        let session = StubURLProtocol.makeSession(statusCode: 302, body: "")
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected ingestion error")
        } catch let AppInsightsSinkError.ingestion(code, _) {
            #expect(code == 302)
        }
    }

    @Test("POST request carries correct headers and JSON body")
    func postRequestShape() async throws {
        // tests-05: use NSLock-protected boxes to avoid data races on vars
        // captured in the handler closure, which runs on URLSession's delegate
        // queue, and read after the await on the test's task.
        final class CaptureBox: @unchecked Sendable {
            let lock = NSLock()
            var request: URLRequest?
            var body: Data?
        }
        let box = CaptureBox()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.currentHandler = { request in
                let body = requestBody(request)
                box.lock.withLock {
                    box.request = request
                    box.body = body
                }
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(), resp)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let sink = try makeSink(session: session)
        try await sink.send(makeEvents(2))

        let (capturedRequest, capturedBody) = box.lock.withLock { (box.request, box.body) }
        let req = try #require(capturedRequest, "No request was captured")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(req.url?.absoluteString == "https://eastus.in.applicationinsights.azure.com/v2/track")

        // Body must be a JSON array of 2 envelopes.
        // tests-06: guarded casts so shape regressions fail this test only.
        let body = try #require(capturedBody, "Request body must not be nil")
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [[String: Any]],
            "Request body must be a JSON array of objects"
        )
        #expect(json.count == 2)
        #expect(json[0]["iKey"] as? String == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(json[0]["name"] as? String == "Microsoft.ApplicationInsights.Event")
    }

    @Test("iKey in envelope matches the instrumentation key from the connection string")
    func iKeyInEnvelope() async throws {
        // tests-05: lock-protected box avoids the handler→test data race.
        final class BodyBox: @unchecked Sendable {
            let lock = NSLock()
            var data: Data?
        }
        let box = BodyBox()
        StubURLProtocol.lock.withLock {
            StubURLProtocol.currentHandler = { request in
                let body = requestBody(request)
                box.lock.withLock { box.data = body }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let sink = try AppInsightsSink(
            connectionString:
            "InstrumentationKey=12345678-1234-1234-1234-123456789abc;" +
                "IngestionEndpoint=https://westeurope.in.applicationinsights.azure.com/",
            installID: "inst",
            appVersion: "2026.06.1",
            session: session
        )
        try await sink.send(makeEvents(1))

        let capturedBody = box.lock.withLock { box.data }
        // tests-06: guarded cast so shape regressions fail this test only.
        let body = try #require(capturedBody)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [[String: Any]],
            "Request body must be a JSON array of objects"
        )
        #expect(json[0]["iKey"] as? String == "12345678-1234-1234-1234-123456789abc")
    }

    @Test("sdkTag is 'ofem' when appVersion is empty")
    func sdkTagEmptyVersion() throws {
        let sink = try AppInsightsSink(
            connectionString: validConnectionString,
            installID: "",
            appVersion: "",
            session: StubURLProtocol.makeSession(statusCode: 200)
        )
        #expect(sink.sdkTag == "ofem")
    }

    @Test("sdkTag is 'ofem:<version>' when appVersion is provided")
    func sdkTagWithVersion() throws {
        let sink = try makeSink()
        #expect(sink.sdkTag == "ofem:2026.06.1")
    }

    @Test("206 with malformed JSON body does not throw (graceful decode failure)")
    func status206MalformedBody() async throws {
        // If the 206 body cannot be decoded as TrackResponse the sink should
        // not throw — it falls through the guard-let without a partialReject.
        let session = StubURLProtocol.makeSession(statusCode: 206, body: "not-json{{{")
        let sink = try makeSink(session: session)
        try await sink.send(makeEvents(2)) // Must not throw.
    }

    @Test("206 with out-of-bounds error index is filtered out")
    func status206OutOfBoundsIndex() async throws {
        // Index 99 is beyond the 2-event batch; should produce no retriable items.
        let body = """
        {
          "itemsReceived": 2,
          "itemsAccepted": 1,
          "errors": [{"index": 99, "statusCode": 503, "message": "Unavailable"}]
        }
        """
        let session = StubURLProtocol.makeSession(statusCode: 206, body: body)
        let sink = try makeSink(session: session)
        // No retriable items → should not throw.
        try await sink.send(makeEvents(2))
    }

    @Test("206 with only 408 retriable error code re-queues correctly")
    func status206Retriable408() async throws {
        let body = """
        {
          "itemsReceived": 1,
          "itemsAccepted": 0,
          "errors": [{"index": 0, "statusCode": 408, "message": "Timeout"}]
        }
        """
        let session = StubURLProtocol.makeSession(statusCode: 206, body: body)
        let events = makeEvents(1)
        let sink = try makeSink(session: session)
        do {
            try await sink.send(events)
            Issue.record("Expected partialReject for 408")
        } catch let AppInsightsSinkError.partialReject(accepted, received, retriable) {
            #expect(accepted == 0)
            #expect(received == 1)
            #expect(retriable.count == 1)
        }
    }

    @Test("206 with only 429 retriable error code re-queues correctly")
    func status206Retriable429() async throws {
        let body = """
        {
          "itemsReceived": 2,
          "itemsAccepted": 0,
          "errors": [
            {"index": 0, "statusCode": 429, "message": "Too Many Requests"},
            {"index": 1, "statusCode": 429, "message": "Too Many Requests"}
          ]
        }
        """
        let session = StubURLProtocol.makeSession(statusCode: 206, body: body)
        let events = makeEvents(2)
        let sink = try makeSink(session: session)
        do {
            try await sink.send(events)
            Issue.record("Expected partialReject for 429")
        } catch let AppInsightsSinkError.partialReject(_, _, retriable) {
            #expect(retriable.count == 2)
        }
    }
}
