import Foundation
import os.log

// MARK: - OneLakeClient

/// HTTP client for the OneLake ADLS Gen2 DFS endpoint.
///
/// Wraps ``HTTPClient`` with OneLake-specific URL construction, header
/// injection, auth-token acquisition, response decoding, and pagination.
///
/// All public methods are `async throws` and safe for concurrent use.
/// The underlying ``HTTPClient`` and ``HTTPGateRegistry`` handle per-host
/// throttling and retry; the client itself holds no mutable state.
///
/// ## Usage
///
/// ```swift
/// let client = OneLakeClient(http: myHTTPClient, tokenProvider: myOfemAuth)
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

    /// Body size for a single append call. 4 MiB is well under Azure's
    /// per-append limit (100 MiB) and aligns with typical FS block sizes.
    static let chunkSize = 4 * 1024 * 1024

    /// Maximum pagination pages before giving up.
    static let maxPaginationPages = 1_000

    // MARK: - Properties

    private let http: HTTPClient
    private let tokenProvider: any TokenProvider
    private let baseURL: URL

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "OneLakeClient")

    // MARK: - Initialisers

    /// Creates an `OneLakeClient`.
    ///
    /// - Parameters:
    /// - http: Shared ``HTTPClient`` (carries gate registry + retry policy).
    /// - tokenProvider: Supplies bearer tokens for account aliases.
    /// - baseURL: DFS endpoint. Default: ``defaultBaseURL``.
    public init(
        http: HTTPClient,
        tokenProvider: any TokenProvider,
        baseURL: URL = OneLakeClient.defaultBaseURL
    ) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
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

            let url = oneLakeListURL(base: baseURL, workspaceGUID: workspaceGUID, query: queryItems)
            let (data, response) = try await doRequest(
                alias: alias,
                method: "GET",
                url: url,
                body: nil,
                extraHeaders: nil,
                idempotent: true
            )

            let body: RawListBody
            do {
                body = try JSONDecoder().decode(RawListBody.self, from: data)
            } catch {
                throw OneLakeError.decodeFailed(error)
            }

            let nextCont = response.value(forHTTPHeaderField: "x-ms-continuation")
            for raw in body.paths ?? [] {
                out.append(convertRawEntry(raw))
            }

            guard let next = nextCont, !next.isEmpty else {
                return ListResult(entries: out)
            }
            if next == continuation {
                throw OneLakeError.paginationExceeded(page)
            }
            continuation = next
            Self.log.debug("OneLakeClient: list page \(page + 1, privacy: .public), \(out.count, privacy: .public) entries so far")
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
        let url = oneLakePathURL(base: baseURL, workspaceGUID: workspaceGUID, itemGUID: itemGUID, relPath: path)
        let (_, response) = try await doRequest(
            alias: alias,
            method: "HEAD",
            url: url,
            body: nil,
            extraHeaders: nil,
            idempotent: true
        )
        return propertiesFromHeaders(response.allHeaderFields)
    }

    // MARK: - Read

    /// Downloads a file or a byte range from a file, writing the response body
    /// into `destination`.
    ///
    /// The response body is received via the standard ``HTTPClient`` path and
    /// appended to `destination` using the throwing ``FileHandle/write(contentsOf:)``
    /// API so disk-full surfaces as a typed error rather than an ObjC exception.
    ///
    /// Pass `range: nil` to download the entire file.
    /// Pass `ifMatch: ""` to skip the `If-Match` header.
    ///
    /// - Parameters:
    /// - destination: An open `FileHandle` (writable, positioned at the write
    ///   offset) that receives the response body bytes.
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
        let url = oneLakePathURL(base: baseURL, workspaceGUID: workspaceGUID, itemGUID: itemGUID, relPath: path)
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
        // Write the response bytes into the caller-provided handle using the
        // throwing variant so disk-full surfaces as a typed Swift error.
        try destination.write(contentsOf: data)
        return propertiesFromHeaders(response.allHeaderFields)
    }

    /// Downloads a file or a byte range, returning the body as `Data`.
    ///
    /// Convenience overload for callers that require the raw bytes (e.g. small
    /// metadata payloads). For large files use ``read(alias:workspaceGUID:itemGUID:path:range:ifMatch:destination:)``
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
        let url = oneLakePathURL(base: baseURL, workspaceGUID: workspaceGUID, itemGUID: itemGUID, relPath: path)
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
    /// - content: The bytes to upload. Must contain exactly `size` bytes.
    /// - size: Must equal `content.count`.
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

        // 1. Create file.
        let createURL = oneLakePathURL(
            base: baseURL,
            workspaceGUID: workspaceGUID,
            itemGUID: itemGUID,
            relPath: path,
            query: [URLQueryItem(name: "resource", value: "file")]
        )
        _ = try await doRequest(alias: alias, method: "PUT", url: createURL, body: nil, extraHeaders: nil, idempotent: true)

        // 2. Append in chunks.
        // net-11: normalise to a zero-based Data so chunk subscripting is safe
        // regardless of the buffer's startIndex (a Data slice preserves the
        // parent's indices; re-wrapping gives startIndex == 0).
        let buf = content.startIndex == 0 ? content : Data(content)
        var pos: Int64 = 0
        var remaining = size
        while remaining > 0 {
            let want = min(Int64(Self.chunkSize), remaining)
            let start = Int(pos)
            let end   = Int(pos + want)
            guard end <= buf.count else {
                throw OneLakeError.shortRead(offset: pos)
            }
            // Safe: buf.startIndex == 0 after normalisation above.
            let chunk = buf[start..<end]
            let appendURL = oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: [
                    URLQueryItem(name: "action", value: "append"),
                    URLQueryItem(name: "position", value: "\(pos)"),
                ]
            )
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
        let url = oneLakePathURL(
            base: baseURL,
            workspaceGUID: workspaceGUID,
            itemGUID: itemGUID,
            relPath: path,
            query: [URLQueryItem(name: "resource", value: "directory")]
        )
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
        let url = oneLakePathURL(
            base: baseURL,
            workspaceGUID: workspaceGUID,
            itemGUID: itemGUID,
            relPath: path,
            query: query.isEmpty ? nil : query
        )
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
        let createURL = oneLakePathURL(
            base: baseURL,
            workspaceGUID: workspaceGUID,
            itemGUID: itemGUID,
            relPath: path,
            query: [URLQueryItem(name: "resource", value: "file")]
        )
        _ = try await doRequest(alias: alias, method: "PUT", url: createURL, body: nil, extraHeaders: nil, idempotent: true)

        // 2. Append in chunks, reading from the handle.
        var pos: Int64 = 0
        var remaining = size
        while remaining > 0 {
            let want = min(Int64(Self.chunkSize), remaining)
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: Int(want)) ?? Data()
            } catch {
                throw OneLakeError.shortRead(offset: pos)
            }
            guard !chunk.isEmpty else {
                throw OneLakeError.shortRead(offset: pos)
            }
            let appendURL = oneLakePathURL(
                base: baseURL,
                workspaceGUID: workspaceGUID,
                itemGUID: itemGUID,
                relPath: path,
                query: [
                    URLQueryItem(name: "action", value: "append"),
                    URLQueryItem(name: "position", value: "\(pos)"),
                ]
            )
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
        let flushURL = oneLakePathURL(
            base: baseURL,
            workspaceGUID: workspaceGUID,
            itemGUID: itemGUID,
            relPath: path,
            query: [
                URLQueryItem(name: "action", value: "flush"),
                URLQueryItem(name: "position", value: "\(size)"),
            ]
        )
        _ = try await doRequest(alias: alias, method: "PATCH", url: flushURL, body: nil, extraHeaders: nil, idempotent: true)
    }

    /// Builds and executes a DFS request via ``HTTPClient``.
    ///
    /// Injects the `x-ms-version` header (using the single ``oneLakeDFSAPIVersion``
    /// constant — net-17: the dead `oneLakeVersionHeader()` helper has been removed),
    /// acquires a bearer token for `alias`, and maps ``HTTPClientError`` to
    /// ``OneLakeError``.
    @discardableResult
    private func doRequest(
        alias: String,
        method: String,
        url: URL,
        body: Data?,
        extraHeaders: [String: String]?,
        idempotent: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(oneLakeDFSAPIVersion, forHTTPHeaderField: "x-ms-version")
        if let b = body {
            req.httpBody = b
            req.setValue("\(b.count)", forHTTPHeaderField: "Content-Length")
        }
        extraHeaders?.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        do {
            return try await http.execute(
                req,
                tokenProvider: tokenProvider,
                alias: alias,
                scope: .oneLake,
                idempotent: idempotent
            )
        } catch {
            throw OneLakeError.from(error)
        }
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
