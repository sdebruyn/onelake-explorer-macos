import Alamofire
import Foundation
import os.log

// MARK: - OneLakeClient

/// HTTP client for the OneLake ADLS Gen2 DFS endpoint.
///
/// Wraps a ``SessionPool`` with OneLake-specific URL construction, header
/// injection, response decoding, and pagination.  Authentication and retry
/// are handled transparently by the Alamofire session returned from the pool.
///
/// All public methods are `async throws` and safe for concurrent use.
/// The client itself holds no mutable state.
///
/// ## Usage
///
/// ```swift
/// let client = OneLakeClient(sessionPool: myPool)
/// let listing = try await client.listPath(
///     alias: "work",
///     workspaceGUID: "...",
///     itemGUID: "...",
///     directory: "Files",
///     recursive: false
/// )
/// ```
public final class OneLakeClient: Sendable {
    // MARK: - Constants

    /// Default DFS endpoint.
    public static let defaultBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

    // periphery:ignore
    /// Default body size for a single append call. 4 MiB is well under Azure's
    /// per-append limit (100 MiB) and aligns with typical FS block sizes.
    static let defaultChunkSize = 4 * 1024 * 1024

    /// Maximum pagination pages before giving up.
    static let maxPaginationPages = 1000

    // MARK: - Shared decoder (onelake-05)

    /// Shared `JSONDecoder` for all response decoding.
    ///
    /// `JSONDecoder` is stateless after configuration, so a single instance
    /// shared across all pagination pages avoids repeated allocations (onelake-05).
    private static let decoder = JSONDecoder()

    // MARK: - Properties

    private let sessionPool: SessionPool
    private let baseURL: URL
    private let logger: OfemLogger
    /// Effective chunk size for append operations. Overridable in tests.
    let chunkSize: Int
    /// Directory ``doStreamRequest`` stages downloads in before copying them
    /// into the caller's destination handle. Defaults to the system temp
    /// directory; overridable in tests so a temp-file-leak assertion can
    /// scope to an isolated directory instead of racing other suites that
    /// scribble in the shared system temp dir under parallel test execution.
    let downloadTempDirectory: URL

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OneLakeClient")

    // MARK: - Initialisers

    /// Creates an `OneLakeClient`.
    ///
    /// - Parameters:
    ///   - sessionPool: Process-wide pool of Alamofire sessions. One session per
    ///     `(alias, .oneLake)` key is created lazily on first use.
    ///   - baseURL: DFS endpoint. Default: ``defaultBaseURL``.
    ///   - chunkSize: Maximum bytes per append PATCH. Defaults to 4 MiB.
    ///     Override in tests to exercise multi-chunk paths with small payloads.
    ///   - logger: Structured logger for debug request/pagination traces.
    ///     Defaults to an ``OfemLogger`` with default ``LogConfiguration`` so
    ///     existing call sites compile unchanged.
    ///   - downloadTempDirectory: Staging directory for ``doStreamRequest``.
    ///     Defaults to `FileManager.default.temporaryDirectory`. Override in
    ///     tests to assert no temp file leaks without scanning the shared
    ///     system temp dir.
    public init(
        sessionPool: SessionPool,
        baseURL: URL = OneLakeClient.defaultBaseURL,
        chunkSize: Int = 4 * 1024 * 1024,
        logger: OfemLogger = OfemLogger(),
        downloadTempDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.sessionPool = sessionPool
        self.baseURL = baseURL
        self.chunkSize = chunkSize
        self.logger = logger
        self.downloadTempDirectory = downloadTempDirectory
    }

    // MARK: - ListPath

    /// Enumerates a directory inside a OneLake item.
    ///
    /// If `recursive` is `true`, every descendant is returned in a single
    /// (paginated) stream. Pagination is fully resolved before returning.
    public func listPath(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        directory: String,
        recursive: Bool
    ) async throws -> ListResult {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }

        let dir = joinItemPath(itemGUID: itemGUID, relPath: directory)
        var out: [PathEntry] = []
        var continuation: String? = nil
        // onelake-11: track the full set of seen tokens to detect any cycle,
        // not just immediately repeated ones (A→B→A→B loops).
        var seenContinuations: Set<String> = []

        for page in 0 ..< Self.maxPaginationPages {
            // net-05: query values are percent-encoded via oneLakeListURL /
            // percentEncodedQueryItem so '+' in continuation tokens and
            // directory names is not decoded as a space by Azure.
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "resource", value: "filesystem"),
                URLQueryItem(name: "recursive", value: recursive ? "true" : "false"),
                URLQueryItem(name: "directory", value: dir),
            ]
            if let cont = continuation {
                queryItems.append(URLQueryItem(name: "continuation", value: cont))
            }

            let url = try buildURL { try oneLakeListURL(base: baseURL, workspaceGUID: workspaceGUID, query: queryItems) }
            // Count the non-empty path segments (excluding the workspaceGUID prefix)
            // as a safe, non-PII proxy for "how deep into the item are we listing".
            let pathSegments = dir.split(separator: "/").count
            logger.debug("onelake request", metadata: [
                "method": "GET",
                "endpoint": "listPath",
                "workspaceId": workspaceGUID,
                "itemId": itemGUID,
                "segments": "\(pathSegments)",
            ])
            let (data, response) = try await doRequest(
                alias: alias,
                method: "GET",
                url: url,
                body: nil,
                extraHeaders: nil,
                idempotent: true
            )
            logger.debug("onelake response", metadata: [
                "method": "GET",
                "endpoint": "listPath",
                "workspaceId": workspaceGUID,
                "itemId": itemGUID,
                "status": "\(response.statusCode)",
            ])

            let body: RawListBody
            do {
                body = try Self.decoder.decode(RawListBody.self, from: data)
            } catch {
                throw OneLakeError.decodeFailed(error)
            }

            // onelake-06: log any rejected headers at debug level.
            logRejectedHeaders(response)

            let nextCont = response.value(forHTTPHeaderField: "x-ms-continuation")
            let beforeCount = out.count
            for raw in body.paths ?? [] {
                // onelake-12: strip the itemGUID prefix so consumers get an
                // item-relative name rather than the raw workspace-rooted string.
                out.append(convertRawEntry(raw, itemGUID: itemGUID))
            }
            let pageItems = out.count - beforeCount

            guard let next = nextCont, !next.isEmpty else {
                logger.debug("onelake list page", metadata: [
                    "endpoint": "listPath",
                    "workspaceId": workspaceGUID,
                    "itemId": itemGUID,
                    "page": "\(page + 1)",
                    "itemsThisPage": "\(pageItems)",
                    "totalSoFar": "\(out.count)",
                    "hasContinuation": "false",
                ])
                logger.debug("onelake list complete", metadata: [
                    "endpoint": "listPath",
                    "workspaceId": workspaceGUID,
                    "itemId": itemGUID,
                    "totalPages": "\(page + 1)",
                    "totalItems": "\(out.count)",
                ])
                return ListResult(entries: out)
            }
            // onelake-11: detect any cycle (not just immediately adjacent tokens).
            if seenContinuations.contains(next) {
                throw OneLakeError.paginationExceeded(page)
            }
            seenContinuations.insert(next)
            continuation = next
            Self.log.debug("OneLakeClient: list page \(page + 1, privacy: .public), \(out.count, privacy: .public) entries so far")
            logger.debug("onelake list page", metadata: [
                "endpoint": "listPath",
                "workspaceId": workspaceGUID,
                "itemId": itemGUID,
                "page": "\(page + 1)",
                "itemsThisPage": "\(pageItems)",
                "totalSoFar": "\(out.count)",
                "hasContinuation": "true",
            ])
        }
        throw OneLakeError.paginationExceeded(Self.maxPaginationPages)
    }

    // MARK: - GetProperties

    /// Returns metadata for a single path (HEAD request).
    public func getProperties(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String
    ) async throws -> PathProperties {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        let url = try buildURL { try oneLakePathURL(base: baseURL, workspaceGUID: workspaceGUID, itemGUID: itemGUID, relPath: path) }
        let (_, response) = try await doRequest(
            alias: alias,
            method: "HEAD",
            url: url,
            body: nil,
            extraHeaders: nil,
            idempotent: true
        )
        logRejectedHeaders(response)
        return propertiesFromHeaders(response.allHeaderFields)
    }

    // MARK: - Read

    /// Downloads a file or a byte range from a file into `destination` without
    /// buffering the whole payload in process memory at once (net-19 / onelake-02).
    ///
    /// This overload uses ``doStreamRequest(alias:method:url:extraHeaders:destination:)``
    /// under the hood: Alamofire downloads the response body to a private temp
    /// file on disk, then the temp file is read back and copied into
    /// `destination` in 64 KB chunks. This is **not** true end-to-end
    /// streaming (`URLSession.bytes` writing straight into `destination` as
    /// bytes arrive) — every download transiently needs ~2x the file's size
    /// on disk (the temp file plus `destination`) and writes the payload
    /// twice. The temp file is always removed before this method returns or
    /// throws, on every exit path (M5 / #430). Genuine single-write
    /// streaming is a larger change and is tracked as a follow-up.
    ///
    /// Retries are handled by the session's interceptor stack (see
    /// ``SessionPool``); a retried request re-downloads from byte 0,
    /// overwriting the same staged temp file in place (Alamofire's
    /// `.removePreviousFile` destination option) — there is no `resumeData`
    /// reuse, so `destination` is never left with a partial write, but a
    /// retry after a large partial transfer re-pays the bytes already
    /// transferred.
    ///
    /// Pass `range: nil` to download the entire file.
    /// Pass `ifMatch: ""` to skip the `If-Match` header.
    ///
    /// - Parameters:
    /// - destination: An open `FileHandle` (writable, positioned at offset 0)
    ///   that receives the response body bytes.
    /// - onProgress: Optional incremental-progress callback (#461); default
    ///   `nil` leaves every existing caller byte-for-byte unchanged. See
    ///   ``doStreamRequest(alias:method:url:extraHeaders:destination:onProgress:)``
    ///   for exactly what `(completed, total)` mean.
    /// - Returns: The response headers parsed as ``PathProperties``; the caller
    ///   does not need a follow-up HEAD request after a full GET.
    public func read(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        range: Range<Int64>? = nil,
        ifMatch: String = "",
        destination: FileHandle,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> PathProperties {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        // onelake-10: guard against empty ranges that produce inverted headers.
        if let r = range, r.isEmpty {
            // Zero-length range — no bytes to fetch; return empty-body properties.
            return PathProperties(isDirectory: false, contentLength: 0, eTag: "", lastModified: .distantPast, contentType: "")
        }
        let url = try buildURL { try oneLakePathURL(base: baseURL, workspaceGUID: workspaceGUID, itemGUID: itemGUID, relPath: path) }
        var extra: [String: String] = [:]
        if let r = range {
            extra["Range"] = "bytes=\(r.lowerBound)-\(r.upperBound - 1)"
        }
        if !ifMatch.isEmpty {
            extra["If-Match"] = ifMatch
        }
        let response = try await doStreamRequest(
            alias: alias,
            method: "GET",
            url: url,
            extraHeaders: extra.isEmpty ? nil : extra,
            destination: destination,
            onProgress: onProgress
        )
        logRejectedHeaders(response)
        return propertiesFromHeaders(response.allHeaderFields)
    }

    /// Downloads a file or a byte range, returning the body as `Data`.
    ///
    /// Convenience overload for callers that require the raw bytes (e.g. small
    /// metadata payloads). For large files use
    /// ``read(alias:workspaceGUID:itemGUID:path:range:ifMatch:destination:)``
    /// to avoid buffering the entire response in memory.
    // periphery:ignore
    public func read(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        range: Range<Int64>? = nil,
        ifMatch: String = ""
    ) async throws -> (Data, PathProperties) {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        // onelake-10: guard against empty ranges.
        if let r = range, r.isEmpty {
            return (Data(), PathProperties(isDirectory: false, contentLength: 0, eTag: "", lastModified: .distantPast, contentType: ""))
        }
        let url = try buildURL { try oneLakePathURL(base: baseURL, workspaceGUID: workspaceGUID, itemGUID: itemGUID, relPath: path) }
        var extra: [String: String] = [:]
        if let r = range {
            extra["Range"] = "bytes=\(r.lowerBound)-\(r.upperBound - 1)"
        }
        if !ifMatch.isEmpty {
            extra["If-Match"] = ifMatch
        }
        let (data, response) = try await doRequest(
            alias: alias,
            method: "GET",
            url: url,
            body: nil,
            extraHeaders: extra.isEmpty ? nil : extra,
            idempotent: true
        )
        logRejectedHeaders(response)
        return (data, propertiesFromHeaders(response.allHeaderFields))
    }

    // MARK: - Write (Create + Append + Flush)

    /// Uploads content from a file URL to `path` using the DFS create + append
    /// + flush pattern.
    ///
    /// The file is read in 4 MiB chunks so memory use stays bounded regardless
    /// of file size (arch-07/net-10: streaming source rather than in-memory `Data`).
    ///
    /// - Parameters:
    /// - sourceURL: Local file URL to read upload content from.
    /// - size: Byte count to upload. Must equal the file size at `sourceURL`.
    ///   Throws ``OneLakeError/shortRead(offset:)`` if the file is shorter.
    public func write(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        sourceURL: URL,
        size: Int64
    ) async throws {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        guard !path.isEmpty else {
            throw OneLakeError.missingArgument("path required")
        }
        guard size >= 0 else {
            throw OneLakeError.missingArgument("size must be >= 0")
        }

        // Open the source file for reading.
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        try await writeFromHandle(
            alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID,
            path: path, handle: handle, size: size
        )
    }

    /// Uploads content from an in-memory `Data` buffer to `path` using the DFS
    /// create + append + flush pattern.
    ///
    /// Use this overload for small payloads (metadata, manifests). For large
    /// files prefer ``write(alias:workspaceGUID:itemGUID:path:sourceURL:size:)``
    /// which streams from a file without loading all bytes into memory.
    ///
    /// - Parameters:
    /// - content: The bytes to upload.
    /// - size: Must equal `content.count` (onelake-09: validated).
    // periphery:ignore
    public func write(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        content: Data,
        size: Int64
    ) async throws {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        guard !path.isEmpty else {
            throw OneLakeError.missingArgument("path required")
        }
        guard size >= 0 else {
            throw OneLakeError.missingArgument("size must be >= 0")
        }
        // onelake-09: validate the declared size matches the buffer so a caller
        // bug surfaces as a typed error rather than silent data loss.
        guard Int64(content.count) == size else {
            throw OneLakeError.missingArgument(
                "size \(size) does not match content.count \(content.count)"
            )
        }

        // Stage the upload at a temp sibling path and commit it via rename
        // (finding F11) — see writeFromHandle's doc comment for the rationale.
        let stagingPath = temporaryUploadPath(for: path)
        do {
            try await createAppendFlush(
                alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID,
                path: stagingPath, content: content, size: size
            )
            // See writeFromHandle's rename call for the lost-ack/retry
            // trade-off this shares (it applies to every upload, not just
            // the FileHandle-based one).
            try await rename(
                alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID,
                sourcePath: stagingPath, destinationPath: path
            )
        } catch {
            await cleanupStagingPath(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: stagingPath)
            throw error
        }
    }

    /// Performs the DFS create + chunked append + flush sequence for an
    /// in-memory buffer against `path`. Extracted so `write(content:size:)`
    /// can run it against a staging path and only expose `path` itself once
    /// the rename has committed.
    private func createAppendFlush(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        content: Data,
        size: Int64
    ) async throws {
        // 1. Create file.
        let createURL = try buildURL {
            try oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: [URLQueryItem(name: "resource", value: "file")]
            )
        }
        _ = try await doRequest(alias: alias, method: "PUT", url: createURL, body: nil, extraHeaders: nil, idempotent: true)

        // 2. Append in chunks.
        // net-11: normalise to a zero-based Data so chunk subscripting is safe
        // regardless of the buffer's startIndex (a Data slice preserves the
        // parent's indices; re-wrapping gives startIndex == 0).
        let buf = content.startIndex == 0 ? content : Data(content)
        var pos: Int64 = 0
        var remaining = size
        while remaining > 0 {
            let want = min(Int64(chunkSize), remaining)
            let start = Int(pos)
            let end = Int(pos + want)
            guard end <= buf.count else {
                throw OneLakeError.shortRead(offset: pos)
            }
            // Safe: buf.startIndex == 0 after normalisation above.
            let chunk = buf[start ..< end]
            let appendURL = try buildURL {
                try oneLakePathURL(
                    base: baseURL,
                    workspaceGUID: workspaceGUID,
                    itemGUID: itemGUID,
                    relPath: path,
                    query: [
                        URLQueryItem(name: "action", value: "append"),
                        URLQueryItem(name: "position", value: "\(pos)"),
                    ]
                )
            }
            _ = try await doRequest(
                alias: alias,
                method: "PATCH",
                url: appendURL,
                body: Data(chunk),
                extraHeaders: nil,
                idempotent: true // Position-addressed: replay is safe.
            )
            pos += want
            remaining -= want
        }

        // 3. Flush.
        try await doFlush(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path, size: size)
    }

    // MARK: - CreateDirectory

    /// Creates a directory.
    public func createDirectory(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String
    ) async throws {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        guard !path.isEmpty else {
            throw OneLakeError.missingArgument("path required")
        }
        let url = try buildURL {
            try oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: [URLQueryItem(name: "resource", value: "directory")]
            )
        }
        _ = try await doRequest(alias: alias, method: "PUT", url: url, body: nil, extraHeaders: nil, idempotent: true)
    }

    // MARK: - Rename

    /// Renames a file or directory within the same parent directory.
    ///
    /// Issues `PUT <destinationURL>` (the new path, same as a create URL but
    /// at the destination) with `x-ms-rename-source` set to the URL-encoded,
    /// leading-slash source path `/<workspaceGUID>/<itemGUID>/<sourcePath>`.
    /// The `Content-Length: 0` and `x-ms-version` headers are injected by
    /// `doRequest` (onelake-07). No request body.
    public func rename(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        sourcePath: String,
        destinationPath: String
    ) async throws {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        guard !sourcePath.isEmpty else {
            throw OneLakeError.missingArgument("sourcePath required")
        }
        guard !destinationPath.isEmpty else {
            throw OneLakeError.missingArgument("destinationPath required")
        }

        // x-ms-rename-source: URL-encoded "/<workspaceGUID>/<itemGUID>/<sourcePath>".
        // Derive it from the same oneLakePathURL helper used for the destination
        // so the per-segment encoding rule lives in exactly one place and cannot
        // drift (the source path is item-relative, so itemGUID is the second
        // segment just like the destination). `percentEncodedPath` is a property
        // of `URLComponents` (not `URL`), so decompose the built URL — this is the
        // faithful inverse of how oneLakePathURL composes it (it sets
        // `components.percentEncodedPath`), round-tripping the exact encoding the
        // rename API expects.
        let sourceURL = try buildURL {
            try oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: sourcePath
            )
        }
        guard let renameSource = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?
            .percentEncodedPath
        else {
            throw OneLakeURLError.invalidURL("Cannot extract rename-source path from: \(sourceURL.absoluteString)")
        }

        // ADLS Gen2 bounds the number of paths renamed per call for directory
        // renames and returns an `x-ms-continuation` *response* header when more
        // remain; that token must be re-sent on a subsequent invocation as the
        // `continuation` *query parameter* (per the Path - Create REST contract)
        // until exhausted. Without the loop a large directory is only partially
        // renamed server-side while the cache rewrites all descendants → permanent
        // divergence. Mirrors listDirectory's continuation handling, including its
        // cycle-detection guard (onelake-11). Note: unlike list (which sends the
        // token as a query param too), the token here is delivered as a header on
        // the response, so we re-issue with it as a query param on the next PUT.
        var continuation: String? = nil
        var seenContinuations: Set<String> = []
        for _ in 0 ..< Self.maxPaginationPages {
            // Destination URL: the new path (same shape as createDirectory),
            // plus the continuation query param on follow-up invocations.
            let destURL = try buildURL {
                var query: [URLQueryItem]? = nil
                if let cont = continuation {
                    query = [URLQueryItem(name: "continuation", value: cont)]
                }
                return try oneLakePathURL(
                    base: baseURL,
                    workspaceGUID: workspaceGUID,
                    itemGUID: itemGUID,
                    relPath: destinationPath,
                    query: query
                )
            }
            let (_, response) = try await doRequest(
                alias: alias,
                method: "PUT",
                url: destURL,
                body: nil,
                extraHeaders: ["x-ms-rename-source": renameSource],
                idempotent: true
            )
            guard let next = response.value(forHTTPHeaderField: "x-ms-continuation"),
                  !next.isEmpty
            else {
                return
            }
            if seenContinuations.contains(next) {
                throw OneLakeError.paginationExceeded(seenContinuations.count)
            }
            seenContinuations.insert(next)
            continuation = next
        }
        throw OneLakeError.paginationExceeded(Self.maxPaginationPages)
    }

    // MARK: - Delete

    /// Removes a file or directory.
    ///
    /// If `recursive` is `true`, all descendants are removed. Otherwise a
    /// non-empty directory yields a 409 from the server.
    public func delete(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        recursive: Bool = false
    ) async throws {
        guard !workspaceGUID.isEmpty, !itemGUID.isEmpty else {
            throw OneLakeError.missingArgument("workspaceGUID and itemGUID required")
        }
        guard !path.isEmpty else {
            throw OneLakeError.missingArgument("path required")
        }
        var query: [URLQueryItem] = []
        if recursive {
            query.append(URLQueryItem(name: "recursive", value: "true"))
        }
        let url = try buildURL {
            try oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: query.isEmpty ? nil : query
            )
        }
        _ = try await doRequest(alias: alias, method: "DELETE", url: url, body: nil, extraHeaders: nil, idempotent: true)
    }

    // MARK: - Private helpers

    /// Streams content from `handle` to the DFS endpoint in 4 MiB chunks.
    ///
    /// The file handle must be positioned at the start of the content to upload
    /// and must remain valid for the duration of the call.
    ///
    /// Stages the upload at a temp sibling path and commits it via rename
    /// (finding F11): creating directly at the live destination immediately
    /// truncates any existing content to 0 bytes (DFS create is a full
    /// overwrite; flush is a separate, later request). If the process or
    /// network dies after create but before flush — and the retry budget is
    /// exhausted — the destination is left committed at 0 bytes with the
    /// previous content permanently gone. Staging at a temp path in the same
    /// item/directory means the commit is a metadata-only rename, so an
    /// interrupted upload leaves the original destination untouched.
    private func writeFromHandle(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        handle: FileHandle,
        size: Int64
    ) async throws {
        let stagingPath = temporaryUploadPath(for: path)
        do {
            try await createAppendFlush(
                alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID,
                path: stagingPath, handle: handle, size: size
            )
            // Non-blocking trade-off, not specific to this call site but worth
            // flagging here since this rename now sits on the hot path of every
            // upload rather than just explicit renames: SessionPool's
            // RetryPolicy retries PUT on transport failures where no response
            // was received (lost connection, timeout, …). If this rename
            // actually landed server-side but the ack was lost, the retried PUT
            // re-sends the same `x-ms-rename-source: stagingPath` — but the
            // source is already gone, so the retry comes back
            // notFound/SourcePathNotFound and this call reports failure even
            // though the destination was committed correctly. Not data loss
            // (worst case: a spurious error plus a harmless redundant
            // re-upload, consistent with last-write-wins) — deliberately not
            // special-cased here; idempotent-retry handling belongs in the
            // shared retry/DELETE path, not duplicated per call site.
            try await rename(
                alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID,
                sourcePath: stagingPath, destinationPath: path
            )
        } catch {
            await cleanupStagingPath(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: stagingPath)
            throw error
        }
    }

    /// Performs the DFS create + chunked append + flush sequence, streaming
    /// from `handle`, against `path`. Extracted so `writeFromHandle` can run
    /// it against a staging path and only expose `path` itself once the
    /// rename has committed.
    private func createAppendFlush(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        handle: FileHandle,
        size: Int64
    ) async throws {
        // 1. Create file.
        let createURL = try buildURL {
            try oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: [URLQueryItem(name: "resource", value: "file")]
            )
        }
        _ = try await doRequest(alias: alias, method: "PUT", url: createURL, body: nil, extraHeaders: nil, idempotent: true)

        // 2. Append in chunks, reading from the handle.
        //
        // FileHandle.read(upToCount:) returns UP TO the requested count. A short
        // read is valid (e.g. kernel page boundary, network-backed volume) and must
        // not be treated as EOF. We accumulate until `want` bytes are received or
        // until the handle returns an empty read (true EOF / error), so the append
        // is always sent at the correct `position=` offset (blocker-3).
        var pos: Int64 = 0
        var remaining = size
        while remaining > 0 {
            let want = min(Int64(chunkSize), remaining)
            var chunk = Data()
            chunk.reserveCapacity(Int(want))
            while chunk.count < Int(want) {
                let needed = Int(want) - chunk.count
                let slice: Data
                do {
                    slice = try handle.read(upToCount: needed) ?? Data()
                } catch {
                    throw OneLakeError.shortRead(offset: pos + Int64(chunk.count))
                }
                guard !slice.isEmpty else {
                    // Genuine EOF before we accumulated `want` bytes.
                    throw OneLakeError.shortRead(offset: pos + Int64(chunk.count))
                }
                chunk.append(slice)
            }
            let appendURL = try buildURL {
                try oneLakePathURL(
                    base: baseURL,
                    workspaceGUID: workspaceGUID,
                    itemGUID: itemGUID,
                    relPath: path,
                    query: [
                        URLQueryItem(name: "action", value: "append"),
                        URLQueryItem(name: "position", value: "\(pos)"),
                    ]
                )
            }
            _ = try await doRequest(
                alias: alias,
                method: "PATCH",
                url: appendURL,
                body: chunk,
                extraHeaders: nil,
                idempotent: true // Position-addressed: replay is safe.
            )
            pos += Int64(chunk.count)
            remaining -= Int64(chunk.count)
        }

        // 3. Flush.
        try await doFlush(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path, size: size)
    }

    /// Issues the DFS flush PATCH for `path` at the given `size`.
    private func doFlush(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        size: Int64
    ) async throws {
        let flushURL = try buildURL {
            try oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: [
                    URLQueryItem(name: "action", value: "flush"),
                    URLQueryItem(name: "position", value: "\(size)"),
                ]
            )
        }
        _ = try await doRequest(alias: alias, method: "PATCH", url: flushURL, body: nil, extraHeaders: nil, idempotent: true)
    }

    // MARK: - Upload staging (finding F11)

    /// Derives a unique staging path in the same directory as `path`.
    ///
    /// The temp+rename dance needs a sibling within the same item so the
    /// commit is a metadata-only rename rather than a copy. ``isMacOSMetadata``
    /// treats every ``ofemUploadStagingPrefix``-prefixed name as hidden junk
    /// (the same way it already hides `._*` AppleDouble files), so a staging
    /// file caught mid-flight by a concurrent listing — or orphaned by a hard
    /// kill before the terminal rename — never surfaces in Finder. A UUID
    /// makes collisions with real content or a concurrent upload of the same
    /// file effectively impossible.
    private func temporaryUploadPath(for path: String) -> String {
        let uuid = UUID().uuidString
        guard let slash = path.lastIndex(of: "/") else {
            return "\(ofemUploadStagingPrefix)\(uuid)-\(path)"
        }
        let dir = path[path.startIndex ..< slash]
        let name = path[path.index(after: slash)...]
        return "\(dir)/\(ofemUploadStagingPrefix)\(uuid)-\(name)"
    }

    /// Best-effort removal of a staging file left behind by a failed upload.
    ///
    /// Never throws: a cleanup failure must not mask the original error that
    /// triggered it, and an orphaned staging file is harmless — it is never
    /// referenced by anything until the rename that never happened.
    private func cleanupStagingPath(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String
    ) async {
        do {
            try await delete(alias: alias, workspaceGUID: workspaceGUID, itemGUID: itemGUID, path: path)
        } catch {
            Self.log.debug("OneLakeClient: staging cleanup failed for \(path, privacy: .private): \(String(describing: error), privacy: .public)")
        }
    }

    /// Executes a DFS request via the Alamofire session for `(alias, .oneLake)`.
    ///
    /// Injects the `x-ms-version` header and `Content-Length: 0` on bodyless
    /// mutating requests (onelake-07). Authentication, retry, and back-off are
    /// handled transparently by the session's interceptor stack. Request
    /// execution and error mapping are shared with `FabricClient` via
    /// ``executeDataRequest(sessionPool:alias:scope:method:url:headers:body:idempotent:onFailure:mapError:)``
    /// (http-02).
    ///
    /// - Parameter idempotent: Forwarded to `executeDataRequest(idempotent:)`,
    ///   which threads it into `RetryAfterRetrier` as a per-request override —
    ///   every current call site passes `true`, since every current PATCH here
    ///   is position-addressed append/flush (see
    ///   `RetryAfterRetrier.idempotentHTTPMethods`), but a future non-idempotent
    ///   call can pass `false` to opt out of a Retry-After replay.
    @discardableResult
    private func doRequest(
        alias: String,
        method: String,
        url: URL,
        body: Data?,
        extraHeaders: [String: String]?,
        idempotent: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var headers = HTTPHeaders()
        headers.add(name: "x-ms-version", value: oneLakeDFSAPIVersion)
        if let b = body {
            headers.add(name: "Content-Length", value: "\(b.count)")
        } else if method == "PUT" || method == "PATCH" {
            // onelake-07: ADLS Gen2 expects an explicit Content-Length: 0 on
            // bodyless PUT/PATCH (create, flush, createDirectory).
            headers.add(name: "Content-Length", value: "0")
        }
        extraHeaders?.forEach { headers.add(name: $0, value: $1) }

        return try await executeDataRequest(
            sessionPool: sessionPool,
            alias: alias,
            scope: .oneLake,
            method: method,
            url: url,
            headers: headers,
            body: body,
            idempotent: idempotent,
            mapError: OneLakeError.from
        )
    }

    /// Downloads a DFS resource to a `FileHandle` without buffering the whole
    /// payload in process memory at once.
    ///
    /// Uses Alamofire `DownloadRequest` with a temporary-file destination. Once
    /// the download completes, the temporary file is read in 64 KB chunks and
    /// forwarded into `fileHandle`. This is download-to-temp-then-copy, not
    /// true streaming into `fileHandle` — see the doc on
    /// ``read(alias:workspaceGUID:itemGUID:path:range:ifMatch:destination:)``
    /// for the disk/write-amplification trade-off this implies.
    ///
    /// The temp file is removed on every exit path — success, the
    /// nil-response guard, the `.failure` branch, and any error thrown from
    /// the outer `do` block — via a single function-scope `defer` (M5 /
    /// #430: it used to leak on the nil-response guard and outer-catch
    /// paths).
    ///
    /// Injects the `x-ms-version` header and maps errors to ``OneLakeError``.
    ///
    /// - Note: retries (see ``SessionPool``) restart the download from byte
    ///   0, overwriting the same staged temp file in place
    ///   (`.removePreviousFile`); there is no `resumeData` reuse. A file
    ///   that fails late in the transfer re-pays the already-downloaded
    ///   bytes on retry. Wiring `DownloadRequest` resume-data through the
    ///   retry chain is tracked as a follow-up, out of scope for this fix.
    ///
    /// - Parameter onProgress: Optional, attached via `DownloadRequest.downloadProgress`
    ///   before the result is awaited (#461). Default `nil` is byte-for-byte
    ///   the prior behaviour — no `downloadProgress` handler is registered at all.
    private func doStreamRequest(
        alias: String,
        method: String,
        url: URL,
        extraHeaders: [String: String]?,
        destination fileHandle: FileHandle,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> HTTPURLResponse {
        var headers = HTTPHeaders()
        headers.add(name: "x-ms-version", value: oneLakeDFSAPIVersion)
        extraHeaders?.forEach { headers.add(name: $0, value: $1) }

        let session = await sessionPool.session(alias: alias, scope: .oneLake)
        let httpMethod = HTTPMethod(rawValue: method)

        // Alamofire DownloadRequest streams to a temporary file URL.
        let tmpURL = downloadTempDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        let afDestination: DownloadRequest.Destination = { _, _ in
            (tmpURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        // This defer is the single, unconditional cleanup site for every
        // exit path (success, nil-response guard, .failure branch, or an
        // error rethrown from an outer catch) — the temp file must never
        // leak (M5 / #430). Neither branch below removes tmpURL itself;
        // try? because the file may legitimately not exist yet (e.g. the
        // nil-response guard fires before Alamofire ever wrote anything).
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let dl = session
                .download(url, method: httpMethod, headers: headers, to: afDestination)
                .validate()
            if let onProgress {
                // Attached before awaiting the result below (onelake-progress-01).
                // completedUnitCount/totalUnitCount as reported by Alamofire for
                // THIS request only — a ranged/resumed request's totalUnitCount
                // is the remaining bytes, not the full file size; reconciling
                // that against the real file size is the caller's job (SyncEngine).
                _ = dl.downloadProgress { progress in
                    onProgress(progress.completedUnitCount, progress.totalUnitCount)
                }
            }
            let result = await dl.serializingDownloadedFileURL().result
            guard let httpResponse = dl.response else {
                throw HTTPClientError.transport(URLError(.badServerResponse))
            }
            switch result {
            case let .success(fileURL):
                // Copy in 64 KB chunks so the FPE process does not map the
                // entire file into its address space at once.
                let src = try FileHandle(forReadingFrom: fileURL)
                defer { try? src.close() }
                let chunkSize = 65536
                while true {
                    let chunk = src.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    try fileHandle.write(contentsOf: chunk)
                }
                return httpResponse
            case let .failure(afError):
                let mapped = HTTPClientError(
                    afError: afError,
                    response: httpResponse,
                    retryCount: dl.retryCount
                )
                throw OneLakeError.from(mapped)
            }
        } catch let oneLakeError as OneLakeError {
            throw oneLakeError
        } catch let afError as AFError {
            let mapped = HTTPClientError(afError: afError, response: nil, retryCount: 0)
            throw OneLakeError.from(mapped)
        } catch {
            throw OneLakeError.from(error)
        }
    }

    /// Translates a URL-builder closure result into either a URL or an
    /// ``OneLakeError/missingArgument(_:)`` (onelake-03: no force-unwraps).
    ///
    /// NIT-5: pattern-match on the associated value of `OneLakeURLError` directly
    /// so the message is the developer-authored string, not the generic
    /// `localizedDescription` ("The operation couldn't be completed").
    private func buildURL(_ build: () throws -> URL) throws -> URL {
        do {
            return try build()
        } catch let urlErr as OneLakeURLError {
            if case let .invalidURL(msg) = urlErr {
                throw OneLakeError.missingArgument(msg)
            }
            throw OneLakeError.missingArgument(urlErr.localizedDescription)
        }
    }

    /// Logs the `x-ms-rejected-headers` response header at debug level
    /// (onelake-06). Never fails; only logs.
    private func logRejectedHeaders(_ response: HTTPURLResponse) {
        guard let rejected = response.value(forHTTPHeaderField: "x-ms-rejected-headers"),
              !rejected.isEmpty else { return }
        Self.log.debug("OneLakeClient: x-ms-rejected-headers: \(rejected, privacy: .public)")
    }
}

// MARK: - joinItemPath

/// Joins an item-relative path onto the item GUID for use in list queries.
private func joinItemPath(itemGUID: String, relPath: String) -> String {
    let trimmed = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty {
        return itemGUID
    }
    return "\(itemGUID)/\(trimmed)"
}
