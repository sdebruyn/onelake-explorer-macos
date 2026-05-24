package auth

// EntraClientID is the Microsoft Entra App Registration client ID
// embedded into OFEM builds. This is the real multi-tenant public-client
// registration owned by Sam Debruyn (display name
// "OneLake File Explorer for macOS"), with http://localhost as the
// redirect URI and "Allow public client flows" enabled. The delegated
// API permission is Azure Storage / user_impersonation.
const EntraClientID = "939b4a06-cc18-49eb-9674-a1fc041489f6"

// Scopes is the set of OAuth scopes OFEM requests. The single scope
// covers both Fabric REST and OneLake DFS (audience storage.azure.com).
var Scopes = []string{"https://storage.azure.com/user_impersonation"}

// AuthorityHostPublicCloud is the public-cloud Microsoft Entra authority
// host. Sovereign clouds (US Gov, China, Germany) are out of scope for
// MVP; see docs/auth.md.
const AuthorityHostPublicCloud = "https://login.microsoftonline.com"

// TenantHintCommon is a tenant placeholder that lets Microsoft Entra
// route a sign-in to the user's home tenant. Used when the caller does
// not know the tenant up front. See docs/auth.md.
const TenantHintCommon = "organizations"
