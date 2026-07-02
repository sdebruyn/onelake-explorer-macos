import Foundation

// MARK: - Upload staging prefix (finding F11)

/// Prefix for the temp sibling path ``OneLakeClient`` stages an upload at
/// before committing it via rename.
///
/// Shared with ``isMacOSMetadata`` so a staging file — whether caught
/// mid-flight by a concurrent listing, or orphaned by a hard kill between a
/// successful flush and the terminal rename — is filtered the same way as
/// `._*` AppleDouble junk: it never surfaces in a folder listing before its
/// rename lands (or at all, if it never does).
public let ofemUploadStagingPrefix = ".ofem-upload-"

// MARK: - macOS metadata filter

/// Returns `true` when `path` denotes a file that must never surface to the
/// user: a macOS metadata file that must never be pushed to OneLake, or an
/// ``OneLakeClient`` upload-staging file that must never be pulled down
/// (finding F11 — see ``ofemUploadStagingPrefix``).
///
/// Matches:
/// - `._*` — AppleDouble resource fork shadow
/// - `*.DS_Store`, `*.Spotlight-V100`, `*.Trashes`, `*.fseventsd`
/// - `.ofem-upload-*` — OneLakeClient's upload staging file
public func isMacOSMetadata(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    guard !name.isEmpty else { return false }
    if name.hasPrefix("._") { return true }
    if name.hasPrefix(ofemUploadStagingPrefix) { return true }
    let suffixes = [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd"]
    return suffixes.contains(where: { name.hasSuffix($0) })
}
