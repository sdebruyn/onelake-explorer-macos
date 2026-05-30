# Sign in

Open the OneLake menu bar icon and choose **Add Account…**. Your browser opens at Microsoft sign-in. After you authenticate, pick a short alias for the account (for example `work`, `client-a`).

That alias becomes the Finder entry `OneLake — <alias>` (on disk: `~/Library/CloudStorage/OneLake-<alias>/`). Pick something memorable.

## Add another account

Choose **Add Account…** again from the menu. You can add accounts from different tenants. Each gets its own alias and its own folder in Finder.

## Listing and switching

Every signed-in account appears in the menu bar with its own submenu. The default account is marked with a check; switch the default from an account's submenu with **Set as Default**. There is no "active" account to switch between — each one is mounted in Finder side by side.

## Signing out

Open the account's submenu in the menu bar and choose **Sign Out…**. Your data in OneLake is untouched.

## If sign-in expires

After a long idle period your tenant may require re-authentication. The menu bar header shows a warning when that happens. Sign the account out and add it again to refresh the token.
