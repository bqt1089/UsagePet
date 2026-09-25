# Security

UsagePet handles your Claude Code OAuth access token, so it is built to do as little as possible with it.

## What the app does with your token

- Reads it only after you click **Use Claude Code login** (or paste one in Settings).
- Uses it only as the `Authorization` header of one read-only `GET` request to
  `https://api.anthropic.com/api/oauth/usage`, about once a minute.
- Never logs it, writes it to disk, refreshes it, or sends it to any other host.
- A pasted token is stored only in UsagePet's own macOS Keychain item.

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

- Click **Unlink** in Settings to stop all requests.
- Remove UsagePet from the `Claude Code-credentials` item in Keychain Access
  (Access Control tab).
- Run `claude /logout` to invalidate the token itself.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private
[security advisory](../../security/advisories/new) form on this repository instead.
