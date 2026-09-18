#!/bin/bash
# AIUsage statusline hook.
#
# Claude Code runs this with its status-line JSON on stdin. We mirror that JSON
# verbatim into a file the menu bar app watches, then hand the same JSON to
# whatever status line command was configured before we were installed
# (stored one line in `chain-command`), so the user's existing status line
# keeps working. With no chained command we print a small default line, unless
# the app has created the `hide-claude-code-line` flag file (Settings → Claude Code).
#
# Data contract: see docs/data-contract.md in the AIUsage repo.
set -u

DIR="${AIUSAGE_DIR:-$HOME/Library/Application Support/AIUsage}"
OUT="$DIR/claude-statusline.json"
CHAIN="$DIR/chain-command"

mkdir -p "$DIR"
input=$(cat)

# Atomic replace: readers never see a half-written file.
tmp="$OUT.$$.tmp"
if printf '%s\n' "$input" > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$OUT"
else
  rm -f "$tmp"
fi

if [ -s "$CHAIN" ]; then
  printf '%s' "$input" | bash -c "$(cat "$CHAIN")"
  exit 0
fi

# Default line when nothing is chained. Re-read on every run, so toggling the flag
# takes effect at the next status line refresh without restarting Claude Code.
[ -f "$DIR/hide-claude-code-line" ] && exit 0

# jq is optional; without it show nothing.
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$input" | jq -r '
    def pct: if . == null then "—" else "\(. | floor)%" end;
    "[\(.model.display_name // "?")] ctx \(.context_window.used_percentage | pct)"
    + (if .rate_limits then
         " · 5h \(.rate_limits.five_hour.used_percentage | pct) · 7d \(.rate_limits.seven_day.used_percentage | pct)"
       else "" end)'
fi
