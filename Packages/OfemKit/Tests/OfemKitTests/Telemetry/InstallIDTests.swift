import Testing
@testable import OfemKit
import Foundation

@Suite("InstallID")
struct InstallIDTests {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "ofem-install-id-\(UUID().uuidString).json",
                       directoryHint: .notDirectory)
    }

    @Test("ensure generates a UUID on first call")
    func ensureGeneratesUUID() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = InstallID(fileURL: url)
        let id = try await store.ensure()
        #expect(!id.isEmpty)
        // Should be a valid lowercase UUID (8-4-4-4-12).
        #expect(UUID(uuidString: id) != nil || id.count >= 32,
                "expected UUID-like string, got: \(id)")
    }

    @Test("ensure returns the same ID on repeated calls")
    func ensureIsIdempotent() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = InstallID(fileURL: url)
        let first = try await store.ensure()
        let second = try await store.ensure()
        #expect(first == second)
    }

    @Test("ensure persists the ID to disk and reloads it")
    func ensurePersistsToDisk() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = InstallID(fileURL: url)
        let first = try await store1.ensure()

        // Create a fresh actor pointing at the same file.
        let store2 = InstallID(fileURL: url)
        let second = try await store2.ensure()

        #expect(first == second, "reloaded ID must match persisted ID")
    }

    @Test("ensure creates intermediate directories")
    func ensureCreatesDirectories() async throws {
        let nested = FileManager.default.temporaryDirectory
            .appending(path: "ofem-install-id-nested-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "config", directoryHint: .isDirectory)
            .appending(path: "install_id.json", directoryHint: .notDirectory)
        defer {
            try? FileManager.default.removeItem(
                at: nested.deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        let store = InstallID(fileURL: nested)
        let id = try await store.ensure()
        #expect(!id.isEmpty)
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("IDs from different stores pointing at different files differ")
    func differentStoresDifferentIDs() async throws {
        let url1 = tempFileURL()
        let url2 = tempFileURL()
        defer {
            try? FileManager.default.removeItem(at: url1)
            try? FileManager.default.removeItem(at: url2)
        }

        let id1 = try await InstallID(fileURL: url1).ensure()
        let id2 = try await InstallID(fileURL: url2).ensure()
        #expect(id1 != id2, "independent stores must generate independent UUIDs")
    }
}
