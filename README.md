# AIUsage

English · [中文](README.zh-CN.md)

A macOS menu bar app that shows your Claude subscription quota (5-hour and 7-day windows) — and, optionally,
your DeepSeek balance and burn rate — together with **pace**: assuming you want to land at exactly 99% when the window resets, how much should be used by now,
how much actually is, whether you are ahead or behind, and when you would run out at the current rate.

```
5h 42% ▲9      ← 42% used, 9 points above the even-pace budget (red)
5h 42% ▼3      ← 3 points under budget (green)
5h 1% ○        ← window just started; too early to judge pace
5h 42% ●       ← within tolerance of budget (±5 for 5h, ±3 for 7d)
5h 0% ↺        ← window has reset, waiting for fresh data
5h ↺           ← no active window; your next message starts one
5h 42% ● ⧗     ← data is more than 30 minutes old
```

## Where the data comes from

| Source | Cost | Freshness |
|---|---|---|
| **Claude Code statusline hook** (default) | none | live while a session is running; refreshed every 60s when idle |
| **Query now** (button in the menu) | one tiny Haiku request, ~500 tokens ≈ $0.001 API-equivalent; included in a Max subscription | instant |

Both paths use interfaces Claude Code exposes officially. No OAuth tokens, no web scraping.
Details in [docs/data-contract.md](docs/data-contract.md).

Side effect of Query now: if no 5-hour window is currently active, the request starts a new one.

**Re-pace from now** (7-day row). Burnt 60% by Tuesday? The even-pace line will say ▲30 until Sunday,
which tells you nothing you can act on. Pressing the button treats what is used as spent and paces only
the remainder over the time left: the bar gains a dashed tick at the checkpoint and a faint one where the
original budget would be, and Budget / Delta / Projected, the menu bar marker and the notifications all
switch to the new line. It expires when the window resets; *Clear* removes it earlier.

## Updates

Packaged releases check for updates through [Sparkle](https://sparkle-project.org) (EdDSA-signed appcast at
`aiusage.cogflux.io/appcast.xml`). Toggle automatic checks or check manually in Settings → General.

## Settings

Gear icon in the menu → Settings window.

- **General**: language, which window the menu bar shows (5h / 7d), compact menu bar (just `42%`), launch at login,
  notifications (over pace, running out before the reset, 5-hour window reset) with a test button, update checks.
- **Claude Code**: hook status and install, whether the hook also prints a usage line into Claude Code's own
  status line (only when you had none of your own; toggles at the next refresh, no restart), `claude` path.

## DeepSeek

Settings → DeepSeek. Paste an API key and the app polls the free balance endpoint every 5 minutes, derives
today's / this month's spend and a per-day burn rate from balance changes, and estimates when the balance runs
out. Set a monthly budget to pace the month exactly like a Claude window (markers, notifications, menu bar
`DS 42% ▲6`). The key is stored owner-only under `~/Library/Application Support/AIUsage/` and is sent only to
`api.deepseek.com/user/balance`.

## Language

The UI defaults to English. The menu offers English / 中文 / System (Chinese when the system's preferred
language starts with `zh`). All strings live in the `Strings` table in `Sources/AIUsage/Localization.swift`,
one entry per language; a missing key is a compile error. `AIUsageCore` contains no user-facing text.

## Install

Download `AIUsage.zip` from the [latest release](https://github.com/CogFlux/aiusage/releases/latest) (universal,
macOS 14+) and move `AIUsage.app` to Applications. The build is not yet signed, so on first launch macOS blocks it:
open **System Settings → Privacy & Security → Open Anyway**, or run
`xattr -dr com.apple.quarantine /Applications/AIUsage.app`.

## Build and run

Requires macOS 14+ and a Swift toolchain (the one bundled with Command Line Tools is enough; Xcode is not needed).

```bash
swift run AIUsageCoreChecks   # run the checks
scripts/build-app.sh          # → build/AIUsage.app (add --universal for arm64 + x86_64)
scripts/release.sh 0.1.0      # tag, build universal, zip, GitHub release
open build/AIUsage.app
```

After the first launch, click **Install** in the menu to set up the hook, or from the command line:

```bash
hook/install.sh               # install / update
hook/install.sh --uninstall   # remove and restore the previous statusLine
```

Installing backs up `~/.claude/settings.json` (`settings.json.aiusage-backup-<timestamp>`). A previously
configured status line command is saved to `~/Library/Application Support/AIUsage/chain-command` and keeps running.

## Layout

```
Sources/AIUsageCore/     Pure logic, no UI dependencies: models, pace math, both parsers, text formatting (the portable part)
Sources/AIUsage/         Menu bar app: file watching, claude -p probe, hook installer, string tables, SwiftUI views
Sources/AIUsage/Resources/aiusage-statusline.sh   The hook script itself
Tests/AIUsageCoreChecks/ Checks (a standalone executable, since Command Line Tools ship no XCTest)
hook/install.sh          Command-line hook installer
scripts/build-app.sh     Builds the .app bundle
docs/data-contract.md    Data format and algorithm spec
```

## License

MIT — see [LICENSE](LICENSE).

## Roadmap

- [x] Claude: passive statusline + active `claude -p`
- [x] In-app updates (Sparkle)
- [ ] Show 5h and 7d side by side in the menu bar
- [x] DeepSeek balance, burn rate and monthly budget pace
- [ ] Customizable popover: choose which provider blocks are shown and in what order (e.g. Claude only, or DeepSeek above Claude)
- [ ] Other providers (Codex / Cursor …)
- [x] Launch at login, notifications (over pace / running out / window reset)
