import Foundation
import Testing

@testable import OfemKit

// MARK: - Gating

/// `true` only when integration tests are explicitly opted into via the
/// environment. The default unit-test pass never sets this, so the live suites
/// below are skipped everywhere except the dedicated CI workflow (and a local
/// `make test-integration`).
let integrationEnabled = ProcessInfo.processInfo.environment["OFEM_INTEGRATION"] == "1"

/// `true` when a prepared warehouse is available (`OFEM_TEST_WAREHOUSE_ID` set).
/// The warehouse table must be seeded first by `scripts/prep_warehouse.py`.
let warehouseConfigured = !(ProcessInfo.processInfo.environment["OFEM_TEST_WAREHOUSE_ID"] ?? "").isEmpty

extension Trait where Self == ConditionTrait {
    /// Skips a suite/test unless `OFEM_INTEGRATION=1`. Integration tests hit a
    /// live Fabric workspace and need bearer tokens injected through
    /// ``EnvVarTokenProvider``; they cannot run in the host-less unit pass.
    static var integration: Self {
        .enabled(
            if: integrationEnabled,
            "set OFEM_INTEGRATION=1 with injected tokens + workspace env to run live integration tests"
        )
    }

    /// Skips a suite/test unless integration is enabled AND a prepared warehouse
    /// is configured. The warehouse table is seeded out-of-band by
    /// `scripts/prep_warehouse.py` (CI runs it before the suite).
    static var warehouse: Self {
        .enabled(
            if: integrationEnabled && warehouseConfigured,
            "set OFEM_INTEGRATION=1 and OFEM_TEST_WAREHOUSE_ID (after scripts/prep_warehouse.py) to run warehouse tests"
        )
    }
}

// MARK: - Token injection

/// A ``TokenProvider`` that returns bearer tokens straight from the environment.
///
/// Used only by the integration test target — the shipped product authenticates
/// interactively through MSAL and never sees a service-principal token. CI
/// obtains tokens with `az account get-access-token` for the two audiences OFEM
/// needs and exports them:
///   - `OFEM_TOKEN_ONELAKE` — audience `https://storage.azure.com/` (DFS data plane)
///   - `OFEM_TOKEN_FABRIC`  — audience `https://analysis.windows.net/powerbi/api` (Fabric REST)
///
/// The `alias` is ignored: a single injected identity backs every account.
struct EnvVarTokenProvider: TokenProvider {
    enum Failure: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case .missing(let name): return "integration env var \(name) is not set"
            }
        }
    }

    func token(alias: String, scope: TokenScope) async throws -> String {
        let name: String
        switch scope {
        case .oneLake: name = "OFEM_TOKEN_ONELAKE"
        case .fabric: name = "OFEM_TOKEN_FABRIC"
        }
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw Failure.missing(name)
        }
        return value
    }
}

// MARK: - Live-environment coordinates

/// Workspace + lakehouse coordinates for the live suite, read from the
/// environment the CI workflow populates.
struct IntegrationConfig {
    let workspaceID: String
    let lakehouseID: String
    /// Warehouse item GUID; `nil` unless `OFEM_TEST_WAREHOUSE_ID` is set.
    let warehouseID: String?

    static func fromEnvironment() throws -> IntegrationConfig {
        let env = ProcessInfo.processInfo.environment
        guard let ws = env["OFEM_TEST_WORKSPACE_ID"], !ws.isEmpty else {
            throw EnvVarTokenProvider.Failure.missing("OFEM_TEST_WORKSPACE_ID")
        }
        guard let lh = env["OFEM_TEST_LAKEHOUSE_ID"], !lh.isEmpty else {
            throw EnvVarTokenProvider.Failure.missing("OFEM_TEST_LAKEHOUSE_ID")
        }
        let wh = env["OFEM_TEST_WAREHOUSE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        return IntegrationConfig(workspaceID: ws, lakehouseID: lh, warehouseID: wh)
    }

    /// The warehouse item GUID, or a thrown error when it is not configured.
    /// Use inside suites gated by `.warehouse`, where it is guaranteed present.
    func requireWarehouseID() throws -> String {
        guard let wh = warehouseID else {
            throw EnvVarTokenProvider.Failure.missing("OFEM_TEST_WAREHOUSE_ID")
        }
        return wh
    }
}
