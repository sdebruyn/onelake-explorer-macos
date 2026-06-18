import Foundation
import os.log

// MARK: - FabricClient

/// HTTP client for the Microsoft Fabric REST API
/// (`https://api.fabric.microsoft.com`).
///
/// OFEM uses this client for discovery only — listing workspaces, items,
/// and workspace-folders, plus fetching a single item's metadata. File I/O
/// happens through ``OneLakeClient`` against the DFS endpoint.
///
/// `FabricClient` wraps ``HTTPClient`` with Fabric-specific URL construction,
/// bearer-token injection for the Fabric audience, response decoding, and
/// two-branch pagination (``continuationToken`` or ``continuationUri``).
///
/// All public methods are `async throws` and safe for concurrent use.
/// The underlying ``HTTPClient`` and ``HTTPGateRegistry`` handle per-host
/// throttling and retry; the client itself holds no mutable state.
///
/// ## Usage
///
/// ```swift
/// let client = FabricClient(http: myHTTPClient, tokenProvider: myOfemAuth)
/// let workspaces = try await client.listAllWorkspaces(alias: "work")
/// ```
public final class FabricClient: Sendable {
    // MARK: - Constants

    /// Maximum pagination pages before giving up.
    ///
    /// Cheap insurance against a misbehaving server that keeps returning a
    /// non-empty continuation forever.
    static let maxPaginationPages = 1_000

    // MARK: - Shared decoder (onelake-05 / fabric)

    /// Shared `JSONDecoder` for all response decoding.
    ///
    /// A single instance avoids repeated allocations across pagination pages.
    private static let decoder = JSONDecoder()

    // MARK: - Properties

    private let http: HTTPClient
    private let tokenProvider: any TokenProvider
    private let baseURL: URL
    private let logger: OfemLogger

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "FabricClient")

    // MARK: - Initialisers

    /// Creates a `FabricClient`.
    ///
    /// - Parameters:
    /// - http: Shared ``HTTPClient`` (carries gate registry + retry policy).
    /// - tokenProvider: Supplies bearer tokens for account aliases.
    /// - baseURL: Fabric REST endpoint. Default: `https://api.fabric.microsoft.com`.
    /// - logger: Structured logger for debug request/pagination traces.
    ///   Defaults to an ``OfemLogger`` with default ``LogConfiguration`` so
    ///   existing call sites compile unchanged.
    public init(
        http: HTTPClient,
        tokenProvider: any TokenProvider,
        baseURL: URL = fabricDefaultBaseURL,
        logger: OfemLogger = OfemLogger()
    ) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        self.logger = logger
    }

    // MARK: - Workspace operations

    /// Returns a single page of workspaces.
    ///
    /// Use ``listAllWorkspaces(alias:)`` when you need the full list.
    ///
    /// - Parameters:
    /// - alias: Account alias to acquire the Fabric bearer token for.
    /// - continuation: Opaque continuation token from the previous page;
    ///   pass `nil` for the first page.
    /// - Returns: A ``WorkspacePage`` with items and an optional next token.
    ///   When the server returns only a `continuationUri` (no token), the page's
    ///   `continuationToken` is `nil` but `hasContinuation` is `true`; use
    ///   ``listAllWorkspaces(alias:)`` to follow both continuation forms
    ///   exhaustively (net-12 / fabric-04).
    /// - Throws: ``FabricError`` on failure.
    public func listWorkspaces(
        alias: String,
        continuation: String? = nil
    ) async throws -> WorkspacePage {
        let url = try fabricListURL(base: baseURL, path: "/v1/workspaces", continuationToken: continuation)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        do {
            let page = try Self.decoder.decode(FabricPageResponse<WireWorkspace>.self, from: data)
            let tok = page.continuationToken.flatMap { $0.isEmpty ? nil : $0 }
            let hasMore = tok != nil || (page.continuationUri.map { !$0.isEmpty } ?? false)
            return WorkspacePage(
                items: page.value.compactMap { $0.toWorkspace() },
                continuationToken: tok,
                hasContinuation: hasMore
            )
        } catch {
            throw FabricError.decodeFailed(error)
        }
    }

    /// Returns every workspace the principal can see, following pagination to
    /// the end automatically.
    ///
    /// - Parameter alias: Account alias to acquire the Fabric bearer token for.
    /// - Returns: All workspaces, accumulated across all pages.
    /// - Throws: ``FabricError`` on failure, including
    /// ``FabricError/paginationExceeded(_:)`` and
    /// ``FabricError/loopingPagination(_:)`` as safety guards.
    public func listAllWorkspaces(alias: String) async throws -> [Workspace] {
        try await listAllPages(alias: alias, path: "/v1/workspaces") { (wire: WireWorkspace) in
            wire.toWorkspace()
        }
    }

    // MARK: - Item operations

    /// Returns a single page of items inside a workspace.
    ///
    /// Use ``listAllItems(alias:workspaceID:)`` for the full list.
    ///
    /// - Parameters:
    /// - alias: Account alias.
    /// - workspaceID: The workspace to query. Must not be empty.
    /// - continuation: Opaque continuation token; `nil` for the first page.
    /// - Returns: An ``ItemPage``.
    /// - Throws: ``FabricError/missingArgument(_:)`` when `workspaceID` is
    /// empty; ``FabricError`` on network failure.
    public func listItems(
        alias: String,
        workspaceID: String,
        continuation: String? = nil
    ) async throws -> ItemPage {
        guard !workspaceID.isEmpty else {
            throw FabricError.missingArgument("workspaceID required")
        }
        // fabric-03: percent-encode the ID when building the path so a stray
        // reserved character does not silently restructure the URL.
        let path = "/v1/workspaces/\(workspaceID.percentEncodedPathSegment)/items"
        let url = try fabricListURL(base: baseURL, path: path, continuationToken: continuation)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        do {
            let page = try Self.decoder.decode(FabricPageResponse<WireItem>.self, from: data)
            let tok = page.continuationToken.flatMap { $0.isEmpty ? nil : $0 }
            let hasMore = tok != nil || (page.continuationUri.map { !$0.isEmpty } ?? false)
            return ItemPage(
                items: page.value.compactMap { $0.toItem() },
                continuationToken: tok,
                hasContinuation: hasMore
            )
        } catch {
            throw FabricError.decodeFailed(error)
        }
    }

    /// Returns all items in a workspace, following pagination automatically.
    ///
    /// - Parameters:
    /// - alias: Account alias.
    /// - workspaceID: The workspace to query. Must not be empty.
    /// - Throws: ``FabricError/missingArgument(_:)`` when `workspaceID` is empty.
    public func listAllItems(alias: String, workspaceID: String) async throws -> [Item] {
        guard !workspaceID.isEmpty else {
            throw FabricError.missingArgument("workspaceID required")
        }
        // fabric-03: percent-encode the path segment.
        let path = "/v1/workspaces/\(workspaceID.percentEncodedPathSegment)/items"
        return try await listAllPages(alias: alias, path: path) { (wire: WireItem) in
            wire.toItem()
        }
    }

    // MARK: - Folder operations

    /// Returns a single page of workspace-folders inside a workspace.
    ///
    /// Use ``listAllFolders(alias:workspaceID:)`` for the full list.
    ///
    /// - Parameters:
    /// - alias: Account alias.
    /// - workspaceID: The workspace to query. Must not be empty.
    /// - continuation: Opaque continuation token; `nil` for the first page.
    /// - Returns: A ``FolderPage``.
    /// - Throws: ``FabricError/missingArgument(_:)`` when `workspaceID` is empty.
    public func listFolders(
        alias: String,
        workspaceID: String,
        continuation: String? = nil
    ) async throws -> FolderPage {
        guard !workspaceID.isEmpty else {
            throw FabricError.missingArgument("workspaceID required")
        }
        // fabric-03: percent-encode the path segment.
        let path = "/v1/workspaces/\(workspaceID.percentEncodedPathSegment)/folders"
        let url = try fabricListURL(base: baseURL, path: path, continuationToken: continuation)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        do {
            let page = try Self.decoder.decode(FabricPageResponse<WireFolder>.self, from: data)
            let tok = page.continuationToken.flatMap { $0.isEmpty ? nil : $0 }
            let hasMore = tok != nil || (page.continuationUri.map { !$0.isEmpty } ?? false)
            return FolderPage(
                items: page.value.compactMap { $0.toFolder() },
                continuationToken: tok,
                hasContinuation: hasMore
            )
        } catch {
            throw FabricError.decodeFailed(error)
        }
    }

    /// Returns all workspace-folders inside a workspace, following pagination
    /// automatically.
    ///
    /// These are workspace-level folders that organise items; they are unrelated
    /// to item-internal folders served by the DFS API.
    ///
    /// - Parameters:
    /// - alias: Account alias.
    /// - workspaceID: The workspace to query. Must not be empty.
    /// - Throws: ``FabricError/missingArgument(_:)`` when `workspaceID` is empty.
    public func listAllFolders(alias: String, workspaceID: String) async throws -> [Folder] {
        guard !workspaceID.isEmpty else {
            throw FabricError.missingArgument("workspaceID required")
        }
        // fabric-03: percent-encode the path segment.
        let path = "/v1/workspaces/\(workspaceID.percentEncodedPathSegment)/folders"
        return try await listAllPages(alias: alias, path: path) { (wire: WireFolder) in
            wire.toFolder()
        }
    }

    // MARK: - Single-resource operations

    /// Fetches a single item by workspace and item ID.
    ///
    /// - Parameters:
    /// - alias: Account alias.
    /// - workspaceID: The workspace containing the item. Must not be empty.
    /// - itemID: The item to fetch. Must not be empty.
    /// - Returns: The fetched ``Item``.
    /// - Throws: ``FabricError/missingArgument(_:)`` when either ID is empty;
    /// ``FabricError/notFound`` when the item does not exist.
    public func getItem(
        alias: String,
        workspaceID: String,
        itemID: String
    ) async throws -> Item {
        guard !workspaceID.isEmpty, !itemID.isEmpty else {
            throw FabricError.missingArgument("workspaceID and itemID required")
        }
        // fabric-03: percent-encode both IDs.
        let path = "/v1/workspaces/\(workspaceID.percentEncodedPathSegment)/items/\(itemID.percentEncodedPathSegment)"
        let url = try fabricItemURL(base: baseURL, path: path)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        do {
            guard let item = try Self.decoder.decode(WireItem.self, from: data).toItem() else {
                throw FabricError.decodeFailed(
                    DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "item missing required id or workspaceId"))
                )
            }
            return item
        } catch let err as FabricError {
            throw err
        } catch {
            throw FabricError.decodeFailed(error)
        }
    }

    // MARK: - Private helpers

    /// Executes a Fabric REST request via ``HTTPClient``.
    ///
    /// Acquires a bearer token for the Fabric audience (``TokenScope/fabric``)
    /// and maps ``HTTPClientError`` to ``FabricError``.
    @discardableResult
    private func doRequest(
        alias: String,
        method: String,
        url: URL
    ) async throws -> (Data, HTTPURLResponse) {
        let req = fabricRequest(method: method, url: url)
        let path = url.path
        Self.log.debug("FabricClient: \(method, privacy: .public) \(path, privacy: .public)")
        logger.debug("fabric request", metadata: ["method": method, "path": path])
        do {
            let (data, response) = try await http.execute(
                req,
                tokenProvider: tokenProvider,
                alias: alias,
                scope: .fabric,
                idempotent: true // All Fabric reads are idempotent.
            )
            logger.debug("fabric response", metadata: ["method": method, "path": path, "status": "\(response.statusCode)"])
            return (data, response)
        } catch {
            // fabric-05: log the raw HTTPClientError (or transport error) before
            // classification so a fast failure — e.g. a cached 404 served by
            // URLSession without a real network round-trip — is observable in
            // unredacted DEBUG streams.  The message is compile-time eliminated
            // in Release builds; alias is .public (not PII), error is .public in
            // DEBUG only.
            #if DEBUG
            Self.log.debug(
                "FabricClient[D]: raw error before FabricError.from alias=\(alias, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            #endif
            throw FabricError.from(error)
        }
    }

    /// Walks a paginated Fabric collection, honouring either
    /// `continuationToken` (token replayed on the original path) or
    /// `continuationUri` (absolute or relative URL — resolved and issued directly).
    ///
    /// Three guards prevent a misbehaving server from looping forever:
    /// - Hard cap of ``maxPaginationPages``.
    /// - Full set of seen continuation tokens/URIs (not just the immediately
    ///   previous one), catching A→B→A→B cycles (onelake-11 pattern).
    private func listAllPages<Wire: Decodable, Model>(
        alias: String,
        path: String,
        convert: (Wire) -> Model?
    ) async throws -> [Model] {
        var all: [Model] = []
        var nextURL: URL = try fabricListURL(base: baseURL, path: path)
        var seenTokens: Set<String> = []
        var seenURIs: Set<String> = []

        for page in 0..<Self.maxPaginationPages {
            let (data, _) = try await doRequest(alias: alias, method: "GET", url: nextURL)
            let pr: FabricPageResponse<Wire>
            do {
                pr = try Self.decoder.decode(FabricPageResponse<Wire>.self, from: data)
            } catch {
                throw FabricError.decodeFailed(error)
            }

            let pageItems = pr.value.compactMap(convert)
            all.append(contentsOf: pageItems)

            // Determine how to advance (token branch or URI branch).
            //
            // NIT-4: seenTokens.removeAll() / seenURIs.removeAll() is called
            // whenever the server switches between the two continuation styles.
            // This means a mixed-mode server (token T → URI U → token T) would
            // not be caught by the set guard alone.  That is acceptable: the
            // hard cap of maxPaginationPages provides a universal upper bound
            // regardless of the cycle shape, so the invariant "we terminate" is
            // preserved.  The set guards are an optimisation that short-circuits
            // obvious same-branch cycles early, not the sole safety net.
            if let tok = pr.continuationToken, !tok.isEmpty {
                // Guard against a token seen before (detects A→B→A→B cycles).
                if seenTokens.contains(tok) {
                    throw FabricError.loopingPagination(
                        "server returned duplicate continuationToken for \(path)"
                    )
                }
                seenTokens.insert(tok)
                seenURIs.removeAll()
                nextURL = try fabricListURL(base: baseURL, path: path, continuationToken: tok)
                Self.log.debug("FabricClient: following continuationToken, page \(page + 1, privacy: .public), \(all.count, privacy: .public) items so far")
                logger.debug("fabric list page", metadata: [
                    "path": path,
                    "page": "\(page + 1)",
                    "itemsThisPage": "\(pageItems.count)",
                    "totalSoFar": "\(all.count)",
                    "hasContinuation": "true",
                ])
            } else if let uriString = pr.continuationUri, !uriString.isEmpty {
                // net-12: a continuationUri-only response means more pages exist.
                if seenURIs.contains(uriString) {
                    throw FabricError.loopingPagination(
                        "server returned duplicate continuationUri for \(path)"
                    )
                }
                seenURIs.insert(uriString)
                seenTokens.removeAll()
                nextURL = try resolveContinuationURI(uriString, base: baseURL)
                Self.log.debug("FabricClient: following continuationUri, page \(page + 1, privacy: .public), \(all.count, privacy: .public) items so far")
                logger.debug("fabric list page", metadata: [
                    "path": path,
                    "page": "\(page + 1)",
                    "itemsThisPage": "\(pageItems.count)",
                    "totalSoFar": "\(all.count)",
                    "hasContinuation": "true",
                ])
            } else {
                // No continuation — last page.
                logger.debug("fabric list page", metadata: [
                    "path": path,
                    "page": "\(page + 1)",
                    "itemsThisPage": "\(pageItems.count)",
                    "totalSoFar": "\(all.count)",
                    "hasContinuation": "false",
                ])
                logger.debug("fabric list complete", metadata: [
                    "path": path,
                    "totalPages": "\(page + 1)",
                    "totalItems": "\(all.count)",
                ])
                return all
            }
        }

        throw FabricError.paginationExceeded(Self.maxPaginationPages)
    }
}

// NIT-1: `percentEncodedPathSegment` is defined once in StringExtensions.swift
// and shared across the Clients domain. No private copy needed here.
