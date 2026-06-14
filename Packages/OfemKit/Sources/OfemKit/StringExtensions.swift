import Foundation

// MARK: - Shared URL-encoding helpers

extension String {
    /// Percent-encodes a single URL path segment so that reserved characters
    /// (including `/`) cannot restructure the path hierarchy.
    ///
    /// `urlPathAllowed` includes `/`, which is undesirable inside a segment,
    /// so `/` is removed from the allowed set before encoding.
    ///
    /// Used by both ``OneLakeRequest`` and ``FabricClient`` (NIT-1: single
    /// shared copy to avoid maintenance divergence).
    var percentEncodedPathSegment: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
