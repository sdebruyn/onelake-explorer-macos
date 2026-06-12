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

    // MARK: - Properties

    private let http: HTTPClient
    private let tokenProvider: any TokenProvider
    private let baseURL: URL

    private static let log = Logger(subsystem: "dev.debruyn.ofem", category: "FabricClient")

    // MARK: - Initialisers

    /// Creates a `FabricClient`.
    ///
    /// - Parameters:
    /// - http: Shared ``HTTPClient`` (carries gate registry + retry policy).
    /// - tokenProvider: Supplies bearer tokens for account aliases.
    /// - baseURL: Fabric REST endpoint. Default: `https://api.fabric.microsoft.com`.
    public init(
        http: HTTPClient,
        tokenProvider: any TokenProvider,
        baseURL: URL = fabricDefaultBaseURL
    ) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
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
    ///   `continuationToken` is `nil`; use ``listAllWorkspaces(alias:)`` to
    ///   follow both continuation forms exhaustively (net-12).
    /// - Throws: ``FabricError`` on failure.
    public func listWorkspaces(
        alias: String,
        continuation: String? = nil
    ) async throws -> WorkspacePage {
        let url = fabricListURL(base: baseURL, path: "/v1/workspaces", continuationToken: continuation)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        // net-13: the `catch let fabErr as FabricError` clause was unreachable —
        // JSONDecoder never throws FabricError. Use a single catch instead.
        do {
            let page = try JSONDecoder().decode(FabricPageResponse<WireWorkspace>.self, from: data)
            return WorkspacePage(
                items: page.value.map { $0.toWorkspace() },
                continuationToken: resolvedContinuationToken(page)
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
        let path = "/v1/workspaces/\(workspaceID)/items"
        let url = fabricListURL(base: baseURL, path: path, continuationToken: continuation)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        // net-13: removed unreachable `catch let fabErr as FabricError` clause.
        do {
            let page = try JSONDecoder().decode(FabricPageResponse<WireItem>.self, from: data)
            return ItemPage(
                items: page.value.map { $0.toItem() },
                continuationToken: resolvedContinuationToken(page)
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
        let path = "/v1/workspaces/\(workspaceID)/items"
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
        let path = "/v1/workspaces/\(workspaceID)/folders"
        let url = fabricListURL(base: baseURL, path: path, continuationToken: continuation)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        // net-13: removed unreachable `catch let fabErr as FabricError` clause.
        do {
            let page = try JSONDecoder().decode(FabricPageResponse<WireFolder>.self, from: data)
            return FolderPage(
                items: page.value.map { $0.toFolder() },
                continuationToken: resolvedContinuationToken(page)
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
        let path = "/v1/workspaces/\(workspaceID)/folders"
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
        let path = "/v1/workspaces/\(workspaceID)/items/\(itemID)"
        let url = fabricItemURL(base: baseURL, path: path)
        let (data, _) = try await doRequest(alias: alias, method: "GET", url: url)
        // net-13: removed unreachable `catch let fabErr as FabricError` clause.
        do {
            return try JSONDecoder().decode(WireItem.self, from: data).toItem()
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
        Self.log.debug("FabricClient: \(method, privacy: .public) \(url.path, privacy: .public)")
        do {
            return try await http.execute(
                req,
                tokenProvider: tokenProvider,
                alias: alias,
                scope: .fabric,
                idempotent: true // All Fabric reads are idempotent.
            )
        } catch {
            throw FabricError.from(error)
        }
    }

    /// Walks a paginated Fabric collection, honouring either
    /// `continuationToken` (token replayed on the original path) or
    /// `continuationUri` (absolute or relative URL — resolved and issued directly).
    ///
    /// Three guards prevent a misbehaving server from looping forever:
    /// - Hard cap of ``maxPaginationPages``.
    /// - Identical continuation token twice in a row.
    /// - Identical continuation URI twice in a row.
    private func listAllPages<Wire: Decodable, Model>(
        alias: String,
        path: String,
        convert: (Wire) -> Model
    ) async throws -> [Model] {
        var all: [Model] = []
        var nextURL: URL = fabricListURL(base: baseURL, path: path)
        var prevToken: String = ""
        var prevURI: String = ""

        for page in 0..<Self.maxPaginationPages {
            let (data, _) = try await doRequest(alias: alias, method: "GET", url: nextURL)
            let pr: FabricPageResponse<Wire>
            do {
                pr = try JSONDecoder().decode(FabricPageResponse<Wire>.self, from: data)
            } catch {
                throw FabricError.decodeFailed(error)
            }

            all.append(contentsOf: pr.value.map(convert))

            // Determine how to advance (token branch or URI branch).
            if let tok = pr.continuationToken, !tok.isEmpty {
                // Guard against an identical token returned twice in a row.
                if tok == prevToken {
                    throw FabricError.loopingPagination(
                        "server returned identical continuationToken twice for \(path)"
                    )
                }
                prevToken = tok
                prevURI = ""
                nextURL = fabricListURL(base: baseURL, path: path, continuationToken: tok)
                Self.log.debug("FabricClient: following continuationToken, page \(page + 1, privacy: .public), \(all.count, privacy: .public) items so far")
            } else if let uriString = pr.continuationUri, !uriString.isEmpty {
                // net-12: a continuationUri-only response means more pages exist;
                // it must not be silently treated as "last page".
                // Guard against an identical URI returned twice in a row.
                if uriString == prevURI {
                    throw FabricError.loopingPagination(
                        "server returned identical continuationUri twice for \(path)"
                    )
                }
                prevURI = uriString
                prevToken = ""
                // net-06: resolveContinuationURI now resolves relative URIs
                // against base so the result is always a usable absolute URL.
                nextURL = try resolveContinuationURI(uriString, base: baseURL)
                Self.log.debug("FabricClient: following continuationUri, page \(page + 1, privacy: .public), \(all.count, privacy: .public) items so far")
            } else {
                // No continuation — last page.
                return all
            }
        }

        throw FabricError.paginationExceeded(Self.maxPaginationPages)
    }
}

// MARK: - Continuation token resolution helper

/// Extracts the effective continuation token from a page response.
///
/// Returns `continuationToken` when present and non-empty. Returns `nil` when
/// only `continuationUri` is present — the single-page API callers cannot
/// round-trip a URI as an opaque token. In that case the next-page state is
/// lost; use the exhaust-all variants (``FabricClient/listAllWorkspaces(alias:)``
/// etc.) which follow both continuation forms internally (net-12).
private func resolvedContinuationToken<T>(_ page: FabricPageResponse<T>) -> String? {
    if let tok = page.continuationToken, !tok.isEmpty { return tok }
    return nil
}
