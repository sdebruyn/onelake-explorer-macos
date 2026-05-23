package auth

// PlaceholderClientID is the Microsoft Entra App Registration client ID
// embedded into source builds. It MUST be replaced with the real OFE
// App Registration GUID before the first signed/notarized release.
// Tracked at https://github.com/sdebruyn/onelake-explorer-macos/issues
// (label: area:auth).
const PlaceholderClientID = "00000000-0000-0000-0000-000000000000"

// Scopes is the set of OAuth scopes OFE requests. The single scope
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
