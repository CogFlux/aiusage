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
- Several Claude Code sessions writing concurrently is normal; quota is account-wide, so any writer's data is valid.
  **The file with the newest mtime wins.**
- The file's mtime is the observation time (`observedAt`). The hook adds no fields to the JSON.
- Timing is decided by Claude Code: every assistant message, `/compact`, the `refreshInterval` (set to 60s at
  install), and when a window reaches its `resets_at`. **The file does not update while no session is running.**

Only `rate_limits` is read:

```json
{
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
  Max subscriptions are not billed in dollars; this consumes a negligible slice of quota.
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

## 2. Unified model

```
WindowKind   = five_hour | seven_day
  duration   : five_hour = 5 × 3600 s, seven_day = 7 × 86400 s

UsageWindow  { kind, usedPercent: 0–100, resetsAt: timestamp }
  startsAt   = resetsAt − duration          (Claude only reports the reset time; the start is derived)

UsageSnapshot { provider: "claude", source: statusline | probe, observedAt, windows: [UsageWindow] }
```

Precision: both sources ultimately come from the API's rate-limit response headers, whose utilization is a
two-decimal fraction that appears to be **truncated** (0.186 → 0.18). Claude Code's `/usage` screen uses a
more precise internal value and rounds, so it can read up to one point higher than AIUsage. This is a
property of the source, not a bug; do not "correct" for it.

Merge rule (`UsageSnapshot.merging`), applied whenever a new observation arrives from either source:

1. An observation older than the current snapshot is ignored entirely.
2. Per window: if `resetsAt` is unchanged (same window instance), the **higher** `usedPercent` wins — usage is
   monotonic within a window. If `resetsAt` differs, the window has reset and the incoming value wins.
3. A window missing from the incoming snapshot is kept only while its `resetsAt` is still in the future.
4. `observedAt` and `source` follow the incoming snapshot.

Why not "newest write wins": several Claude Code sessions share the statusline file, and an idle session
re-emits its last-known numbers every `refreshInterval` with a fresh mtime. Its `rate_limits` reflect that
session's last API response, so the newest write is not the newest truth. Consequently `observedAt` means
"last time any source reported", not "last API response".

## 3. Pace calculation

Parameters (`PaceConfig`, defaults):

| Name | Default | Meaning |
|---|---|---|
| `targetPercent` | 99 | The usage level planned for the moment the window resets |
| `minElapsedFraction` | 0.05 | No projection below this window progress |
| `minElapsedSeconds` | 900 | No projection below this elapsed time |
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
tooEarly        = elapsed < minElapsedFraction  or  elapsedSeconds < minElapsedSeconds

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
- While `tooEarly`, `delta` is still computed and may be shown; only `projected` / `runout` are withheld.
- Stale data: `now − observedAt > 30 min` is flagged stale (default; a UI-layer parameter).

## 4. Text rendering (menu bar title)

`"<5h|7d> " + body [+ " ⧗" when stale]`

| status | body | example |
|---|---|---|
| no data | `—` | `5h —` |
| reset | `0% ↺` | `5h 0% ↺` |
| tooEarly | `<used>%` | `5h 3%` |
| overPace | `<used>% ▲<|delta|>` | `5h 42% ▲9` |
| underPace | `<used>% ▼<|delta|>` | `5h 42% ▼3` |
| onTrack | `<used>% ●` | `5h 42% ●` |

Compact mode (for crowded menu bars) reduces the title to the bare percentage: `42%`, or `—` with no data;
the window label, pace marker and stale marker are all dropped.

Percentages are rounded to integers (half up). Countdown format: `45s` / `7m` / `2h13m` / `3d 4h`; `0s` once past.

## 5. Test vectors

See `Tests/AIUsageCoreChecks/`. `ParserChecks.streamJSON` is a real captured `rate_limit_event`;
`statuslineJSON` comes from the official docs example. Reuse them directly when porting.
