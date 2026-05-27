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

Also deletes the local cache, the daemon's config, and your sign-in state.

## Revoke access in your tenant

Uninstalling the app does not revoke OFEM's OAuth grant in your Microsoft Entra tenant. To revoke:

1. Open [myapplications.microsoft.com](https://myapplications.microsoft.com).
2. Find "OneLake Explorer for macOS".
3. Click **Manage** → **Revoke**.
