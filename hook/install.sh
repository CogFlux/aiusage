#!/bin/bash
# CLI installer for the AIUsage statusline hook (the app has an equivalent button).
#
#   hook/install.sh            install / update
#   hook/install.sh --uninstall
#
# What it does:
#   1. copies Sources/AIUsage/Resources/aiusage-statusline.sh to
#      ~/Library/Application Support/AIUsage/aiusage-statusline.sh
#   2. backs up ~/.claude/settings.json to settings.json.aiusage-backup-<timestamp>
#   3. if a different statusLine.command was configured, saves it to
#      ~/Library/Application Support/AIUsage/chain-command so the hook keeps running it
#   4. points statusLine.command at the hook (single-quoted: Claude Code runs the
#      command through a shell and "Application Support" contains a space), refreshInterval 60
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO/Sources/AIUsage/Resources/aiusage-statusline.sh"
DIR="${AIUSAGE_DIR:-$HOME/Library/Application Support/AIUsage}"
HOOK="$DIR/aiusage-statusline.sh"
CHAIN="$DIR/chain-command"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

mkdir -p "$DIR" "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.aiusage-backup-$(date +%Y%m%d-%H%M%S)"

if [ "${1:-}" = "--uninstall" ]; then
  python3 - "$SETTINGS" "$HOOK" "$CHAIN" <<'PY'
import json, sys, os
settings_path, hook, chain = sys.argv[1:4]
with open(settings_path) as f:
    s = json.load(f)
sl = s.get("statusLine") or {}
if sl.get("command") in (hook, f"'{hook}'"):
    if os.path.exists(chain) and os.path.getsize(chain) > 0:
        with open(chain) as f:
            s["statusLine"] = {"type": "command", "command": f.read().strip()}
    else:
        s.pop("statusLine", None)
    with open(settings_path, "w") as f:
        json.dump(s, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("statusLine restored")
else:
    print("hook was not the active statusLine; settings untouched")
PY
  rm -f "$HOOK" "$CHAIN"
  echo "uninstalled"
  exit 0
fi

install -m 755 "$SRC" "$HOOK"

python3 - "$SETTINGS" "$HOOK" "$CHAIN" <<'PY'
import json, sys
settings_path, hook, chain = sys.argv[1:4]
with open(settings_path) as f:
    s = json.load(f)
sl = s.get("statusLine") or {}
prev = sl.get("command")
quoted = f"'{hook}'"
if prev and prev not in (hook, quoted):
    with open(chain, "w") as f:
        f.write(prev + "\n")
    print(f"chained previous status line: {prev}")
s["statusLine"] = {"type": "command", "command": quoted, "refreshInterval": 60}
with open(settings_path, "w") as f:
    json.dump(s, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

echo "installed: $HOOK"
echo "data file: $DIR/claude-statusline.json (appears after the next Claude Code response)"
