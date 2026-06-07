import Testing
@testable import OfemKit

// MARK: - EntraAuthorityTests

/// Tests for ``EntraAuthorityResolver``.
@Suite("EntraAuthorityResolver")
struct EntraAuthorityTests {
    // MARK: - authority(tenantHint:)

    @Test("Nil tenant hint maps to organizations endpoint")
    func nilTenantHintMapsToOrganizations() throws {
        let url = try EntraAuthorityResolver.authority(tenantHint: nil)
        #expect(url.absoluteString == "https://login.microsoftonline.com/organizations")
    }

    @Test("Empty string tenant hint maps to organizations endpoint")
    func emptyTenantHintMapsToOrganizations() throws {
        let url = try EntraAuthorityResolver.authority(tenantHint: "")
        #expect(url.absoluteString == "https://login.microsoftonline.com/organizations")
    }

    @Test("Tenant GUID is preserved in the authority URL")
    func tenantGUIDPreserved() throws {
        let tenantID = "xxxxxxxx-1234-5678-abcd-xxxxxxxxxxxx"
        let url = try EntraAuthorityResolver.authority(tenantHint: tenantID)
        #expect(url.absoluteString == "https://login.microsoftonline.com/\(tenantID)")
    }

    @Test("Verified domain is preserved in the authority URL")
    func verifiedDomainPreserved() throws {
        let domain = "contoso.onmicrosoft.com"
        let url = try EntraAuthorityResolver.authority(tenantHint: domain)
        #expect(url.absoluteString == "https://login.microsoftonline.com/\(domain)")
    }

    // MARK: - authority(tenantID:)

    @Test("Non-empty tenantID builds correct authority URL")
    func nonEmptyTenantID() throws {
        let tenantID = "aaaabbbb-cccc-dddd-eeee-ffffffffffff"
        let url = try EntraAuthorityResolver.authority(tenantID: tenantID)
        #expect(url.absoluteString == "https://login.microsoftonline.com/\(tenantID)")
    }

    @Test("Empty tenantID falls back to organizations endpoint")
    func emptyTenantIDFallsBack() throws {
        let url = try EntraAuthorityResolver.authority(tenantID: "")
        #expect(url.absoluteString == "https://login.microsoftonline.com/organizations")
    }

    // MARK: - Constants

    @Test("Authority host constant is the public-cloud endpoint")
    func authorityHostConstant() {
        #expect(entraAuthorityHost == "https://login.microsoftonline.com")
    }

    @Test("Tenant hint common is 'organizations'")
    func tenantHintCommonConstant() {
        #expect(entraTenantHintCommon == "organizations")
    }

    @Test("OFEM client ID is set to the registered value")
    func ofemClientID() {
        #expect(ofemEntraClientID == "939b4a06-cc18-49eb-9674-a1fc041489f6")
    }

    // MARK: - TokenScope

    @Test("OneLake scopes include storage.azure.com")
    func oneLakeScopesAreCorrect() {
        let scopes = TokenScope.oneLake.scopes
        #expect(scopes == ["https://storage.azure.com/user_impersonation"])
    }

    @Test("Fabric scopes include both Workspace.Read.All and Item.Read.All")
    func fabricScopesAreCorrect() {
        let scopes = TokenScope.fabric.scopes
        #expect(scopes.contains("https://analysis.windows.net/powerbi/api/Workspace.Read.All"))
        #expect(scopes.contains("https://analysis.windows.net/powerbi/api/Item.Read.All"))
        #expect(scopes.count == 2)
    }

    @Test("LoginScopes is a single resource (OneLake only)")
    func loginScopesIsSingleResource() {
        // The Microsoft Entra v2 endpoint rejects interactive requests that
        // span more than one resource (AADSTS28000). LoginScopes must be
        // limited to the OneLake resource only.
        let scopes = TokenScope.loginScopes
        #expect(scopes == TokenScope.oneLakeScopes)
        // Verify no Fabric scope is included at login time.
        let hasFabric = scopes.contains { $0.contains("analysis.windows.net") }
        #expect(!hasFabric)
    }
}
