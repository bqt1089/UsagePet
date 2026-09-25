# Changelog

## Unreleased

### Added
- **Antigravity usage provider**: reads quota from the running Antigravity desktop app over
  its own local server (`127.0.0.1`, read-only).
- **Provider switching**: pick Claude Code or Antigravity in **Settings → Providers**, or tap
  the title on the widget to switch instantly. Exactly one provider is shown — and polled — at
  a time; switching stops the other provider's requests immediately.
- **Antigravity model groups**: while Antigravity is active, choose which group it shows —
  Auto (whichever of Gemini / Claude & GPT is closest to its limit), Gemini, or Claude & GPT —
  in **Settings → Providers**.

### Changed
- Replaced the old multi-select "Providers" toggles and "auto" source picker with a single
  provider choice. If Antigravity was previously enabled, the widget now defaults back to
  showing Claude Code until you pick Antigravity again.
- When Antigravity is active but the app isn't open (or its local API errors), the widget no
  longer falls back to Claude Code — it shows a "not open" state and keeps polling in the
  background so it recovers on its own once you open Antigravity.

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
