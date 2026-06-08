import Foundation

// MARK: - macOS metadata filter

/// Returns `true` when `path` denotes a macOS metadata file that must never
/// be pushed to OneLake.
///
/// Matches:
/// - `._*` — AppleDouble resource fork shadow
/// - `*.DS_Store`, `*.Spotlight-V100`, `*.Trashes`, `*.fseventsd`
///
/// Mirrors `internal/sync/upload.go` — `IsMacOSMetadata`.
public func isMacOSMetadata(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    guard !name.isEmpty else { return false }
    if name.hasPrefix("._") { return true }
    let suffixes = [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd"]
    return suffixes.contains(where: { name.hasSuffix($0) })
}
