import Foundation
import GRDB

// MARK: - CacheKey

/// Uniquely identifies a metadata row. The four components together form the
/// SQLite primary key for `path_metadata`.
public struct CacheKey: Hashable, Sendable {
    /// The user-chosen short name for the signed-in account (e.g. `"work"`).
    public var accountAlias: String

    /// The Fabric workspace GUID owning the item.
    public var workspaceID: String

    /// The Fabric item GUID (lakehouse, warehouse, etc.) the path is rooted in.
    public var itemID: String

    /// The POSIX path relative to the item root. No leading `"/"`.
    /// Use `""` for the item root itself.
    public var path: String

    public init(accountAlias: String, workspaceID: String, itemID: String, path: String) {
        self.accountAlias = accountAlias
        self.workspaceID = workspaceID
        self.itemID = itemID
        self.path = path
    }
}

// MARK: - MetadataRecord

/// Full metadata row for one path in the `path_metadata` table.
///
/// Time fields stored as Unix nanoseconds (`Int64`) in SQLite; zero means
/// "unset". All `Date` values use UTC.
public struct MetadataRecord: FetchableRecord, PersistableRecord, Sendable {
    // MARK: Table name

    public static let databaseTableName = "path_metadata"

    // MARK: Column names (match schema exactly)

    public enum Columns {
        public static let accountAlias = Column("account_alias")
        public static let workspaceID = Column("workspace_id")
        public static let itemID = Column("item_id")
        public static let path = Column("path")
        public static let parentPath = Column("parent_path")
        public static let name = Column("name")
        public static let isDir = Column("is_dir")
        public static let contentLength = Column("content_length")
        public static let etag = Column("etag")
        public static let lastModifiedNs = Column("last_modified_ns")
        public static let contentType = Column("content_type")
        public static let blobSHA256 = Column("blob_sha256")
        public static let blobSize = Column("blob_size")
        public static let lastAccessedNs = Column("last_accessed_ns")
        public static let syncedAtNs = Column("synced_at_ns")
        public static let childrenSyncedAtNs = Column("children_synced_at_ns")
        public static let itemType = Column("item_type")
        public static let createdNs = Column("created_ns")
    }

    // MARK: Fields

    /// Account alias component of the primary key.
    public var accountAlias: String

    /// Workspace GUID component of the primary key.
    public var workspaceID: String

    /// Item GUID component of the primary key.
    public var itemID: String

    /// POSIX path relative to item root (no leading `"/"`). `""` = item root.
    public var path: String

    /// POSIX path of the containing directory. `""` when at item root.
    public var parentPath: String

    /// Final segment of `path` (or the item alias for roots).
    public var name: String

    /// `true` when the entry is a directory or container.
    public var isDir: Bool

    /// Remote-reported size in bytes. Zero for directories.
    public var contentLength: Int64

    /// OneLake / ADLS Gen2 entity tag, or `""` when unknown.
    public var etag: String

    /// Remote last-modified timestamp as Unix nanoseconds. Zero = unknown.
    public var lastModifiedNs: Int64

    /// MIME type reported by the remote, or `""` when unknown.
    public var contentType: String

    /// Lowercase hex SHA-256 of the locally cached blob, or `""` when uncached.
    public var blobSHA256: String

    /// Size in bytes of the locally cached blob. Zero when uncached.
    public var blobSize: Int64

    /// Unix nanoseconds of the last cache hit. Used for LRU eviction.
    public var lastAccessedNs: Int64

    /// Unix nanoseconds at which this row was last reconciled with the remote.
    public var syncedAtNs: Int64

    /// Unix nanoseconds at which this directory's children were last listed.
    /// Zero = "never listed"; always zero for non-directory rows.
    public var childrenSyncedAtNs: Int64

    /// Fabric item type (e.g. `"Lakehouse"`, `"Warehouse"`, `"SQLDatabase"`,
    /// `"MirroredDatabase"`). Empty string for virtual rows (workspace and
    /// root sentinels) and for items not yet enumerated by the sync engine.
    /// An empty value is treated as read-only by `DomainItem.computeCapabilities`.
    public var itemType: String

    /// Remote creation timestamp as Unix nanoseconds. Zero = unknown.
    public var createdNs: Int64

    // MARK: Computed helpers

    /// `lastModifiedNs` as a `Date`. `nil` when zero.
    public var lastModified: Date? {
        nsToDate(lastModifiedNs)
    }

    /// `createdNs` as a `Date`. `nil` when zero.
    public var created: Date? {
        nsToDate(createdNs)
    }

    // periphery:ignore
    /// `lastAccessedNs` as a `Date`. `nil` when zero.
    public var lastAccessed: Date? {
        nsToDate(lastAccessedNs)
    }

    /// `syncedAtNs` as a `Date`. `nil` when zero.
    public var syncedAt: Date? {
        nsToDate(syncedAtNs)
    }

    /// `childrenSyncedAtNs` as a `Date`. `nil` when zero.
    public var childrenSyncedAt: Date? {
        nsToDate(childrenSyncedAtNs)
    }

    // MARK: Initialisers

    /// Full memberwise initialiser.
    public init(
        accountAlias: String,
        workspaceID: String,
        itemID: String,
        path: String,
        parentPath: String,
        name: String,
        isDir: Bool,
        contentLength: Int64 = 0,
        etag: String = "",
        lastModifiedNs: Int64 = 0,
        contentType: String = "",
        blobSHA256: String = "",
        blobSize: Int64 = 0,
        lastAccessedNs: Int64 = 0,
        syncedAtNs: Int64 = 0,
        childrenSyncedAtNs: Int64 = 0,
        itemType: String = "",
        createdNs: Int64 = 0
    ) {
        self.accountAlias = accountAlias
        self.workspaceID = workspaceID
        self.itemID = itemID
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.isDir = isDir
        self.contentLength = contentLength
        self.etag = etag
        self.lastModifiedNs = lastModifiedNs
        self.contentType = contentType
        self.blobSHA256 = blobSHA256
        self.blobSize = blobSize
        self.lastAccessedNs = lastAccessedNs
        self.syncedAtNs = syncedAtNs
        self.childrenSyncedAtNs = childrenSyncedAtNs
        self.itemType = itemType
        self.createdNs = createdNs
    }

    // MARK: FetchableRecord

    public init(row: Row) throws {
        accountAlias = row[Columns.accountAlias]
        workspaceID = row[Columns.workspaceID]
        itemID = row[Columns.itemID]
        path = row[Columns.path]
        parentPath = row[Columns.parentPath]
        name = row[Columns.name]
        isDir = (row[Columns.isDir] as? Int64 ?? 0) != 0
        contentLength = row[Columns.contentLength]
        etag = row[Columns.etag]
        lastModifiedNs = row[Columns.lastModifiedNs]
        contentType = row[Columns.contentType]
        blobSHA256 = row[Columns.blobSHA256]
        blobSize = row[Columns.blobSize]
        lastAccessedNs = row[Columns.lastAccessedNs]
        syncedAtNs = row[Columns.syncedAtNs]
        childrenSyncedAtNs = row[Columns.childrenSyncedAtNs]
        itemType = row[Columns.itemType] ?? ""
        createdNs = row[Columns.createdNs] ?? 0
    }

    // MARK: PersistableRecord

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.accountAlias] = accountAlias
        container[Columns.workspaceID] = workspaceID
        container[Columns.itemID] = itemID
        container[Columns.path] = path
        container[Columns.parentPath] = parentPath
        container[Columns.name] = name
        container[Columns.isDir] = isDir ? 1 : 0
        container[Columns.contentLength] = contentLength
        container[Columns.etag] = etag
        container[Columns.lastModifiedNs] = lastModifiedNs
        container[Columns.contentType] = contentType
        container[Columns.blobSHA256] = blobSHA256
        container[Columns.blobSize] = blobSize
        container[Columns.lastAccessedNs] = lastAccessedNs
        container[Columns.syncedAtNs] = syncedAtNs
        container[Columns.childrenSyncedAtNs] = childrenSyncedAtNs
        container[Columns.itemType] = itemType
        container[Columns.createdNs] = createdNs
    }
}

// MARK: - WorkspaceStatusRecord

/// Persisted view of one workspace's availability in the `workspace_status` table.
public struct WorkspaceStatusRecord: FetchableRecord, PersistableRecord, Sendable {
    // MARK: Table name

    public static let databaseTableName = "workspace_status"

    // MARK: WorkspaceState

    /// Persisted workspace availability state.
    public enum State: String, Sendable {
        /// The workspace is reachable. Default state.
        case active
        /// The Fabric capacity is paused; the workspace cannot accept reads/writes.
        case paused
    }

    // MARK: Column names (match schema exactly)

    public enum Columns {
        public static let accountAlias = Column("account_alias")
        public static let workspaceID = Column("workspace_id")
        public static let state = Column("state")
        public static let reason = Column("reason")
        public static let detectedAtNs = Column("detected_at_ns")
        public static let probedAtNs = Column("probed_at_ns")
    }

    // MARK: Fields

    public var accountAlias: String
    public var workspaceID: String
    public var state: State
    /// Short machine-friendly description of why the workspace is in this state.
    /// Empty when state is `.active`.
    public var reason: String
    /// Unix nanoseconds when the state was first observed (or last transitioned into).
    public var detectedAtNs: Int64
    /// Unix nanoseconds of the last recovery probe. Zero when no probe has run.
    public var probedAtNs: Int64

    // MARK: Computed helpers

    // periphery:ignore
    public var detectedAt: Date? {
        nsToDate(detectedAtNs)
    }

    public var probedAt: Date? {
        nsToDate(probedAtNs)
    }

    // MARK: Initialisers

    public init(
        accountAlias: String,
        workspaceID: String,
        state: State = .active,
        reason: String = "",
        detectedAtNs: Int64 = 0,
        probedAtNs: Int64 = 0
    ) {
        self.accountAlias = accountAlias
        self.workspaceID = workspaceID
        self.state = state
        self.reason = reason
        self.detectedAtNs = detectedAtNs
        self.probedAtNs = probedAtNs
    }

    // MARK: FetchableRecord

    public init(row: Row) throws {
        accountAlias = row[Columns.accountAlias]
        workspaceID = row[Columns.workspaceID]
        let stateRaw: String = row[Columns.state]
        state = State(rawValue: stateRaw) ?? .active
        reason = row[Columns.reason]
        detectedAtNs = row[Columns.detectedAtNs]
        probedAtNs = row[Columns.probedAtNs]
    }

    // MARK: PersistableRecord

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.accountAlias] = accountAlias
        container[Columns.workspaceID] = workspaceID
        container[Columns.state] = state.rawValue
        container[Columns.reason] = reason
        container[Columns.detectedAtNs] = detectedAtNs
        container[Columns.probedAtNs] = probedAtNs
    }
}

// MARK: - DeletionTombstoneRecord

/// A soft-delete log row recording that an item was removed during remote
/// reconciliation.
///
/// `refreshFolder` writes one row here before hard-deleting from
/// `path_metadata`.  `itemsChangedAfter` queries this table to return
/// deleted identifier strings so `enumerateChanges` can call
/// `didDeleteItems(withIdentifiers:)` and Finder reflects the removal.
public struct DeletionTombstoneRecord: FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "deletion_tombstones"

    public enum Columns {
        public static let accountAlias = Column("account_alias")
        public static let identifierString = Column("identifier_string")
        public static let deletedAtNs = Column("deleted_at_ns")
    }

    /// The account alias for this item.
    public var accountAlias: String
    /// The opaque `ItemIdentifier.identifierString` for the deleted item.
    public var identifierString: String
    /// Unix nanoseconds at which the deletion was recorded.
    public var deletedAtNs: Int64

    public init(accountAlias: String, identifierString: String, deletedAtNs: Int64) {
        self.accountAlias = accountAlias
        self.identifierString = identifierString
        self.deletedAtNs = deletedAtNs
    }

    public init(row: Row) throws {
        accountAlias = row[Columns.accountAlias]
        identifierString = row[Columns.identifierString]
        deletedAtNs = row[Columns.deletedAtNs]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.accountAlias] = accountAlias
        container[Columns.identifierString] = identifierString
        container[Columns.deletedAtNs] = deletedAtNs
    }
}

// MARK: - MaterializedContainerRecord

/// One row in the `materialized_containers` table.
///
/// Tracks the set of containers that are locally materialized (have been
/// expanded by the user in Finder), keyed by the opaque
/// `ItemIdentifier.identifierString`. The FPE's
/// `materializedItemsDidChange(completionHandler:)` callback writes this table
/// via a full-replace reconcile so the freshness poll loop (a follow-up PR)
/// knows which containers to keep fresh.
///
/// The `identifier_string` is stored verbatim (the opaque string produced by
/// ``ItemIdentifier/identifierString``). Re-parsing to a ``CacheKey`` is done
/// in ``CacheReader/materializedContainers(alias:)``.
public struct MaterializedContainerRecord: FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "materialized_containers"

    public enum Columns {
        public static let accountAlias = Column("account_alias")
        public static let identifierString = Column("identifier_string")
        public static let materializedAtNs = Column("materialized_at_ns")
    }

    /// Account alias this row belongs to.
    public var accountAlias: String
    /// Opaque `ItemIdentifier.identifierString` for the materialized container.
    public var identifierString: String
    /// Unix nanoseconds at which this entry was recorded. Used for diagnostics.
    public var materializedAtNs: Int64

    public init(accountAlias: String, identifierString: String, materializedAtNs: Int64) {
        self.accountAlias = accountAlias
        self.identifierString = identifierString
        self.materializedAtNs = materializedAtNs
    }

    public init(row: Row) throws {
        accountAlias = row[Columns.accountAlias]
        identifierString = row[Columns.identifierString]
        materializedAtNs = row[Columns.materializedAtNs]
    }

    public func encode(to container: inout PersistenceContainer) {
        container[Columns.accountAlias] = accountAlias
        container[Columns.identifierString] = identifierString
        container[Columns.materializedAtNs] = materializedAtNs
    }
}

// MARK: - Private helpers

/// Converts Unix nanoseconds to `Date`. Returns `nil` for zero (= "unset").
func nsToDate(_ ns: Int64) -> Date? {
    guard ns != 0 else { return nil }
    return Date(timeIntervalSince1970: Double(ns) / 1_000_000_000)
}

/// Converts a `Date` to Unix nanoseconds. Returns `0` for `nil` (= "unset").
///
/// Out-of-range dates (e.g. `.distantPast`, `.distantFuture`) are clamped to `0`
/// so that a container carrying `.distantPast` never causes an `Int64` overflow trap.
func dateToNs(_ date: Date?) -> Int64 {
    guard let d = date else { return 0 }
    let ns = d.timeIntervalSince1970 * 1_000_000_000
    guard ns >= Double(Int64.min), ns <= Double(Int64.max) else { return 0 }
    return Int64(ns)
}
