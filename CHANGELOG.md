# Changelog

## Unreleased

### Added
- **Menu bar numbers**: show 5h (and weekly) % next to the menu bar icon, with a warning icon near the limit. You can also hide the floating widget and use the menu bar only.

### Removed
- **Sign in with claude.ai**: Google/Apple sign-in doesn't work inside an embedded window, so this option is gone. Use *Sign in to Claude Code…* instead. Any saved claude.ai session is deleted on launch.

## v0.4.0 — more ways to link your account

### Added
- **Sign in to Claude Code… is back**: runs `claude /login` in Terminal, links automatically and
  closes the window when done
- **Sign in with claude.ai**: a new way to link an account for machines without Claude Code
  installed, or when the Keychain route to Claude Code's own login fails. Sign-in happens in an
  in-app, isolated web view; UsagePet reads only the `sessionKey` cookie from that view's own
  cookie store (never your browser's cookies) and uses it the way claude.ai's own web app does

### Changed
- Clearer Account settings with a description under each button

### Fixed
- **Refresh Now** now really refreshes: it reconnects, fetches right away and shows "Refreshing… / Updated just now / Refresh failed" in the widget footer

### Upgrading
- The app is ad-hoc signed, so macOS treats each version as a new app: expect "Open Anyway" once, and the Keychain prompt for Claude Code's login once more (choose Always Allow)
- The first time you use Sign in to Claude Code…, macOS asks to let UsagePet control Terminal — allow it so the window can close by itself

## v0.3.0 — easier install, steadier connection

### Added
- Prebuilt universal app (Apple Silicon + Intel) attached to each GitHub Release — no Xcode needed
- Homebrew: `brew install --cask bqt1089/tap/usagepet`

### Fixed
- The widget could stop updating after running for days: reading the Keychain could hang forever when macOS was waiting on an access prompt (often after Claude Code refreshed its login). It now times out, shows "waiting for Keychain access", and keeps the last numbers
- Fresh network connection after the Mac wakes, shorter request timeouts, and an automatic restart if nothing succeeds for 8 minutes

### Changed
- The app is now installed as `UsagePet.app` (was `ClaudeUsageWidget.app`)

## v0.2.0 — weekly battery

### Added
- **Weekly battery** in the widget header: shows how much of your weekly limit is left, so an empty battery means the week is used up
  - Five cells, 20% each, as milestones
  - Same colors as the weekly rim: green, then yellow at 60%, orange at 80%, red at 95%
  - The last cell blinks when low (slowly from 80%, fast from 95%); at 100% the battery is empty with a blinking red outline and `!`
  - A lightning bolt appears right after the weekly limit resets
  - Remaining percent shown next to it; hover for a tooltip with used / left
- **Battery in mini mode**, in the top-right corner

### Changed
- The header battery used to mirror the 5h bar; it now tracks the weekly limit

## v0.1.0 — first public release

UsagePet is a small macOS widget that shows your Claude Code plan limits (5-hour session and weekly) with a pixel pet whose mood follows your usage.

### Usage
- Current (5h) and Weekly usage with percent, segmented bars and live reset countdowns
- Numbers come from the same source as Claude Code's `/usage`, so they include usage from the web, desktop and other machines on the same account
- Refreshes about once a minute and right after your Mac wakes; backs off automatically if rate-limited

### Pixel Pet
- Pet mood follows 5h usage: ecstatic, happy, chill, focused, worried, stressed, panic, and asleep when limited
- Situational moods: busy (Claude Code running), sleepy (late night), celebrate (5h reset), grateful (weekly reset), lonely (not linked), dizzy (offline), confused (API rate limit)
- Weekly usage shows as a glowing rim: yellow at 60%, orange at 80%, red at 95%
- At 100% weekly the pet goes on vacation until the reset
- Mouse interactions: hover to say hi, hold still for cuddles, jiggle to tickle, click to make it laugh, rub too much and it gets dizzy, swipe fast and it falls over

### Widget
- Floats on every Space and over full-screen apps; never steals focus
- Full and mini modes, drag anywhere, remembers its position
- Adjustable size (70–160%) and background opacity
- Classic theme with plain bars, if you prefer
- Menu bar icon with show/hide, mini mode, reset position, refresh, settings and quit
- Launch at login

### Account and privacy
- No login screen: links to the Claude Code login already on your Mac, only after you click **Use Claude Code login**
- Optional: paste a token from `claude setup-token`, stored in UsagePet's own Keychain item
- Read-only: one `GET` to the usage endpoint; never calls models, refreshes or stores your token
- No analytics or telemetry; CI blocks any new network host and scans for committed secrets
- Logging out of Claude Code clears the numbers; the widget resumes after you sign in again

### Requirements
- macOS 14 Sonoma or later
- Swift 5.9+ (Xcode or Command Line Tools) to build
- Claude Code logged in on a Pro or Max plan

### Install
```sh
git clone https://github.com/bqt1089/UsagePet.git
cd UsagePet
./scripts/build-app.sh --install
```

### Known limitations
- Uses an undocumented Claude Code endpoint that may change without notice
- Using Claude Code's token from another app may not be covered by Anthropic's terms; use at your own risk
- No prebuilt, notarized app yet; build from source
- macOS only
