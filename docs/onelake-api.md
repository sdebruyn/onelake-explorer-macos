# OneLake & Fabric APIs — what we need

Two API families together give us everything we need:

1. **Fabric REST API** (`https://api.fabric.microsoft.com`) — for discovery: workspaces, items, metadata.
2. **OneLake DFS API** (`https://onelake.dfs.fabric.microsoft.com`) — for file I/O, ADLS Gen2–compatible.

Both accept the same token audience: `https://storage.azure.com/`. For the Fabric REST API the audience `https://api.fabric.microsoft.com/.default` also works, but `storage.azure.com` is sufficient for both listing and data I/O via DFS.

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

For the MVP the generic Get/List Item is enough — we don't need to special-case every item type.

### Catalog search (optional, phase 2)

```http
POST https://api.fabric.microsoft.com/v1/admin/items/search
```

Powerful for "find all items matching X", but not critical for file browsing.

### Shortcuts

```http
GET https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/items/{itemId}/shortcuts
```

Returns, per shortcut, the path within the item and the target type (`OneLake`, `ADLS Gen2`, `Amazon S3`, `Google Cloud Storage`, `S3 Compatible`, `Dataverse`, `External Data Share`). For the MVP shortcuts are **transparent**: they appear as a folder in the DFS-API listing without any special handling.

## File I/O — OneLake DFS API (ADLS Gen2–compatible)

OneLake speaks the [ADLS Gen2 REST API](https://learn.microsoft.com/rest/api/storageservices/data-lake-storage-gen2). Mapping:

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

### Tables endpoint (separate, not for MVP)

```
https://onelake.table.fabric.microsoft.com
```

Iceberg REST Catalog and Delta protocols for table metadata. Not needed for file browsing; potentially relevant if we ever add table preview.

## Throughput considerations

- DFS endpoints support parallel reads via `Range` headers — good for large files.
- For uploads of large files: chunked write through `append` + `flush` is more efficient than a single big `PUT`.
- Listings are paginated through the `continuation` parameter — implement pagination correctly or you will miss files in large folders.
- The HTTP client deliberately does NOT set a top-level `Client.Timeout`. A `Read` on a multi-GiB file at modest bandwidth would otherwise be killed mid-stream. We instead cap the response-header wait via `http.Transport.ResponseHeaderTimeout` (default 30 s) and leave the body-streaming budget to the caller's `context`. Callers that want to bound a download should use `context.WithTimeout` or `context.WithDeadline`.

## Error handling we must cover explicitly

| Status | Meaning | Reaction |
|---|---|---|
| `401` | Token expired or no access | Refresh token; if that fails, re-authenticate |
| `403` | Authenticated but no permission on the item | Display clearly; do not retry |
| `404` | Path does not exist | Standard |
| `409` | Conflict (e.g. directory already exists) | On upload-with-overwrite, retry |
| `412` / `If-Match` | Etag conflict | Surface "remote was changed; refresh first" |
| `429` | Throttling | Exponential backoff, honor `Retry-After` |
| `503` | Backend temporarily unavailable | Same retry pattern |
| `x-ms-rejected-headers` in the response | OneLake ignored a header | Log it, do not fail |
