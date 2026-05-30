package httpgate

import "time"

// Known hosts and their sensible default budgets. [DefaultRegistry]
// pre-registers these at daemon start so the very first Acquire on each
// host uses the curated values instead of the generic [Defaults]
// fall-back. The values are conservative — we'd rather be a little slow
// than trigger Fabric's throttling on the first sync after a fresh login.
const (
	// HostFabric is the Fabric REST host (discovery only).
	HostFabric = "api.fabric.microsoft.com"
	// HostOneLake is the OneLake DFS host (file I/O).
	HostOneLake = "onelake.dfs.fabric.microsoft.com"
)

// FabricBudget is the inflight cap, qps and burst recommended for the
// Fabric REST host. Fabric is the lower-budget upstream of the two so we
// keep both concurrency and qps tight.
//
// TODO(telemetry): FabricQPS=2 is conservative relative to nothing —
// Microsoft does not publish concrete RPS limits for the Fabric REST
// surface, so this number is a guess sized to be safe on first sync.
// Revisit once we have multi-tenant production traffic in the
// telemetry pipeline (see docs/telemetry.md) and a feel for the real
// throttle threshold. 4–5 qps is a likely safe bump.
const (
	FabricConcurrency = 8
	FabricQPS         = 2
	FabricBurst       = 4
	// FabricMissingRetryAfter is the pause applied when Fabric returns
	// 429/503 with no Retry-After header. Errs on the long side because
	// Fabric throttling typically takes a tens-of-seconds window to clear.
	FabricMissingRetryAfter = 30 * time.Second
)

// OneLakeBudget is the inflight cap, qps and burst recommended for the
// DFS endpoint. ADLS Gen2 tolerates much higher concurrency than Fabric
// REST, so the cap is roomier.
const (
	OneLakeConcurrency = 16
	OneLakeQPS         = 8
	OneLakeBurst       = 16
	// OneLakeMissingRetryAfter is the pause applied when DFS returns
	// 429/503 with no Retry-After header. DFS recovers faster than
	// Fabric so the fallback is shorter.
	OneLakeMissingRetryAfter = 10 * time.Second
)

// DefaultRegistry builds a [Registry] with Fabric and OneLake pre-
// registered against the budgets above and the [Defaults] tuned for any
// other host that lands here by accident.
func DefaultRegistry() *Registry {
	r := NewRegistry(Defaults{
		Concurrency:       FabricConcurrency,
		QPS:               FabricQPS,
		Burst:             FabricBurst,
		MissingRetryAfter: FabricMissingRetryAfter,
	})
	r.Register(HostFabric, FabricConcurrency, FabricQPS, FabricBurst)
	r.Register(HostOneLake, OneLakeConcurrency, OneLakeQPS, OneLakeBurst)
	return r
}
