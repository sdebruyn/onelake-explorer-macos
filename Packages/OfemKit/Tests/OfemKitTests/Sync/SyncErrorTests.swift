import Foundation
@testable import OfemKit
import Testing

// MARK: - SyncErrorTests

/// Tests for ``SyncError``: all cases, associated-value interpolation in
/// `description`, and the `fpCode` → `FPError.Code` mapping.
@Suite("SyncError")
struct SyncErrorTests {
    // MARK: - description: workspacePaused

    @Test("workspacePaused description")
    func workspacePausedDescription() {
        let err = SyncError.workspacePaused
        #expect(err.description == "sync: workspace capacity is paused")
    }

    // MARK: - description: shortDownload

    @Test("shortDownload description interpolates expected and got bytes")
    func shortDownloadDescription() {
        let err = SyncError.shortDownload(expected: 1024, got: 512)
        #expect(err.description == "sync: short download: expected 1024 bytes, got 512")
    }

    @Test("shortDownload description with zero got")
    func shortDownloadZeroGot() {
        let err = SyncError.shortDownload(expected: 100, got: 0)
        #expect(err.description == "sync: short download: expected 100 bytes, got 0")
    }

    // MARK: - description: blobSHAMismatch

    @Test("blobSHAMismatch description interpolates got and expected hashes")
    func blobSHAMismatchDescription() {
        let got = "aabbccdd"
        let expected = "11223344"
        let err = SyncError.blobSHAMismatch(got: got, expected: expected)
        #expect(err.description == "sync: blob SHA mismatch: got \(got), expected \(expected)")
    }

    // MARK: - description: spillFileError

    @Test("spillFileError description wraps the inner error message")
    func spillFileErrorDescription() {
        let inner = MockError.intentional("disk full")
        let err = SyncError.spillFileError(inner)
        // The description must include the "sync: spill file error:" prefix.
        #expect(err.description.hasPrefix("sync: spill file error:"))
        // It must also mention something from the wrapped error.
        #expect(err.description.contains("disk full") || err.description.contains("intentional"))
    }

    // MARK: - fpCode mapping

    @Test("workspacePaused maps to FPError.Code.serverBusy")
    func workspacePausedFPCode() {
        #expect(SyncError.workspacePaused.fpCode == .serverBusy)
    }

    @Test("shortDownload maps to FPError.Code.cannotSynchronize")
    func shortDownloadFPCode() {
        #expect(SyncError.shortDownload(expected: 10, got: 5).fpCode == .cannotSynchronize)
    }

    @Test("blobSHAMismatch maps to FPError.Code.cannotSynchronize")
    func blobSHAMismatchFPCode() {
        #expect(SyncError.blobSHAMismatch(got: "a", expected: "b").fpCode == .cannotSynchronize)
    }

    @Test("spillFileError maps to FPError.Code.cannotSynchronize")
    func spillFileErrorFPCode() {
        let inner = MockError.intentional("io")
        #expect(SyncError.spillFileError(inner).fpCode == .cannotSynchronize)
    }

    // MARK: - SyncError conforms to Error (throwable)

    @Test("SyncError can be thrown and caught by case")
    func syncErrorIsThrowable() throws {
        func throwPaused() throws {
            throw SyncError.workspacePaused
        }
        do {
            try throwPaused()
            Issue.record("expected throw")
        } catch {
            if case SyncError.workspacePaused = error {
                // correct
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("shortDownload preserves associated values through throw/catch")
    func shortDownloadThrowCatch() throws {
        func throwIt() throws {
            throw SyncError.shortDownload(expected: 999, got: 1)
        }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case let SyncError.shortDownload(exp, got) = error {
                #expect(exp == 999)
                #expect(got == 1)
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("blobSHAMismatch preserves associated values through throw/catch")
    func blobSHAMismatchThrowCatch() throws {
        func throwIt() throws {
            throw SyncError.blobSHAMismatch(got: "deadbeef", expected: "cafebabe")
        }
        do {
            try throwIt()
            Issue.record("expected throw")
        } catch {
            if case let SyncError.blobSHAMismatch(g, e) = error {
                #expect(g == "deadbeef")
                #expect(e == "cafebabe")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    // MARK: - FPError.classify integration

    @Test("FPError.classify routes workspacePaused to serverBusy")
    func classifyWorkspacePaused() {
        let code = FPError.classify(SyncError.workspacePaused)
        #expect(code == .serverBusy)
    }

    @Test("FPError.classify routes shortDownload to cannotSynchronize")
    func classifyShortDownload() {
        let code = FPError.classify(SyncError.shortDownload(expected: 100, got: 50))
        #expect(code == .cannotSynchronize)
    }

    @Test("FPError.classify routes blobSHAMismatch to cannotSynchronize")
    func classifyBlobSHAMismatch() {
        let code = FPError.classify(SyncError.blobSHAMismatch(got: "a", expected: "b"))
        #expect(code == .cannotSynchronize)
    }

    @Test("FPError.classify routes spillFileError to cannotSynchronize")
    func classifySpillFileError() {
        let code = FPError.classify(SyncError.spillFileError(MockError.intentional("x")))
        #expect(code == .cannotSynchronize)
    }
}
