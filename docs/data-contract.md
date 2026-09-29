# AIUsage Data Contract

This document defines the data formats and calculation rules shared between AIUsage components and with
other projects (for example Cogflux). The UI is replaceable; what is written here is the part that must not
change with it. It is language-agnostic; the Swift implementation lives in `Sources/AIUsageCore/`.

## 1. Data sources

### 1.1 Passive: Claude Code statusline mirror (primary path, free)

Claude Code passes a JSON document on stdin to the `statusLine.command` configured in `settings.json`
(docs: <https://code.claude.com/docs/en/statusline>). The hook script `aiusage-statusline.sh` writes that
JSON **verbatim** to:

```
~/Library/Application Support/AIUsage/claude-statusline.json
```

- Write method: write `claude-statusline.json.<pid>.tmp`, then `mv -f` over the target. Readers only ever see a complete file.
- Several Claude Code sessions writing concurrently is normal; quota is account-wide, so any writer's data is valid,
  but not necessarily current. See the merge rule below.
- The file's mtime is the observation time (`observedAt`). The hook adds no fields to the JSON.
- Timing is decided by Claude Code: every assistant message, `/compact`, the `refreshInterval` (set to 60s at
  install), and when a window reaches its `resets_at`. **The file does not update while no session is running.**

Read: `rate_limits`, plus `session_id` and `cost` to tell which writes carry a new API response:

```json
{
  "session_id": "dfc09c42-…",
  "cost": { "total_api_duration_ms": 9053422, "total_duration_ms": 374791088, "...": "ignored" },
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 },
    "spend_limit": { "...": "ignored; only present behind a Claude apps gateway" }
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `used_percentage` | number | **0–100** |
| `resets_at` | number | Unix seconds |
| `cost.total_api_duration_ms` | number | Grows only when the writing process makes an API call |
| `cost.total_duration_ms` | number | Wall time since the writing process started |

Absence rules (from the official docs): `rate_limits` appears only for Pro/Max subscribers and only after the
first API response in a session; `five_hour` / `seven_day` may each be absent independently; Claude Code drops a
window from the JSON once its `resets_at` has passed. A parser that finds no usable window must report
"no data" rather than fail, and the caller keeps the previous snapshot.

Other files the hook uses (same directory):

| File | Purpose |
|---|---|
| `aiusage-statusline.sh` | The hook itself, copied here by the app or by `hook/install.sh` |
| `chain-command` | The user's previous `statusLine.command`, one line; after writing the file the hook pipes the same stdin to it |
| `hide-claude-code-line` | Flag file (contents ignored). When present and nothing is chained, the hook prints nothing, so Claude Code shows no extra status line row. Re-read on every run |

### 1.2 Active: `claude -p` probe (on demand, ~500 tokens per call)

```
claude -p OK --model haiku --output-format stream-json --verbose --max-turns 1 \
  --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --tools "" --system-prompt "Reply OK." --no-session-persistence
```

Run it in an empty directory (so no project CLAUDE.md / .mcp.json is picked up). stdout is one JSON object per
line; look for `"type":"rate_limit_event"`:

```json
{"type":"rate_limit_event","rate_limit_info":{
  "unifiedWindows":{
    "five_hour":{"utilization":0.09,"resetsAt":1789707000},
    "seven_day":{"utilization":0.16,"resetsAt":1790233200}
  }}}
```

| Field | Type | Notes |
|---|---|---|
| `utilization` | number | **0–1**; multiply by 100 before entering the unified model |
| `resetsAt` | number | Unix seconds |

Notes:

- The event is emitted before the model's reply, so the reply content is irrelevant.
- Measured cost (Claude Code 2.1.274, Haiku 4.5): ~400 input + 100–200 output tokens, `total_cost_usd ≈ 0.001`.
  Pro and Max subscriptions are not billed in dollars; this consumes a negligible slice of quota.
- **Side effect**: if no 5-hour window is active, the request starts a new one. The UI must say so.
- `--setting-sources ""` also drops the `env` block of `settings.json` (proxies etc.); the caller must read it
  and inject it into the child process environment explicitly.
- Remove `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` from the environment, or a nested launch may be refused.

### 1.3 Windows not covered

Claude Code's `/usage` screen also shows a separate weekly quota for Claude Fable on Max plans. Neither
path here exposes it: the statusline JSON only ever carries `five_hour` and `seven_day`, and a Haiku probe's
`rate_limit_event` has the same two windows. A probe made **with the Fable model** additionally returns a
`seven_day_overage_included` window, whose meaning is undocumented and which would cost roughly ten times a
Haiku probe (~$0.01 API-equivalent per query). Not worth it; the Fable quota is out of scope until Claude Code
exposes it through the statusline.

### 1.4 Sources deliberately not used

- The OAuth token in the `Claude Code-credentials` Keychain item → `/api/oauth/usage`: undocumented, and
  Anthropic explicitly disallows third-party tools from using subscription OAuth.
- claude.ai web endpoints / cookies: violates the consumer terms of service.

### 1.5 DeepSeek (prepaid balance)

DeepSeek's API exposes no usage statistics, only the current balance
(`GET https://api.deepseek.com/user/balance`, Bearer API key, free, no tokens). The platform's web dashboard
has daily figures but no public API, and scraping it is out of bounds for the same reason as claude.ai.

So spend is **derived**: the app polls the balance every 5 minutes and feeds a `SpendLedger`:

- A decrease between consecutive observations is spend; an increase is a top-up and never counts as
  negative spend. Granted credit expiring shows up as spend (known blind spot).
- Only change points are stored (identical balances collapse), plus the time of the last observation.
  Samples older than 90 days are pruned, keeping the last pre-cutoff sample as a baseline.
- Burn rate = spend over the trailing 7 days ÷ the real span of history in that window; withheld until
  there is a full 24 hours of history, because a shorter span sits inside one working stretch and
  extrapolating it to a day overstates the rate. The UI labels the span the average covers ("/day (3d)").
  Run-out = balance ÷ burn rate.
- Precision is the balance's precision (¥0.01); spend below that is invisible until it accumulates.

The API key lives in `~/Library/Application Support/AIUsage/deepseek.key` with mode 0600 rather than the
Keychain: the app is ad-hoc signed, and the Keychain identifies an app by its code signature, so every
update would trigger a "wants to use your confidential information" prompt. Move it to the Keychain once
builds are Developer-ID signed.

Optional monthly budget: the calendar month becomes a `PaceWindow` (`id: deepseek.month`,
`usedPercent = spentThisMonth / budget × 100`, tolerance 3, running-out lead 2 days) and goes through the
same pace and alert code as Claude's windows.

## 2. Unified model

```
WindowKind   = five_hour | seven_day
  duration   : five_hour = 5 × 3600 s, seven_day = 7 × 86400 s

UsageWindow  { kind, usedPercent: 0–100, resetsAt: timestamp }
  startsAt   = resetsAt − duration          (Claude only reports the reset time; the start is derived)

UsageSnapshot { provider: "claude", source: statusline | probe, observedAt, windows: [UsageWindow] }

PaceWindow   { id, usedPercent: 0–100, startsAt, resetsAt, tolerance, runningOutLead }
             — the generic input to PaceCalculator and AlertTracker. Claude windows map onto it
               ("claude.five_hour", "claude.seven_day"); a DeepSeek monthly budget is "deepseek.month".

SpendLedger  { samples: [{at, balance}], lastObservedAt }  — see §1.5
```

Precision: both sources ultimately come from the API's rate-limit response headers, whose utilization is a
two-decimal fraction that appears to be **truncated** (0.186 → 0.18). Claude Code's `/usage` screen uses a
more precise internal value and rounds, so it can read up to one point higher than AIUsage. This is a
property of the source, not a bug; do not "correct" for it.

Merge rule (`UsageSnapshot.merging` with `MergePolicy`), applied whenever a new observation arrives:

1. An observation older than the current snapshot is ignored entirely.
2. Per window, a `resetsAt` more than 120 s away is another instance: usually the next one after a reset,
   but sessions signed in to different accounts (after a `/login`) report different windows side by side,
   and neither reset time says which account is in use. So another instance is taken when the reading is
   fresh (see below), or when the held window is over and the incoming one is live; otherwise it is ignored.
   Within 120 s it is the same instance, which keeps the `resetsAt` it was first seen with. Credits are
   remembered per instance (`UsageSnapshot.credits`), so switching to another account's window and back
   does not let the first account's pre-credit numbers count again.
3. A window missing from the incoming snapshot is kept only while its `resetsAt` is still in the future.
4. `observedAt` and `source` follow the incoming snapshot.

Why not "newest write wins": several Claude Code sessions share the statusline file, and an idle session
re-emits its last-known numbers every `refreshInterval` with a fresh mtime. Its `rate_limits` reflect that
session's last API response, which can be any age — a session left open overnight trails by a day on the
7-day window. Consequently `observedAt` means "last time any source reported", not "last API response".

Usage only rises inside a window instance, except that **a quota reset credit zeroes `used_percentage` and
leaves `resets_at` untouched** (confirmed 2026-09-28). The size of a drop cannot separate a credit from an
idle session, so the merge asks instead whether the reading is *fresh* — straight from an API response —
using `SessionTracker`:

- The probe is always fresh.
- A statusline write is fresh when its writer's `total_api_duration_ms` has grown since that writer's
  previous write. A writer is a process, not a session: two terminals that resumed the same session write
  under one `session_id` with separate totals (seen live), so writers are told apart by their start time,
  `observedAt − total_duration_ms` (±30 s).
- A writer seen for the first time is never fresh — nothing dates its numbers, and a resumed session may
  carry numbers from before it was closed. Writers silent for 8 days are forgotten. The tracker is persisted.

Same instance, then:

| Incoming | Result |
|---|---|
| Fresh, lower by ≥ `creditDropPoints` (5) | Taken, and recorded as the window's `creditAt` |
| Fresh, lower by less | Held — noise between sources (the probe reports a fraction, the statusline a rounded percentage) |
| Fresh, higher | Taken |
| Stale, from a writer whose last fresh reading predates `creditAt` (or unknown) | Ignored — a pre-credit number, however high |
| Otherwise stale | The higher value wins |

A re-pace checkpoint whose base is above
the current usage is deleted, not just ignored: the amount it treats as sunk has come back, and usage later
climbing past that base again must not revive a line anchored before the credit.

Paced from the window start, usage of 0% at 85% elapsed reads as `▼85` — true, but saturated for the rest
of the window. So a detected credit rebases the even-pace line itself: the budget runs from the credit to
99% at the unchanged reset, which is what the restored quota actually has to be spent in. Internally this
reuses `PaceCheckpoint` (origin = the credit, base = usage just after it, so a partial credit works too),
but it is a correction rather than a user setting — the popover shows none of the re-pace caption, Clear
button or extra ticks for it, and only a checkpoint the user set by hand does. A hand-set checkpoint takes
precedence over the credit's, and clearing it falls back to the credit's rather than to the pre-credit line. The `quotaRestored` alert (`AlertConfig.quotaRestoredDropPoints`, the same
5 points; `quotaRestoredCooldown` keeps one credit reported by two sources to one notification) notifies,
since no `windowReset` can fire here.

## 3. Pace calculation

Parameters (`PaceConfig`, defaults):

| Name | Default | Meaning |
|---|---|---|
| `targetPercent` | 99 | The usage level planned for the moment the window resets |
| `minElapsed` | 5h: 15 min, 7d: 1 h | Per window. No projection before this much time has passed since the origin (window start, or the re-pace checkpoint). A fraction of the window would hide the 7-day projection for most of a day. DeepSeek's month budget uses 12 h |
| `onTrackTolerance` | 5h: 5, 7d: 3 | Per window. |delta| within this counts as on track. The 5-hour window moves in bursts and needs slack; the 7-day window is smooth and a 5-point miss there is a day's quota |

Algorithm (`now` is the current time):

```
if now ≥ resetsAt:
    status = reset; used = budget = delta = 0; projected = runout = nil
    return

elapsedSeconds  = max(0, now − startsAt)
elapsed         = min(1, elapsedSeconds / duration)
budget          = targetPercent × elapsed
delta           = usedPercent − budget                 # >0 over pace, <0 under pace
tooEarly        = elapsedSeconds < minElapsed[kind]

if not tooEarly and elapsed > 0:
    projected   = usedPercent / elapsed                # usage at window end at the current average rate
    if usedPercent > 0 and projected > targetPercent:
        runout  = startsAt + elapsedSeconds × (targetPercent / usedPercent)   # when the target is hit
else:
    projected = runout = nil

tolerance = onTrackTolerance[kind]                     # 5 for five_hour, 3 for seven_day
status = tooEarly            ? tooEarly
       : delta >  tolerance  ? overPace
       : delta < −tolerance  ? underPace
       :                       onTrack
```

- `runout` may lie in the past (already over target); the UI shows "Exhausted".

### Re-pacing from a checkpoint

A window that was overspent early stays "over pace" until it resets, and the marker stops carrying
information. The user can set a checkpoint (`PaceCheckpoint { at, usedPercent }`, "Re-pace from now"),
which treats everything used up to `at` as sunk and spreads only the remainder over the time left. The
algorithm above runs unchanged on the shifted origin:

```
origin     = checkpoint.at            (was startsAt)
base       = checkpoint.usedPercent   (was 0)
remaining  = targetPercent − base
progress   = (now − origin) / (resetsAt − origin)
consumed   = max(0, usedPercent − base)

budget     = base + remaining × progress
delta      = usedPercent − budget
tooEarly   = now − origin < minElapsed[kind]
projected  = base + consumed / progress
runout     = origin + (now − origin) × (remaining / consumed)      # if consumed > 0 and projected > target
```

`Pace.baselineBudgetPercent` keeps the plain `targetPercent × elapsed` for display (a faint tick on the
bar), and `Pace.checkpoint` echoes the checkpoint in effect. A checkpoint that cannot shrink the problem
(`at ≥ resetsAt`, `at < startsAt`, or `usedPercent ≥ targetPercent`) is ignored. The app binds a stored
checkpoint to a window instance by its `resetsAt` (±120 s, since the two sources may differ by a second),
so it expires with the window. Menu bar marker and alerts follow the re-paced numbers.
- While `tooEarly`, `delta` is still computed and may be shown; only `projected` / `runout` are withheld.
- Stale data: flagged when nothing has confirmed the numbers for 30 min (default; a UI-layer parameter), i.e.
  since the last *fresh* reading — the probe, or a statusline write whose writer's API time grew. The snapshot's
  own `observedAt` does not count: idle sessions refresh it every minute without new information. Quota spent
  where the statusline cannot see it (claude.ai, the desktop app) is exactly what a stale flag hints at.

### Alerts

`AlertTracker` is a pure state machine fed every snapshot and clock tick; it decides which
alerts fire and dedupes them per window instance (`id` + `resetsAt`).

| Alert | Fires when | Repeats |
|---|---|---|
| `overPace` | status enters `overPace` | Only after delta has dropped to `tolerance − rearmMargin` (margin 2, capped at tolerance ⁄ 2: 5h re-arms at +3, 7d at +1.5) **and** at least `overPaceCooldown` after the last one (5h: 1 h, 7d: 6 h, DeepSeek month: 24 h). A delta hovering on the threshold therefore alerts once. |
| `runningOut` | `runoutAt` is before the reset and within `runningOutLead` (5h: 30 min, 7d: 12 h) | Once per instance |
| `windowReset` | `now` passes the `resetsAt` of an instance that was being tracked, noticed within `windowResetLateLimit` (15 min) — a reset that happened while the app was not running stays quiet | Once per instance |
| `quotaRestored` | usage in the same instance drops by `quotaRestoredDropPoints` (5) | Not within `quotaRestoredCooldown` (10 min) |

`tooEarly` suppresses everything. The tracker is `Codable` and the app persists it (and DeepSeek's low-balance
flag), so a relaunch — an update, a login — does not repeat what has already fired. State for instances more
than a day past their reset is pruned.

## 4. Text rendering (menu bar title)

`"<5h|7d> " + body [+ " ⧗" when stale]`

| status | body | example |
|---|---|---|
| no data | `—` | `5h —` |
| idle (window absent after its reset; next message starts a new one) | `↺` | `5h ↺` |
| reset (window still listed but `now ≥ resetsAt`) | `0% ↺` | `5h 0% ↺` |
| tooEarly | `<used>% ○` | `5h 3% ○` |
| overPace | `<used>% ▲<|delta|>` | `5h 42% ▲9` |
| underPace | `<used>% ▼<|delta|>` | `5h 42% ▼3` |
| onTrack | `<used>% ●` | `5h 42% ●` |

Compact mode (for crowded menu bars) reduces the title to the bare percentage: `42%`, or `—` with no data;
the window label, pace marker and stale marker are all dropped.

Percentages are rounded to integers (half up). Countdown format: `45s` / `7m` / `2h13m` / `3d 4h`; `0s` once past.

## 5. Test vectors

See `Tests/AIUsageCoreChecks/`. `ParserChecks.streamJSON` is a real captured `rate_limit_event`;
`statuslineJSON` comes from the official docs example. Reuse them directly when porting.
