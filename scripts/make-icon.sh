#!/bin/bash
# Regenerate assets/AppIcon.icns from scripts/make-icon.swift.
# Needs only the command line tools (swift, sips, iconutil) — no Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="build/icon"
SET="$WORK/AppIcon.iconset"
rm -rf "$WORK" && mkdir -p "$SET"

swift scripts/make-icon.swift "$WORK/AppIcon-1024.png"

for px in 16 32 128 256 512; do
  sips -z $px $px "$WORK/AppIcon-1024.png" --out "$SET/icon_${px}x${px}.png" >/dev/null
  double=$((px * 2))
  sips -z $double $double "$WORK/AppIcon-1024.png" --out "$SET/icon_${px}x${px}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns"
