# Telemetry Backend Research for OFEM (OneLake File Explorer)

## Context

OFEM is an open-source macOS app shipping opt-out telemetry with the schema
`{ ts, installId, appVersion, platform, osVersion, tenantId, event, durationMs, success, errorCode }`
(~300 B per event). Projected volume: **< 100k events/month** in year one, possibly
growing toward 1M/month. Data must end up queryable in Microsoft Fabric, but does
**not** have to land in Fabric. A 24/7 Fabric capacity is a non-starter for a personal
OSS project.

All EUR prices are West Europe pay-as-you-go, rounded; check the Azure pricing
calculator before committing.

---

## 1. Azure Functions Consumption + ADLS Gen2

- **Free grant**: 1,000,000 executions/month + 400,000 GB-s/month, **per subscription**.
- 100k events/month sits ~10x inside the free tier. 1M/month still fits.
- Storage: 100k events x ~300 B = ~30 MB/month. ADLS Gen2 hot = ~0.018 EUR/GB; writes
  ~0.05 EUR per 10k transactions. Batching client side keeps writes well under 1 EUR/mo.
- **Cold start**: 1-3 s on first hit after idle. Fine for fire-and-forget telemetry.
- **Fabric integration**: create an ADLS Gen2 **shortcut** in a Lakehouse `Files/`,
  then a notebook (or a Fabric trial capacity, or your own developer machine) parses
  JSONL into Delta. Shortcuts themselves consume **zero** capacity when idle.
- **Total**: effectively **0 EUR/month** at 100k; **<1 EUR/month** at 1M.

## 2. Application Insights (workspace-based)

- **Free grant**: 5 GB/month ingestion, 31-day retention free.
- 100k events x ~1 KB enriched = ~100 MB/month - 50x headroom. 1M/month = ~1 GB.
- **Fabric query path**: AI/Log Analytics has **no native Fabric connector**.
  Workarounds:
  - **Diagnostic Settings -> Storage Account** (continuous export of the `customEvents`
    table to Blob/ADLS). Then shortcut that storage into OneLake. Export itself costs
    ~0.13 EUR/GB ingested, so ~0.65 EUR/mo at 1M events.
  - Or query Log Analytics from a Fabric notebook via the `azure-monitor-query` SDK.
- **Pros**: SDK is one line, anomaly detection / live metrics / sampling are free.
- **Cons**: extra hop into Fabric, double-storage, Azure Monitor egress charge if you
  export, vendor-flavored schema.

## 3. Azure Event Hubs Basic

- Minimum 1 Throughput Unit, billed hourly. Basic = ~0.011 EUR/hr = **~8 EUR/month
  baseline**, plus 0.025 EUR per million ingress events.
- 1 TU = 1 MB/s, 1,000 events/s. Our peak is maybe 1 event/s. **Massively overkill.**
- Basic tier max retention is 1 day, no Capture, no Kafka consumer groups.
- **Verdict**: rule out. Pay-per-streaming-unit doesn't beat Functions free tier.

## 4. Direct client write to Storage with SAS

- Cost: storage only (~cents/mo).
- **Security**: SAS embedded in a public open-source binary is essentially a public
  write token. Anyone can spam your container; the moment it's abused you need to
  rotate (and every old client breaks). Account SAS also allows listing/deletion
  unless tightly scoped to one container with `add`-only and short expiry.
- Even with a write-only, time-bounded **user-delegated SAS** rotated server-side,
  you still need a server to mint it - which negates the "no backend" advantage.
- **Verdict**: bad trust model for OSS telemetry. Skip.

## 5. Cloudflare Workers + R2

- Workers free: **100,000 requests/day** (3M/month), 10 ms CPU/request. Plenty.
- R2 free: 10 GB storage, 1M Class A (write) ops/month, **no egress fees**.
- Pattern: Worker validates a static ingest key, appends NDJSON line into a daily
  R2 object via multipart, or POSTs to a Durable Object that flushes every N seconds.
- **Fabric integration**: OneLake supports **S3-compatible shortcuts**, and R2
  exposes an S3 API. Create the shortcut with the R2 access key + endpoint
  (`https://<accountid>.r2.cloudflarestorage.com`). Verified pattern by multiple
  community blogs; the shortcut caches reads, so cross-cloud egress is minimal.
- **Total**: **0 EUR/month** at 100k and 1M.
- **Cons**: data lives at Cloudflare (US/EU edge), so the privacy notice must say
  "telemetry is stored at Cloudflare R2 (EU) and analyzed in Microsoft Fabric".

## 6. Fabric Eventstream Custom Endpoint (HTTPS)

- The eventstream custom endpoint **requires the workspace to live on a Fabric
  capacity** (or a Trial). There is no serverless/0-CU path for ingestion.
- Smallest paid SKU = **F2** at ~0.18 EUR/hr PAYG = **~130 EUR/month** 24/7, or
  ~88 EUR/month with 1-year reservation. You can pause F2, but then events that
  arrive while paused are dropped.
- Eventstream processing itself is metered only while data flows, but the underlying
  capacity is hourly. This is the gold-standard architecture - and the wrong fit
  for a personal OSS project.
- **Verdict**: ideal experience, unacceptable cost. Skip.

## 7. Static Web Apps + Managed Functions

- SWA Free tier includes managed Functions, but the managed-functions runtime is
  restricted to ~1M executions/month bundled with SWA - effectively the same as
  bare Functions Consumption, plus a static landing/privacy page for free.
- Same downstream story as option 1 (write to Storage, shortcut into Fabric).
- Marginal upside: free HTTPS hostname + privacy page co-located with the API.

## 8. GitHub Actions cron + Git-stored data

- Rate-limited, no public ingress endpoint, committing telemetry to a public repo
  would PII-leak install IDs forever. Ruled out, as requested.

---

## Comparison

| # | Option                      | 100k/mo  | 1M/mo  | Setup | Latency to query | Fabric-native |
|---|-----------------------------|----------|--------|-------|------------------|---------------|
| 1 | Functions + ADLS            | ~0 EUR   | <1 EUR | 2     | minutes (shortcut) | Lakehouse + Notebook |
| 2 | App Insights (+export)      | 0 EUR    | ~1 EUR | 1     | minutes-hours     | indirect      |
| 3 | Event Hubs Basic            | ~8 EUR   | ~8 EUR | 3     | seconds           | needs F SKU   |
| 4 | Direct SAS to Storage       | ~0 EUR   | ~0 EUR | 1     | minutes           | Lakehouse     |
| 5 | Cloudflare Workers + R2     | 0 EUR    | 0 EUR  | 2     | minutes (shortcut)| Lakehouse + Notebook |
| 6 | Fabric Eventstream (F2)     | ~88 EUR  | ~88 EUR| 3     | seconds           | Eventhouse/KQL |
| 7 | SWA + Functions             | 0 EUR    | <1 EUR | 2     | minutes           | Lakehouse     |
| 8 | GitHub Actions              | n/a      | n/a    | n/a   | n/a               | n/a           |

---

## Recommendation: Azure Functions Consumption + ADLS Gen2 -> OneLake shortcut

```
+----------------+      HTTPS POST        +-------------------------+
|  OFEM (macOS)   |  /v1/events  + key     |  Azure Function (Cons.) |
|  opt-out       | ---------------------> |  Node/.NET, validates,  |
|  telemetry SDK |                        |  appends NDJSON line    |
+----------------+                        +------------+------------+
                                                       |
                                                       v
                                          +------------+-------------+
                                          |  ADLS Gen2 Storage Acct  |
                                          |  container: telemetry/   |
                                          |  YYYY/MM/DD/HH.jsonl     |
                                          +------------+-------------+
                                                       |
                                              OneLake Shortcut
                                                (zero copy)
                                                       v
                                          +------------+-------------+
                                          |  Fabric Lakehouse        |
                                          |  Files/telemetry/...     |
                                          |  + Notebook job (trial   |
                                          |  capacity / on-demand)   |
                                          |  -> Delta table          |
                                          +--------------------------+
```

### Why this beats the alternatives

It is the **only** option that is simultaneously free at projected volume, fully in
Azure (matching Sam's ecosystem and the privacy story end-users will expect from a
Microsoft-Fabric-adjacent tool), avoids any 24/7 capacity cost, and lands raw JSONL
in a storage account that Fabric reads **zero-copy** via a OneLake shortcut. Option 5
(Cloudflare R2) is equally free but moves data outside Azure (extra disclosure, extra
provider trust); option 2 (App Insights) is great for live debugging but indirect to
Fabric; options 3 and 6 cost real money for streaming guarantees we don't need at
~1 event/second. Setup is one Bicep file plus a 30-line HTTP-trigger function, and
the same architecture scales to 10M events/month before any line item crosses 5 EUR.
