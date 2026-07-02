# OneLake & Fabric APIs — what we need

Two API families together give us everything we need:

1. **Fabric REST API** (`https://api.fabric.microsoft.com`) — for discovery: workspaces, items, metadata.
2. **OneLake DFS API** (`https://onelake.dfs.fabric.microsoft.com`) — for file I/O, ADLS Gen2–compatible.

The two APIs require **different** token audiences — a single audience does not cover both:

- **OneLake DFS** uses `https://storage.azure.com/` (`OneLakeScopes`).
- **Fabric REST** uses the Power BI Service audience `https://analysis.windows.net/powerbi/api` (`FabricScopes`); `api.fabric.microsoft.com` accepts it. A `storage.azure.com` token returns **401 InvalidToken** on Fabric REST.

OFEM acquires the OneLake token interactively at sign-in and the Fabric token silently from the same refresh token. See `docs/auth.md` "Two-audience scope model" and `Packages/OfemKit/Sources/OfemKit/Auth/TokenScope.swift`.

## URI shapes

### Named URI (human-friendly, but sensitive to renames and special characters)

```
https://onelake.dfs.fabric.microsoft.com/<workspaceName>/<itemName>.<itemtype>/<path>/<fileName>
```

### GUID URI (immutable; recommended for our internal paths)

```
https://onelake.dfs.fabric.microsoft.com/<workspaceGUID>/<itemGUID>/<path>/<fileName>
```

### ABFS style (Hadoop-tool compatible, not what we call directly)

```
abfs[s]://<workspace>@onelake.dfs.fabric.microsoft.com/<item>.<itemtype>/<path>/<fileName>
```

### Alternate hostnames

- `https://api.onelake.fabric.microsoft.com` — generic FQDN (no `.dfs`/`.blob` substring; may cause compat issues with some Azure SDKs, but is fine for our own client).
- `https://<region>-api.onelake.fabric.microsoft.com` — regional variant.
- `https://<wsid>.z<xy>.dfs.fabric.microsoft.com` — workspace FQDN for private endpoints (only relevant when the user is in such an environment).

**Decision**: default to `onelake.dfs.fabric.microsoft.com`; expose the private-link FQDN as an advanced configuration option.

## Discovery — Fabric REST API

### List workspaces

```http
GET https://api.fabric.microsoft.com/v1/workspaces
Authorization: Bearer <token>
```

Response includes `id` (GUID), `displayName`, `type`, `capacityId`, optionally `domainId` per workspace.

### List items inside a workspace

```http
GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items
```

Returns `id`, `displayName`, `type` (e.g. `Lakehouse`, `Warehouse`, `KQLDatabase`, `MirroredDatabase`, `SemanticModel`, `Notebook`, …), `description`, `workspaceId`.

### Type-specific item endpoints (extra metadata)

Certain item types have a type-specific endpoint that returns more info:

```http
GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/lakehouses/{lakehouseId}
```

→ returns OneLake paths to `/Files` and `/Tables`, plus the SQL analytics endpoint connection string.

Similar endpoints exist for `eventhouses`, `kqlDatabases`, `warehouses`, `mirroredDatabases`, …

OFEM uses the generic Get/List Item endpoints and does not special-case every item type.

### Catalog search (optional)

```http
POST https://api.fabric.microsoft.com/v1/admin/items/search
```

Powerful for "find all items matching X", but not critical for file browsing.

### Shortcuts

```http
GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{itemId}/shortcuts
```

Returns, per shortcut, the path within the item and the target type (`OneLake`, `ADLS Gen2`, `Amazon S3`, `Google Cloud Storage`, `S3 Compatible`, `Dataverse`, `External Data Share`). Shortcuts are **transparent**: they appear as a folder in the DFS-API listing without any special handling.

## File I/O — OneLake DFS API (ADLS Gen2–compatible)

OneLake speaks the [ADLS Gen2 REST API](https://learn.microsoft.com/rest/api/storageservices/data-lake-storage-gen2?WT.mc_id=MVP_310840). Mapping:

| ADLS concept | OneLake equivalent |
|---|---|
| Account name | always `onelake` |
| Container / filesystem name | workspace name or GUID |
| Path | starts at the item, e.g. `/mylakehouse.lakehouse/Files/foo.csv` |

### Operations we need

**Filesystem (= workspace)**:
- `HEAD /` — does the workspace exist (useful for a permission check)
- `GET /?resource=filesystem&recursive=false` — list top-level items

**Path (= folder or file)**:
- `GET /{path}?resource=filesystem&recursive=false&directory={dir}` — folder listing
- `HEAD /{path}` — metadata (size, last-modified, etag, content-type)
- `GET /{path}` — read file content (with `Range` header for partial reads)
- `PUT /{path}?resource=file` — create file
- `PATCH /{path}?action=append&position=N` — append data
- `PATCH /{path}?action=flush&position=N` — flush after append
- `PUT /{path}?resource=directory` — create folder
- `DELETE /{path}` — delete (folder or file)
- `PUT /{path}` with `x-ms-rename-source` header — rename / move

### What OneLake **does not** support via the ADLS API (parity gaps)

Important to know for good error handling:

- **No ACL operations**: headers `x-ms-owner`, `x-ms-group`, `x-ms-permissions`, `x-ms-acls` are ignored; `?action=setAccessControl[Recursive]` is rejected. Permissions are managed through the Fabric portal.
- **No access tier or encryption scope**: headers ignored.
- **Workspace and item folders are protected**: you cannot create, rename, or delete them via the DFS API.
- **The first level inside an item** (e.g. `/MyLakehouse.lakehouse/Files` and `/MyLakehouse.lakehouse/Tables`) is Fabric-managed and not modifiable.
- **Page blobs**: not supported (`Put Page`, `Get Page Ranges`).
- **Cross-tenant operations**: not possible in a single API call; must go through External Data Sharing or via download-and-upload.

### Tables endpoint (not used)

```
https://onelake.table.fabric.microsoft.com
```

Iceberg REST Catalog and Delta protocols for table metadata. Not needed for file browsing; potentially relevant if we ever add table preview.

## Throughput considerations

- DFS endpoints support parallel reads via `Range` headers — good for large files.
- For uploads of large files: chunked write through `append` + `flush` is more efficient than a single big `PUT`.
- Listings are paginated through the `continuation` parameter — implement pagination correctly or you will miss files in large folders.
- HTTP is an Alamofire `Session` over `URLSession` (see `Packages/OfemKit/Sources/OfemKit/HTTP/SessionPool.swift`), pooled per `(alias, scope)` so token refresh and connection limits stay scoped to the right account and audience. `timeoutIntervalForRequest` is 60 s, but `timeoutIntervalForResource` is deliberately `.infinity`: a resource-level wall-clock cap would kill a multi-GiB download or append stream mid-transfer at modest bandwidth. There is no response-header timeout either. Instead, retries are bounded explicitly by `RetryAfterRetrier` (honors `Retry-After` on 429/5xx, capped at `maxDelay = 30s`) ahead of `JitteredRetryPolicy` (full-jitter backoff, on `408, 425, 429, 500, 502, 503, 504`) — both share a combined budget of `maxRetries = 5` attempts, so a repeatedly-throttled request cannot retry indefinitely; the resource never hangs open on a dead connection, it just isn't killed by a fixed clock.

## Error handling we must cover explicitly

| Status | Meaning | Reaction |
|---|---|---|
| `401` | Token expired or no access | Refresh token; if that fails, re-authenticate |
| `403` | Authenticated but no permission on the item, **or** a paused/suspended Fabric capacity | `PauseManager.isPausedCapacityError` inspects the response body to tell the two apart; either way it maps to `.cannotSynchronize`, never `.notAuthenticated` — a 403 must never trigger re-authentication |
| `404` | Path does not exist | Standard; a `DELETE` that 404s is treated as success (the row is already gone, e.g. a replayed retry of an already-committed delete) — see `SyncEngine.delete` |
| `409` | Conflict (e.g. directory already exists) | On upload-with-overwrite, retry |
| `412` / `If-Match` | Etag conflict | Surface "remote was changed; refresh first" |
| `429` | Throttling | Exponential backoff with full jitter, honor `Retry-After`; capped at 5 combined retries and a 30 s `Retry-After` ceiling — see "Throughput considerations" above |
| `503` | Backend temporarily unavailable | Same retry pattern |
| `x-ms-rejected-headers` in the response | OneLake ignored a header | Log it, do not fail |
