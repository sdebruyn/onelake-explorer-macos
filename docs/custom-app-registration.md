# Use your own Entra App Registration

OFEM ships with a multi-tenant Microsoft Entra App Registration that works out of the box for most users. In a handful of tenants the built-in registration cannot be used and you have to bring your own. This page explains when and how.

## When do you need this?

Use a custom App Registration **only** if one of the following is true for your Microsoft 365 tenant:

- Your tenant admin has not consented to the built-in OFEM app and you cannot get them to. The sign-in window opens but Microsoft returns `AADSTS650057` ("Invalid resource. The client has requested access to a resource which is not listed in the requested permissions") or `AADSTS65001` ("The user or administrator has not consented to use the application").
- Your tenant blocks third-party multi-tenant apps by default and only allows apps registered in-tenant.
- Your security team wants every Microsoft Graph / Fabric API call from this Mac to flow through an audit-tagged registration they own.

If none of the above applies, leave the **Client ID** field in *Add Account → Advanced* blank — OFEM will use the built-in registration and there is nothing to do.

## What to register

In your own tenant (the one whose data you want to access), create a new App Registration with the values below. All of them are required; OFEM's IPC flow will fail with confusing MSAL errors if any is missing.

| Setting | Value |
|---|---|
| **Name** | Anything you like, e.g. `OneLake Explorer (mac)` |
| **Supported account types** | *Accounts in this organizational directory only* (single-tenant) is fine. Multi-tenant also works. |
| **Redirect URI** | Platform **Mobile and desktop applications**, URI `http://localhost` |
| **Allow public client flows** | **Yes** (Authentication tab → Advanced settings) |
| **API permissions** | Delegated permissions, admin-consented: <br>• `https://storage.azure.com/user_impersonation` (Azure Storage) <br>• `Workspace.Read.All` (Power BI Service) <br>• `Item.Read.All` (Power BI Service) |

Once those permissions are added, click **Grant admin consent** so users in your tenant do not get a consent prompt at every sign-in.

The two Power BI scopes target the Fabric REST API for workspace and item discovery; the Azure Storage scope targets the OneLake DFS endpoint for file I/O. OFEM never asks for write or admin scopes.

## Where to find the Client ID

After saving the registration, copy the **Application (client) ID** GUID from the Overview tab. That is the value to paste into *Add Account → Advanced → Client ID*.

## Faster path — Azure CLI

If you have [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and you can sign in to the target tenant with permission to create app registrations, the steps above collapse into one snippet. Permission GUIDs are fetched live from the service principals so the script keeps working when Microsoft renumbers anything.

```bash
# Sign in to the right tenant.
az login --tenant <your-tenant-id-or-domain>

# 1. Register the app with a loopback redirect + public client flows on.
APP_ID=$(az ad app create \
  --display-name "OneLake Explorer (mac)" \
  --public-client-redirect-uris http://localhost \
  --is-fallback-public-client true \
  --query appId -o tsv)
echo "Client ID: $APP_ID"

# 2. Look up delegated permission GUIDs straight from the service principals.
STORAGE_SP="e406a681-f3d4-42a8-90b6-c2b029497af1"   # Azure Storage
PBI_SP="00000009-0000-0000-c000-000000000000"        # Power BI Service

USER_IMPERSONATION=$(az ad sp show --id $STORAGE_SP \
  --query "oauth2PermissionScopes[?value=='user_impersonation'].id | [0]" -o tsv)
WORKSPACE_READ=$(az ad sp show --id $PBI_SP \
  --query "oauth2PermissionScopes[?value=='Workspace.Read.All'].id | [0]" -o tsv)
ITEM_READ=$(az ad sp show --id $PBI_SP \
  --query "oauth2PermissionScopes[?value=='Item.Read.All'].id | [0]" -o tsv)

# 3. Add the three delegated scopes.
az ad app permission add --id $APP_ID --api $STORAGE_SP \
  --api-permissions ${USER_IMPERSONATION}=Scope
az ad app permission add --id $APP_ID --api $PBI_SP \
  --api-permissions ${WORKSPACE_READ}=Scope ${ITEM_READ}=Scope

echo "Paste this Client ID into Add Account → Advanced: $APP_ID"
```

Paste the printed Client ID into *Add Account → Advanced → Client ID*; leave Tenant blank unless you also want to pin a specific one.

The first sign-in in Add Account opens a browser; Microsoft asks you to consent to the three permissions there. That's a per-user consent, no admin needed — exactly the reason this whole page exists. If you're a tenant admin and want to skip the prompt for everyone in your tenant, add `az ad app permission admin-consent --id $APP_ID` as a final step.

## Do I need to enter the Tenant ID too?

Usually no. Leave the **Tenant** field blank and Microsoft will pick the right tenant from your sign-in. Pin a tenant only if:

- you belong to multiple tenants and want to skip the picker, or
- your registration is single-tenant **and** you want to short-circuit MSAL's home-tenant lookup.

You can enter either the tenant GUID or a verified domain (e.g. `contoso.onmicrosoft.com`).

## Cancel and try again

If the sign-in fails after you paste a Client ID, the most common causes are:

- Public client flows are not enabled. Authentication → Advanced settings → **Allow public client flows: Yes**.
- Redirect URI is missing. Authentication → Platform configurations → **Mobile and desktop applications → http://localhost**.
- Admin consent has not been granted for the three delegated permissions. API permissions → **Grant admin consent for &lt;tenant&gt;**.

Fix any of those and re-run *Add Account*; OFEM does not cache failed registrations, so the next attempt starts clean.

## Privacy note

The Client ID you supply is stored in `~/Library/Group Containers/group.dev.debruyn.ofem/config.toml` next to the account alias. It is never sent to telemetry; only the tenant GUID is — and only if telemetry is enabled (it defaults to on, but everything except tenant IDs is opt-out anyway).
