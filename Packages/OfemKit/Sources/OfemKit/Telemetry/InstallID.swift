import Foundation

/// Per-install pseudonymous identifier for telemetry deduplication.
///
/// Mirrors `EnsureInstallID` in `internal/telemetry/installid.go`.
/// A UUIDv4 is generated on first use and persisted to a small JSON file
/// inside the OFEM config directory so it survives across app restarts.
/// Removing OFEM (`brew uninstall --zap`) removes the config directory and
/// therefore the install ID; reinstalling generates a new one.
///
/// ### Thread safety
///
/// `InstallID` is an actor so concurrent calls to `ensure()` coalesce into
/// a single file write.
///
/// ### Privacy
///
/// The install ID is a random UUID — it does not identify the user, machine,
/// or tenant. It is used only to deduplicate events from the same install in
/// App Insights dashboards. See `docs/telemetry.md`.
public actor InstallID {
    // MARK: - State

    private let fileURL: URL
    private var cached: String?

    // MARK: - File format

    private struct Envelope: Codable {
        let installId: String
    }

    // MARK: - Init

    /// Creates an `InstallID` backed by `fileURL`.
    ///
    /// - Parameter fileURL: Path to the JSON file that persists the ID.
    ///   Typically `<configDir>/install_id.json`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Public API

    /// Returns the install ID, generating and persisting a new UUIDv4 on
    /// first use.
    ///
    /// Throws if the persistence step fails (e.g. the config directory is
    /// not writable). Callers should treat the error as non-fatal and disable
    /// telemetry when the install ID cannot be obtained.
    public func ensure() async throws -> String {
        if let id = cached { return id }

        // Try reading the persisted ID first.
        if let id = try? readFromDisk() {
            cached = id
            return id
        }

        // Generate and persist a new one.
        let newID = UUID().uuidString.lowercased()
        try writeToDisk(newID)
        cached = newID
        return newID
    }

    // MARK: - Helpers

    private func readFromDisk() throws -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let id = envelope.installId.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private func writeToDisk(_ id: String) throws {
        // Ensure the parent directory exists.
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let envelope = Envelope(installId: id)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }
}
