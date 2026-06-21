import Foundation
@testable import OfemKit
import Testing

// MARK: - Gating

/// `true` only when integration tests are explicitly opted into via the
/// environment. The default unit-test pass never sets this, so the live suites
/// below are skipped everywhere except the dedicated CI workflow (and a local
/// `make test-integration`).
let integrationEnabled = ProcessInfo.processInfo.environment["OFEM_INTEGRATION"] == "1"

/// `true` when a prepared warehouse is available (`OFEM_TEST_WAREHOUSE_ID` set).
/// The warehouse table must be seeded first by `scripts/prep_warehouse.sql`.
let warehouseConfigured = !(ProcessInfo.processInfo.environment["OFEM_TEST_WAREHOUSE_ID"] ?? "").isEmpty

/// `true` only when all required integration env vars are present and non-empty.
///
/// tests-22: gate on ALL required vars so that a partially-configured environment
/// (OFEM_INTEGRATION=1 but missing workspace IDs) produces a clean skip rather
/// than a thrown test failure. The thrown-failure path in
/// `IntegrationConfig.fromEnvironment()` is only reachable when this trait
/// permits execution, guaranteeing every var is present.
private let integrationFullyConfigured: Bool = {
    let env = ProcessInfo.processInfo.environment
    guard integrationEnabled else { return false }
    let required = ["OFEM_TEST_WORKSPACE_ID", "OFEM_TEST_LAKEHOUSE_ID",
                    "OFEM_TOKEN_ONELAKE", "OFEM_TOKEN_FABRIC"]
    return required.allSatisfy { !(env[$0] ?? "").isEmpty }
}()

extension Trait where Self == ConditionTrait {
    /// Skips a suite/test unless `OFEM_INTEGRATION=1` AND all required
    /// workspace/token env vars are present. Integration tests hit a live Fabric
    /// workspace; they cannot run in the host-less unit pass.
    ///
    /// tests-22: checking all required vars here prevents the "red test instead
    /// of skip" failure when the env is partially configured.
    static var integration: Self {
        .enabled(
            if: integrationFullyConfigured,
            "set OFEM_INTEGRATION=1 with OFEM_TEST_WORKSPACE_ID, OFEM_TEST_LAKEHOUSE_ID, OFEM_TOKEN_ONELAKE, and OFEM_TOKEN_FABRIC to run live integration tests"
        )
    }

    /// Skips a suite/test unless integration is enabled AND a prepared warehouse
    /// is configured. The warehouse table is seeded out-of-band by
    /// `scripts/prep_warehouse.sql` (CI runs it before the suite).
    static var warehouse: Self {
        .enabled(
            if: integrationFullyConfigured && warehouseConfigured,
            "set OFEM_INTEGRATION=1 and OFEM_TEST_WAREHOUSE_ID (after scripts/prep_warehouse.sql) to run warehouse tests"
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
            case let .missing(name): "integration env var \(name) is not set"
            }
        }
    }

    func token(alias _: String, scope: TokenScope) async throws -> String {
        let name = switch scope {
        case .oneLake: "OFEM_TOKEN_ONELAKE"
        case .fabric: "OFEM_TOKEN_FABRIC"
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
