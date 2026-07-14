import Foundation
@testable import OfemKit
import Testing

// MARK: - ErrorOverloadTests

@Suite("OfemLogger error-taking overloads")
struct ErrorOverloadTests {
    // MARK: - warn(_:error:)

    @Test("warn(_:error:) writes level=WARN with errorCode and errorDescription")
    func warnErrorOverloadWritesWarnLevel() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let err = NSError(domain: "TestDomain", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "something went wrong",
            ])
            logger.warn("test warning", error: err)
            let lines = try capturedLines(directory: dir)
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            #expect(line["level"] == "WARN")
            #expect(line["msg"] == "test warning")
            #expect(line["errorCode"] == "TestDomain.42")
            #expect(line["errorDescription"] != nil)
        }
    }

    // MARK: - error(_:error:)

    @Test("error(_:error:) writes level=ERROR with errorCode")
    func errorErrorOverloadWritesErrorLevel() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let err = NSError(domain: "com.example.Engine", code: 7)
            logger.error("engine failed", error: err)
            let lines = try capturedLines(directory: dir)
            #expect(lines.count == 1)
            let line = try #require(lines.first)
            #expect(line["level"] == "ERROR")
            #expect(line["msg"] == "engine failed")
            #expect(line["errorCode"] == "com.example.Engine.7")
        }
    }

    // MARK: - errorCode safe-charset

    @Test("errorCode with safe-charset characters survives redaction")
    func errorCodePassesSafeCharset() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            // domain uses only [A-Za-z0-9_.:-] — all safe
            let err = NSError(domain: "NSCocoaErrorDomain", code: 256)
            logger.warn("redaction test", error: err)
            let lines = try capturedLines(directory: dir)
            let line = try #require(lines.first)
            // errorCode is "NSCocoaErrorDomain.256" — safe charset, written verbatim
            #expect(line["errorCode"] == "NSCocoaErrorDomain.256")
        }
    }

    // MARK: - errorDescription redaction

    @Test("errorDescription with unsafe characters is redacted in release configuration")
    func errorDescriptionWithUnsafeCharsIsRedactedByPrivacy() {
        // The Privacy.scrubLogValue path is exercised directly — safe charset
        // keeps the value, unsafe chars collapse to "redacted".
        let unsafe = "path/to/file with spaces"
        let safe = "NSPOSIXErrorDomain.2"
        #expect(Privacy.scrubLogValue(unsafe) == "redacted")
        #expect(Privacy.scrubLogValue(safe) == safe)
    }

    // MARK: - caller-supplied metadata is preserved

    @Test("warn(_:error:metadata:) preserves caller-supplied metadata keys")
    func warnErrorPreservesCallerMetadata() async throws {
        try await withTempDir { dir in
            let logger = makeCapturingLogger(directory: dir)
            let err = NSError(domain: "TestDomain", code: 1)
            logger.warn("operation failed", error: err, metadata: ["alias": "dev"])
            let lines = try capturedLines(directory: dir)
            let line = try #require(lines.first)
            #expect(line["alias"] == "dev")
            #expect(line["errorCode"] != nil)
        }
    }
}
