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

    /// Default body size for a single append call. 4 MiB is well under Azure's
    /// per-append limit (100 MiB) and aligns with typical FS block sizes.
    static let defaultChunkSize = 4 * 1024 * 1024

    /// Maximum pagination pages before giving up.
    static let maxPaginationPages = 1_000

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
    public init(
        sessionPool: SessionPool,
        baseURL: URL = OneLakeClient.defaultBaseURL,
        chunkSize: Int = 4 * 1024 * 1024,
        logger: OfemLogger = OfemLogger()
    ) {
        self.sessionPool = sessionPool
        self.baseURL = baseURL
        self.chunkSize = chunkSize
        self.logger = logger
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

        for page in 0..<Self.maxPaginationPages {
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

    /// Downloads a file or a byte range from a file, streaming the response
    /// body directly into `destination` without buffering the whole file in
    /// memory (net-19 / onelake-02: TRUE streaming via `URLSession.bytes`).
    ///
    /// This overload uses ``HTTPClient/download(_:to:tokenProvider:alias:scope:idempotent:)``
    /// under the hood, which writes bytes to `destination` as they arrive.
    /// On retry the destination is truncated and restarted so a partial write
    /// is never left on disk.
    ///
    /// Pass `range: nil` to download the entire file.
    /// Pass `ifMatch: ""` to skip the `If-Match` header.
    ///
    /// - Parameters:
    /// - destination: An open `FileHandle` (writable, positioned at offset 0)
    ///   that receives the response body bytes.
    /// - Returns: The response headers parsed as ``PathProperties``; the caller
    ///   does not need a follow-up HEAD request after a full GET.
    public func read(
        alias: String,
        workspaceGUID: String,
        itemGUID: String,
        path: String,
        range: Range<Int64>? = nil,
        ifMatch: String = "",
        destination: FileHandle
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
            destination: destination
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
            let end   = Int(pos + want)
            guard end <= buf.count else {
                throw OneLakeError.shortRead(offset: pos)
            }
            // Safe: buf.startIndex == 0 after normalisation above.
            let chunk = buf[start..<end]
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
    private func writeFromHandle(
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

    /// Executes a DFS request via the Alamofire session for `(alias, .oneLake)`.
    ///
    /// Injects the `x-ms-version` header and `Content-Length: 0` on bodyless
    /// mutating requests (onelake-07). Authentication, retry, and back-off are
    /// handled transparently by the session's interceptor stack.
    @discardableResult
    private func doRequest(
        alias: String,
        method: String,
        url: URL,
        body: Data?,
        extraHeaders: [String: String]?,
        idempotent: Bool  // retained for call-site documentation; session handles retry
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

        let session = await sessionPool.session(alias: alias, scope: .oneLake)
        let httpMethod = HTTPMethod(rawValue: method)
        do {
            let req = session.request(url, method: httpMethod, headers: headers) { urlRequest in
                urlRequest.httpBody = body
            }
            .validate()
            // net-01: Alamofire's default DataResponseSerializer treats an empty
            // body as an error unless the status code is 204/205 or the method is
            // HEAD.  ADLS Gen2 returns empty bodies on 200/201/202 for PUT create,
            // PATCH flush, DELETE, and 0-byte GET.  Listing all HTTP methods used
            // by this client as "empty-response-allowed" lets Alamofire return
            // Data() instead of AFError.responseSerializationFailed.  The
            // .validate() call above already rejects non-2xx, so this only relaxes
            // the body-length gate on successful responses.
            let dataResponse = await req.serializingData(
                emptyResponseMethods: [.get, .put, .patch, .delete, .post, .head]
            ).response
            switch dataResponse.result {
            case .success(let data):
                guard let httpResponse = dataResponse.response else {
                    throw HTTPClientError.transport(URLError(.badServerResponse))
                }
                return (data, httpResponse)
            case .failure(let afError):
                let mapped = HTTPClientError(
                    afError: afError,
                    response: dataResponse.response,
                    body: dataResponse.data,
                    retryCount: req.retryCount
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

    /// Downloads a DFS resource to a `FileHandle` without buffering all bytes
    /// in memory at once.
    ///
    /// Uses Alamofire `DownloadRequest` with a temporary-file destination.  Once
    /// the download completes, the temporary file is read in 64 KB chunks and
    /// forwarded into `fileHandle`, then the temporary file is removed.
    /// Injects the `x-ms-version` header and maps errors to ``OneLakeError``.
    private func doStreamRequest(
        alias: String,
        method: String,
        url: URL,
        extraHeaders: [String: String]?,
        destination fileHandle: FileHandle
    ) async throws -> HTTPURLResponse {
        var headers = HTTPHeaders()
        headers.add(name: "x-ms-version", value: oneLakeDFSAPIVersion)
        extraHeaders?.forEach { headers.add(name: $0, value: $1) }

        let session = await sessionPool.session(alias: alias, scope: .oneLake)
        let httpMethod = HTTPMethod(rawValue: method)

        // Alamofire DownloadRequest streams to a temporary file URL.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        let afDestination: DownloadRequest.Destination = { _, _ in
            (tmpURL, [.removePreviousFile, .createIntermediateDirectories])
        }

        do {
            let dl = session
                .download(url, method: httpMethod, headers: headers, to: afDestination)
                .validate()
            let result = await dl.serializingDownloadedFileURL().result
            guard let httpResponse = dl.response else {
                throw HTTPClientError.transport(URLError(.badServerResponse))
            }
            switch result {
            case .success(let fileURL):
                // Copy in 64 KB chunks so the FPE process does not map the
                // entire file into its address space at once.
                defer { try? FileManager.default.removeItem(at: fileURL) }
                let src = try FileHandle(forReadingFrom: fileURL)
                defer { try? src.close() }
                let chunkSize = 65_536
                while true {
                    let chunk = src.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    try fileHandle.write(contentsOf: chunk)
                }
                return httpResponse
            case .failure(let afError):
                try? FileManager.default.removeItem(at: tmpURL)
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
            if case .invalidURL(let msg) = urlErr {
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
