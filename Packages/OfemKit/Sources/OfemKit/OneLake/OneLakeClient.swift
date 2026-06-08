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
/// Mirrors `internal/onelake/client.go` — `Client`.
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
    ///
    /// Mirrors `internal/onelake/client.go` — `defaultBaseURL`.
    public static let defaultBaseURL = URL(string: "https://onelake.dfs.fabric.microsoft.com")!

    /// Body size for a single append call. 4 MiB is well under Azure's
    /// per-append limit (100 MiB) and aligns with typical FS block sizes.
    ///
    /// Mirrors `internal/onelake/client.go` — `chunkSize`.
    static let chunkSize = 4 * 1024 * 1024

    /// Maximum pagination pages before giving up.
    ///
    /// Mirrors `internal/onelake/client.go` — `maxPaginationPages`.
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
    ///   - http: Shared ``HTTPClient`` (carries gate registry + retry policy).
    ///   - tokenProvider: Supplies bearer tokens for account aliases.
    ///   - baseURL: DFS endpoint. Default: ``defaultBaseURL``.
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
    ///
    /// Mirrors `internal/onelake/client.go` — `Client.ListPath`.
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
    ///
    /// Mirrors `internal/onelake/client.go` — `Client.GetProperties`.
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

    /// Downloads a file or a byte range from a file.
    ///
    /// Pass `range: nil` to download the entire file.
    /// Pass `ifMatch: ""` to skip the `If-Match` header.
    ///
    /// Returns the file body as `Data` together with the response headers
    /// parsed as ``PathProperties``. The caller does not need a follow-up
    /// HEAD request if it already issues a full GET.
    ///
    /// Mirrors `internal/onelake/client.go` — `Client.ReadWithIfMatch`.
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

    /// Uploads content to `path` using the DFS create + append + flush pattern.
    ///
    /// The body is consumed in 4 MiB chunks so memory use stays bounded
    /// regardless of file size.
    ///
    /// `size` must equal the number of bytes in `content`. If `content`
    /// supplies fewer bytes the call throws ``OneLakeError/shortRead(offset:)``.
    ///
    /// Mirrors `internal/onelake/client.go` — `Client.Write`.
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
        var pos: Int64 = 0
        var remaining = size
        let buf = content
        while remaining > 0 {
            let want = min(Int64(Self.chunkSize), remaining)
            let start = Int(pos)
            let end = Int(pos + want)
            guard end <= buf.count else {
                throw OneLakeError.shortRead(offset: pos)
            }
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

    // MARK: - CreateDirectory

    /// Creates a directory.
    ///
    /// Mirrors `internal/onelake/client.go` — `Client.CreateDirectory`.
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
    ///
    /// Mirrors `internal/onelake/client.go` — `Client.Delete`.
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

    /// Builds and executes a DFS request via ``HTTPClient``.
    ///
    /// Injects the `x-ms-version` header, acquires a bearer token for
    /// `alias`, and maps ``HTTPClientError`` to ``OneLakeError``.
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
        req.setValue("2021-08-06", forHTTPHeaderField: "x-ms-version")
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
///
/// Mirrors `internal/onelake/client.go` — `joinItemPath`.
private func joinItemPath(itemGUID: String, relPath: String) -> String {
    let trimmed = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmed.isEmpty {
        return itemGUID
    }
    return "\(itemGUID)/\(trimmed)"
}
