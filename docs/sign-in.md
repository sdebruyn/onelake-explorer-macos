# Sign in

## First account

```bash
ofem login
```

OFEM opens your default browser at Microsoft's sign-in page. After you authenticate, OFEM prompts you for a short alias:

```
Name this account [work]:
```

Pick something memorable — that alias becomes the folder under `~/OneLake/`. Letters, digits, dash, underscore, dot are allowed; up to 32 characters. Avoid spaces.

After you press Enter, OFEM confirms:

```
Account 'work' added (sam@contoso.com, tenant contoso.onmicrosoft.com).
```

## Add another account

Run the same command:

```bash
ofem login
```

You can add accounts from different tenants. Each gets its own alias and its own folder.

## Headless / SSH sessions

If you're on a machine without a browser (remote SSH), use the device-code flow:

```bash
ofem login --device-code
```

OFEM prints a URL and an 8-character code:

```
To sign in, visit https://microsoft.com/devicelogin and enter the code: ABCD-EFGH
```

Open that URL on another device, paste the code, authenticate, and OFEM picks up the token automatically.

## What OFEM asks for

OFEM requests a single OAuth scope: `https://storage.azure.com/user_impersonation`. That gives it the access OneLake needs (read and write your files via the ADLS Gen2 API) and nothing more. It does NOT ask for:

- Mail or calendar access.
- Directory or user-management permissions.
- Anything outside Fabric / OneLake.

You can review or revoke OFEM's access any time at [https://myapplications.microsoft.com](https://myapplications.microsoft.com).

## Listing accounts

```bash
ofem account list
```

Shows alias, UPN, tenant, and which one is the default.

```bash
ofem account default work
```

Sets `work` as the default account used when a command needs one but you didn't pass `--account`.

## Signing out

```bash
ofem account remove work
```

Removes the alias from OFEM's config and deletes the cached token from your macOS Keychain. Your data in OneLake is untouched, and you can re-add the same account at any time.

## What about Conditional Access / MFA?

If your tenant enforces Conditional Access policies (MFA, compliant device, …), the browser flow handles them transparently. After a long idle period the cached token may expire; OFEM shows a small badge in the menu bar status icon when re-authentication is needed. Run `ofem login --account <alias>` to refresh.
