import Foundation

// MARK: - ResumePlan (sync-09/sync-23)

/// Describes the resume strategy for a single download attempt.
///
/// Extracting these three correlated values into a value type eliminates the
/// ad-hoc mutable locals in `performDownload` and makes the 412-reset atomic
/// and independently testable (sync-09). The unit test for the 412 path now
/// drives the real reset logic rather than re-implementing it (sync-23).
struct ResumePlan {
    // MARK: - Cases

    /// Start from the beginning of the file with no `Range` or `If-Match`
    /// header.
    static let fullRestart = ResumePlan(rangeStart: 0, pinnedEtag: nil, hasPartial: false)

    // MARK: - State

    /// Byte offset to resume from. Zero when `hasPartial` is `false`.
    let rangeStart: Int64

    /// ETag the spill file is pinned to. `nil` when not resuming.
    let pinnedEtag: String?

    /// `true` when a partial spill file exists at the resume offset.
    let hasPartial: Bool

    // MARK: - Derived

    /// The `Range` header value for the download request, or `nil` for a full
    /// download.
    var range: Range<Int64>? {
        hasPartial ? rangeStart ..< Int64.max : nil
    }

    /// The `If-Match` header value for the download request.
    var ifMatch: String {
        pinnedEtag ?? ""
    }
}

// MARK: - CacheKey stable serialisation (sync-11)

extension CacheKey {
    /// A stable, NUL-separated serialisation of the four key fields used as a
    /// dictionary key for coalescing and spill-file naming.
    ///
    /// The field order is fixed: `alias\0workspaceID\0itemID\0path`.
    /// Both ``SyncEngine`` (in-flight coalescing map) and ``PartialManager``
    /// (spill-file SHA name) must use this property so a field-order change
    /// can only be made in one place.
    var stableKeyString: String {
        "\(accountAlias)\0\(workspaceID)\0\(itemID)\0\(path)"
    }
}
