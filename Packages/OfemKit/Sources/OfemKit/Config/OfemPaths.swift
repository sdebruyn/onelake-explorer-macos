import Foundation

/// OfemPaths resolves the canonical on-disk locations for all OFEM state.
///
/// All paths sit under the shared App Group container so the sandboxed File
/// Provider Extension and the host app can both read and write them. The
/// Group Container identifier is hardcoded because OFEM ships from a single
/// Apple Developer team; forks that re-sign under a different team must
/// update `appGroupIdentifier` here.
public struct OfemPaths: Sendable {
    // MARK: - Constants

    /// The Apple Developer team ID OFEM is signed with.
    public static let teamID = "6D79CUWZ4J"

    /// The reverse-DNS bundle identifier shared by every OFEM process.
    public static let bundleID = "dev.debruyn.ofem"

    /// The App Group identifier shared by the host app and the File Provider
    /// Extension. It controls the shared container at
    /// `~/Library/Group Containers/<appGroupIdentifier>/`.
    public static let appGroupIdentifier = "\(teamID).group.\(bundleID)"

    // MARK: - Resolved paths

    /// The App Group container root. All other paths are derived from it.
    /// Corresponds to `~/Library/Group Containers/6D79CUWZ4J.group.dev.debruyn.ofem/`.
    public let configDir: URL

    /// The TOML config file containing accounts and settings.
    /// Corresponds to `<configDir>/config.toml`.
    public let configFile: URL

    /// Directory for the SQLite blob cache and shard files.
    /// Corresponds to `<configDir>/cache/`.
    public let cacheDir: URL

    /// Directory for rotated log files.
    /// Corresponds to `<configDir>/log/`.
    public let logDir: URL

    /// Directory for per-account token blobs written by `FileTokenStore`.
    /// Corresponds to `<configDir>/tokens/`.
    public let tokensDir: URL

    // MARK: - Initialiser

    /// Resolves the canonical OFEM paths for the current user.
    ///
    /// Sandboxed processes (the File Provider Extension, the host app) should
    /// call this initialiser because it tries `FileManager`'s App Group
    /// container API first and only falls back to a `$HOME`-relative path
    /// when the container is unavailable (e.g. in unit tests).
    public init() {
        self.init(root: Self.resolveContainerRoot())
    }

    /// Initialises with an explicit root directory. Useful in tests to avoid
    /// touching the real App Group container.
    public init(root: URL) {
        configDir = root
        configFile = root.appending(path: "config.toml", directoryHint: .notDirectory)
        cacheDir = root.appending(path: "cache", directoryHint: .isDirectory)
        logDir = root.appending(path: "log", directoryHint: .isDirectory)
        tokensDir = root.appending(path: "tokens", directoryHint: .isDirectory)
    }

    // MARK: - Private helpers

    /// Resolves the App Group container root.
    ///
    /// Prefers `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    /// because sandboxed processes must use that API to reach the shared
    /// container. Falls back to `$HOME/Library/Group Containers/<GroupID>/`
    /// when the container API is not available — e.g. when running unit
    /// tests outside the App Group entitlement.
    private static func resolveContainerRoot() -> URL {
        let fm = FileManager.default

        // Sandboxed processes: use the Apple-endorsed container API.
        if let containerURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return containerURL
        }

        // Unsandboxed (unit tests): fall back to $HOME-relative path.
        let home = fm.homeDirectoryForCurrentUser
        return home
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Group Containers", directoryHint: .isDirectory)
            .appending(path: appGroupIdentifier, directoryHint: .isDirectory)
    }
}

