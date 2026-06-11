import Testing
@testable import OfemKit
import Foundation

// MARK: - Stub URL protocol

/// A `URLProtocol` subclass that returns a pre-configured stub response
/// without hitting the network.
///
/// The handler is stored in a lock-protected dictionary keyed by the
/// URLSession's ObjectIdentifier, and each test creates its own session.
/// The HTTP suite is serialized (via `@Suite(.serialized)`) so only one
/// test's handler is active at a time.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var currentHandler: ((URLRequest) -> (Data, HTTPURLResponse))?
    private static let lock = NSLock()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
    (0..<count).map { TelemetryEvent(name: "ev\($0)") }
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
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

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
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataDict = json["data"] as! [String: Any]
        let baseData = dataDict["baseData"] as! [String: Any]

        #expect(dataDict["baseType"] as? String == "EventData")
        #expect(baseData["ver"] as? Int == 2)
        #expect(baseData["name"] as? String == "app_start")
    }

    @Test("envelope tags contain role and sdkVersion (store-22: scrubbed)")
    func tagsArePresent() throws {
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
    func tagsInstallIDIsScrubbed() throws {
        // A PII-containing install ID (e.g. user edited the TOML) must be
        // collapsed to "redacted" before it reaches the wire.
        let event = TelemetryEvent(name: "app_start")
        let envelope = AppInsightsEnvelope.from(
            event: event,
            iKey: "k",
            role: "ofem",
            installID: "user@example.com",  // contains @, must be scrubbed
            sdkTag: "ofem"
        )
        #expect(envelope.tags["ai.cloud.roleInstance"] == "redacted",
                "PII in installID must be scrubbed in tags")
    }

    @Test("time field is ISO 8601 with milliseconds")
    func timeFieldFormat() throws {
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
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let dataDict = json["data"] as! [String: Any]
        let baseData = dataDict["baseData"] as! [String: Any]
        #expect(baseData["measurements"] == nil, "measurements must be nil for bare event")
    }
}

// MARK: - HTTP status handling tests
// Serialized to ensure the shared StubURLProtocol handler is not overwritten
// by a concurrently running test.

@Suite("AppInsightsSink — HTTP status handling", .serialized)
struct AppInsightsSinkHTTPTests {

    @Test("200 OK completes without throwing")
    func status200() async throws {
        let session = StubURLProtocol.makeSession(
            statusCode: 200,
            body: #"{"itemsReceived":1,"itemsAccepted":1,"errors":[]}"#
        )
        let sink = try makeSink(session: session)
        try await sink.send(makeEvents(1))  // Must not throw.
    }

    @Test("400 client error throws ingestion error (non-retriable)")
    func status400() async throws {
        let session = StubURLProtocol.makeSession(statusCode: 400, body: "Bad Request")
        let sink = try makeSink(session: session)
        do {
            try await sink.send(makeEvents(1))
            Issue.record("Expected ingestion error, but no error was thrown")
        } catch AppInsightsSinkError.ingestion(let code, _) {
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
        } catch AppInsightsSinkError.ingestion(let code, _) {
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
        try await sink.send(makeEvents(2))  // Must not throw.
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
        } catch AppInsightsSinkError.partialReject(let accepted, let received, let retriable) {
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
        } catch AppInsightsSinkError.partialReject(_, _, let retriable) {
            #expect(retriable.count == 1)
            #expect(retriable[0].name == events[1].name)
            // Events 0 and 2 must NOT appear in retriable.
            let names = retriable.map { $0.name }
            #expect(!names.contains(events[0].name))
            #expect(!names.contains(events[2].name))
        }
    }
}
