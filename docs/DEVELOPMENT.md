# UsagePet — Development notes

UsagePet is a macOS menu-bar agent app showing Claude Code usage (session / weekly
limits). `ClaudeUsageCore` is the pure-Swift engine (parsing, token lookup,
networking, poll scheduling, formatting); `ClaudeUsageWidget` is the SwiftUI
+ AppKit menu-bar UI on top of it, requiring macOS 14+.

## Run

```sh
swift run
```

or build a release binary and run it directly:

```sh
swift build -c release
.build/release/ClaudeUsageWidget
```

or build and install a real `.app` bundle (recommended — see "Build a real
app" below):

```sh
./scripts/build-app.sh --install
```

The app runs as a background "accessory" app (no Dock icon). Click the
gauge icon in the menu bar for the menu (Show/Hide Widget, Mini Mode,
Refresh Now, Settings…, Quit). The floating usage card can be dragged
anywhere, double-clicked or minimized (the small "–" button in its header)
to switch to mini mode, and right-clicked for a context menu.

## Build a real app

Running via `swift run` launches a bare command-line binary — macOS treats
that as a new, unsigned executable identity, which is why it re-prompts for
Keychain access on every rebuild and can't register for "Launch at Login".

`scripts/build-app.sh` builds a real `ClaudeUsageWidget.app` bundle instead:

```sh
./scripts/build-app.sh            # build build/ClaudeUsageWidget.app
./scripts/build-app.sh --install  # also copy to ~/Applications and open it
```

It builds a universal (arm64 + x86_64) release binary, falling back to a
native-arch build if that fails, assembles the `.app`, best-effort generates
an icon, and ad-hoc code-signs the bundle so it has one stable signing
identity across rebuilds.

**Note:** the first time you run the `.app` (as opposed to `swift run`),
macOS will treat it as a different app and may prompt again for Keychain
access to the "Claude Code-credentials" item, even if you already approved
it for the command-line binary — this is expected and only happens once per
signing identity.

## Themes

Settings → Appearance has a **Theme** picker with two options:

- **Pixel Pet** (default) — an LCD-device-styled widget with a small pixel
  pet whose mood follows your 5h "Current" usage (happy when it's low,
  increasingly worried/stressed/panicked as it climbs, asleep once fully
  limited). Claude Code actively running shows a "typing" pet; late night
  with low usage shows a sleepy pet. A just-detected reset briefly shows a
  celebration (5h) or a "thank you" (weekly). When Weekly usage hits 100%,
  the pet is replaced by a little vacation scene until it resets. Weekly
  usage between 60–99% never changes the pet itself — instead it's shown as
  a pulsing colored glow around the widget's rim (yellow → orange → red as
  it climbs). Not linked, offline, and rate-limited each get their own pet
  reaction (lonely / dizzy / confused). A debug-only "pin a mood" control in
  Settings lets you preview every mood without reproducing its usage state.
- **Classic** — the original dark usage card (percent, progress bars,
  countdowns), unchanged.

The pixel pet renders with the bundled Silkscreen font (SIL Open Font
License, `Sources/ClaudeUsageWidget/Resources/Fonts/OFL.txt`), falling back
to the system monospaced font if it can't be found or registered for any
reason. `swift run`/`swift build` copy the SwiftPM resource bundle next to
the binary automatically; `scripts/build-app.sh` copies that same bundle
into the assembled `.app`'s `Contents/Resources` so the installed app finds
it too.

## Account linking

The widget never reads your Claude login until you explicitly link an
account, in Settings → Account:

- **Use Claude Code login** — reads the same OAuth token `claude` itself
  uses (env var, Keychain, or `~/.claude/.credentials.json`). This is the
  point where macOS may show a Keychain access prompt.
- **Sign in to Claude Code…** — opens Terminal and runs `claude /login` for
  you, if you haven't logged in yet.
- **Advanced: paste token** — for a token from `claude setup-token`, stored
  in this app's own Keychain item (`io.github.bqt1089.UsagePet` /
  `oauth-token`), separate from Claude Code's.
- **Unlink** — stops polling, clears the app's own Keychain item, and clears
  the shown snapshot.

Until you link an account, the widget shows a "Use Claude Code login" button
and does not poll or touch the Keychain at all.

## Build & test

```sh
swift build
swift test
```

Note: `Sources/ClaudeUsageWidget` (the menu-bar UI) only compiles on macOS,
since it depends on AppKit/SwiftUI. On other platforms that target compiles
down to a trivial stub so the package still resolves; only
`ClaudeUsageCore` and its test suite are meaningful there, e.g.:

```sh
swift build --target ClaudeUsageCore
swift test
```

## Open in Xcode

```sh
open Package.swift
```

## Notes

- `ClaudeUsageCore` is a pure-Swift library with no third-party dependencies.
- Depending on the linked account mode, the token comes from
  `CLAUDE_CODE_OAUTH_TOKEN`, the macOS Keychain, `~/.claude/.credentials.json`
  (Claude Code login), or this app's own Keychain item (pasted token) — see
  "Account linking" above. It polls the usage endpoint roughly once a
  minute (with backoff on errors/rate limiting) only while an account is
  linked.
- The access token is never logged, printed, or persisted by this code.
- Preferences (mini mode, widget visibility, size, background opacity, the
  linked account mode, and the widget's on-screen position) are persisted
  via `UserDefaults`/window frame autosave, so they survive relaunches.
