# Security

UsagePet handles either a Claude Code OAuth access token or a claude.ai web session key, so it is
built to do as little as possible with either.

## What the app does with your token

- Reads it only after you click **Use Claude Code login** (or paste one in Settings).
- Uses it only as the `Authorization` header of one read-only `GET` request to
  `https://api.anthropic.com/api/oauth/usage`, about once a minute.
- Never logs it, writes it to disk, refreshes it, or sends it to any other host.
- A pasted token is stored only in UsagePet's own macOS Keychain item.

## What the app does with a claude.ai session (Sign in with claude.ai)

- The `sessionKey` cookie is a full web session for your claude.ai account — anyone with it can
  act as you on claude.ai, so it is treated with the same care as a password.
- Sign-in happens inside an in-app `WKWebView` using a fresh, **non-persistent** cookie store
  (`WKWebsiteDataStore.nonPersistent()`). It has no access to Safari's, Chrome's, or any other
  app's cookies, and its own cookies are discarded when the sign-in window closes.
- UsagePet reads the `sessionKey` cookie only from that isolated web view's own cookie store —
  it never reads the system keychain-backed cookie stores that browsers use.
- The captured session key is used only as a `Cookie` header on read-only `GET` requests to
  `https://claude.ai/api/organizations` and `https://claude.ai/api/organizations/{id}/usage`
  (and, best-effort, `https://claude.ai/api/account` for display), about once a minute.
- It is stored only in UsagePet's own macOS Keychain item, separate from the Claude Code token,
  and is never logged, printed, or sent to any other host.
- Click **Unlink** in Settings to delete it immediately.

There is no analytics, telemetry or auto-update, and no other network traffic.
CI enforces this: `scripts/check-network-hosts.sh` fails the build if the code references
any host outside a short allowlist.

## Only install from the official repository

Because the code is MIT-licensed, anyone can publish a modified copy. A malicious fork could
send your token elsewhere. Build UsagePet only from this repository, and review changes to
`Sources/ClaudeUsageCore/UsageClient.swift` and `CredentialsProvider.swift` before updating.

macOS asks for Keychain access again whenever the app binary changes. If you see that prompt
without having rebuilt or updated UsagePet yourself, click **Deny**.

## Revoking access

- Click **Unlink** in Settings to stop all requests and delete whichever credential is stored
  (Claude Code token, pasted token, or claude.ai session key).
- **Claude Code login**: remove UsagePet from the `Claude Code-credentials` item in Keychain
  Access (Access Control tab), or run `claude /logout` to invalidate the token itself.
- **Sign in with claude.ai**: sign out of claude.ai in a browser (or change your password) to
  invalidate the session server-side, in addition to clicking **Unlink**.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private
[security advisory](../../security/advisories/new) form on this repository instead.
