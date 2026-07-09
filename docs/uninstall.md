# Uninstall

## Keep your cache and sign-in state

```bash
brew uninstall --cask ofem
```

Removes the app. Your local cache and sign-in state stay on disk so a future re-install picks up where you left off.

## Remove everything

```bash
brew uninstall --cask --zap ofem
```

Deletes the local cache and config. It cannot reach the macOS Keychain, so your MSAL sign-in tokens survive it — sign out of each account in the app first, or remove the `dev.debruyn.ofem` Keychain items by hand, if you want those gone too.

## Revoke access in your tenant

Uninstalling the app does not revoke OFEM's OAuth grant in your Microsoft Entra tenant. To revoke:

1. Open [myapplications.microsoft.com](https://myapplications.microsoft.com).
2. Find "OneLake Explorer for macOS".
3. Click **Manage** -> **Revoke**.
