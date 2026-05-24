# Sign in

```bash
ofem login
```

OFEM opens your browser at Microsoft sign-in. After you authenticate, you pick a short alias:

```
Name this account [work]:
```

That alias becomes the Finder entry `OneLake — <alias>` (on disk: `~/Library/CloudStorage/OneLake-<alias>/`). Pick something memorable.

## Add another account

Run `ofem login` again. You can add accounts from different tenants. Each gets its own alias and its own folder.

## Listing and switching

```bash
ofem account list
ofem account default work
```

## Signing out

```bash
ofem account remove work
```

Your data in OneLake is untouched.

## Without a browser (SSH)

```bash
ofem login --device-code
```

OFEM prints a URL and an 8-character code. Open the URL on another device, paste the code, done.

## If sign-in expires

After a long idle period your tenant may require re-authentication. The OneLake menu-bar icon shows a small badge when that happens. Run `ofem login --account <alias>` to refresh.
