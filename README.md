# UsagePet

**A tiny pixel pet that lives on your Mac and shows your Claude Code usage limits in real time.**

![UsagePet demo](docs/media/demo.gif)

UsagePet floats on top of your screen as a little LCD gadget. The pet's mood follows your
5-hour session usage, the rim glows when your weekly limit gets tight, and when the week is
used up the pet simply goes on vacation until the reset.

> Unofficial side project. Not affiliated with, endorsed by, or supported by Anthropic.
> "Claude" and "Claude Code" are trademarks of Anthropic.

```sh
brew install --cask bqt1089/tap/usagepet
```

or download the app from [Releases](https://github.com/bqt1089/UsagePet/releases/latest).

## Features

- **Current (5h) and Weekly** usage with percent, pixel bars and reset countdowns
- **Pet mood follows your 5h usage**: ecstatic, happy, chill, focused, worried, stressed, panic, and asleep once you're limited
- **Situational moods**: busy (Claude Code running), sleepy (late night), celebrate (5h reset), grateful (weekly reset), lonely (not linked), dizzy (offline), confused (API rate limit)
- **Weekly warnings on the rim**: yellow at 60%, orange at 80%, red at 95%, with a light running around the edge
- **Weekly battery** in the header (and in mini mode): cells drain as your weekly limit is used, blink when low, and show a bolt after the reset
- **Vacation scene** when your weekly limit hits 100%
- **Play with the pet**: hover to say hi, keep the pointer still for cuddles, jiggle to tickle, click to make it laugh, rub too much and it gets dizzy, swipe fast and it falls over
- Floating widget on every Space and over full-screen apps; never steals focus
- **Mini mode**, adjustable size (70–160%) and background opacity
- Classic theme if you prefer plain bars
- Native Swift/SwiftUI, no third-party dependencies

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- No Xcode needed for Homebrew or the download; building from source needs Swift 5.9+ (`xcode-select --install`)
- Either [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in on a Pro or
  Max plan, or just a claude.ai account (Sign in with claude.ai, no Claude Code install needed)

## Install

**Homebrew** (recommended):

```sh
brew install --cask bqt1089/tap/usagepet
```

Upgrade with `brew upgrade --cask usagepet`, remove with `brew uninstall --cask usagepet`.

**Or download**: grab `UsagePet-<version>.zip` from [Releases](https://github.com/bqt1089/UsagePet/releases), unzip, and move `UsagePet.app` to Applications.

No Xcode needed either way. UsagePet runs from the menu bar (no Dock icon).

**First launch:** UsagePet isn't notarized yet, so macOS blocks it the first time. Open it once, then go to
**System Settings → Privacy & Security** and click **Open Anyway**. Only needed once per version.
Prefer Terminal? `xattr -dr com.apple.quarantine /Applications/UsagePet.app`

**Build from source** (needs Swift 5.9+, Xcode or Command Line Tools):

```sh
git clone https://github.com/bqt1089/UsagePet.git
cd UsagePet
./scripts/build-app.sh --install
```

First run: three ways to link an account.

- **Use Claude Code login**: already signed in to Claude Code on this Mac? Reuse that sign-in. If
  macOS asks for Keychain access, choose **Always Allow**. Numbers appear within a few seconds.
- **Sign in to Claude Code…** (recommended if you're not already signed in): opens Terminal and runs
  `claude /login`. Approve in your browser (no need to sign in again if you already are). UsagePet
  links and closes Terminal automatically — you never have to switch back to it.
- **Sign in with claude.ai…**: no Claude Code? Sign in to claude.ai in a UsagePet window. The web
  session lasts about 30 days, then you sign in again. UsagePet only reads the `sessionKey` cookie
  from that window's own, isolated session — it never touches your browser's cookies. Google sign-in
  can be blocked inside this window; if so, use **Continue with email** instead, which sends you a
  sign-in code.

Enable **Settings → General → Launch at Login** to start it automatically.

## Using it

- **Menu bar icon**: show/hide the widget, Mini Mode, Reset Widget Position, Refresh Now, Settings, Quit.
- **Widget**: drag to move, `–` to minimize, double-click to switch between full and mini, right-click for more.
- **Settings → Appearance**: theme (Pixel Pet or Classic), widget size (70–160%), background opacity.
- **Settings → Account**: link with your Claude Code login, run Sign in to Claude Code…, sign in
  with claude.ai, paste a token, or unlink.

## How it works

UsagePet supports two ways to read your usage, and never asks for your password.

**Claude Code login**: reuses the login you already have in Claude Code.

1. After you click **Use Claude Code login**, it reads the OAuth access token that Claude Code
   stores in your macOS Keychain.
2. About once a minute it sends one read-only request to the same usage endpoint that
   Claude Code's `/usage` command uses.
3. It shows the returned percentages and reset times. Countdowns tick locally.

**Sign in to Claude Code…**: runs `claude /login` for you, then links automatically.

1. Clicking **Sign in to Claude Code…** opens Terminal and runs `claude /login` there, so it works
   even if you weren't signed in yet.
2. UsagePet watches Claude Code's own credentials (never the token itself, only a fingerprint of it)
   until they change, then links this app the same way **Use Claude Code login** does.
3. It closes the Terminal window for you — you never have to switch back to it.

**Sign in with claude.ai**: for machines without Claude Code, or when the Keychain route fails.

1. Clicking **Sign in with claude.ai…** opens claude.ai's own login page inside an in-app, isolated
   web view — a private, non-persistent session with no access to your Safari/Chrome cookies.
2. Once you're signed in, UsagePet reads the `sessionKey` cookie from that web view's own cookie
   store only, then closes the window.
3. It uses that cookie the same way claude.ai's own web app does: one request to find your
   organization, then about once a minute a read-only usage request, both to `claude.ai`.

## Privacy

- The Claude Code token is only used for that request's `Authorization` header, and the claude.ai
  `sessionKey` only as a `Cookie` header. Neither is ever logged, written to disk unencrypted, or
  sent anywhere other than `api.anthropic.com` / `claude.ai`.
- No analytics, telemetry, or update checks. No other network traffic (enforced in CI).
- The "Claude Code running" mood only checks file modification times under
  `~/.claude/projects`; it never reads their contents.
- **Unlink** in Settings stops all requests.

## Security

- **Only build from this repository.** Forks can be modified to steal your token.
- If macOS asks for Keychain access when you haven't just rebuilt or updated UsagePet, click **Deny**.
- CI checks every change for unexpected network hosts and committed secrets.

See [SECURITY.md](SECURITY.md) for details and how to report a vulnerability.

## Caveats

- The usage endpoint is **undocumented**. It can change or disappear at any time, and the
  widget will then show its last known values until it's updated.
- Using Claude Code's token from another app may not be covered by Anthropic's terms.
  Review them and use this at your own risk.
- UsagePet does not refresh tokens. If Claude Code's token expires, open Claude Code once
  and the widget picks up the new one.
- If you log out of Claude Code, the widget clears its numbers and asks you to sign in again.
  It resumes on its own after you log back in.

## Development

```sh
swift test                       # core logic tests (also run on Linux)
swift run                        # run from source
./scripts/build-app.sh           # build build/ClaudeUsageWidget.app
```

`ClaudeUsageCore` holds the platform-independent logic (API client, parser, mood engine);
`ClaudeUsageWidget` is the SwiftUI/AppKit app. More detail in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

Contributions welcome, especially new pet skins and moods.

## License

[MIT](LICENSE) © 2026 Toan Bui. The bundled Silkscreen font is under the SIL Open Font License.
