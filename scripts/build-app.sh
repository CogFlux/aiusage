#!/bin/bash
# Build a release binary and wrap it in a minimal .app bundle (no Xcode needed).
#   scripts/build-app.sh              → build/AIUsage.app for this Mac's architecture
#   scripts/build-app.sh --universal  → arm64 + x86_64 in one binary
#   open build/AIUsage.app
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUNDLE_ID="${BUNDLE_ID:-io.cogflux.aiusage}"
# Sparkle: feed URL and the EdDSA public key (sparkle-public-key.txt, committed; the private
# key stays in the release maintainer's Keychain). Without the key file the updater is off.
SU_FEED_URL="${SU_FEED_URL:-https://aiusage.cogflux.io/appcast.xml}"
SU_PUBLIC_KEY="${SU_PUBLIC_KEY:-$(cat sparkle-public-key.txt 2>/dev/null || true)}"
SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

ARCH_FLAGS=()
if [ "${1:-}" = "--universal" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
# Ask SwiftPM where the products went rather than assuming: the layout changed with the build
# system (Swift 6.4 writes .build/out/Products/Release for every architecture), and packaging a
# path that is no longer written ships whatever old binary happens to be left there.
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR=$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)
BIN="$BIN_DIR/AIUsage"
RES="$BIN_DIR/AIUsage_AIUsage.bundle"

STALE=$(find Sources Package.swift -type f -newer "$BIN" | head -1)
if [ -n "$STALE" ]; then
  echo "error: $BIN is older than $STALE; refusing to package a stale build" >&2
  exit 1
fi
if [ "${1:-}" = "--universal" ]; then
  for arch in arm64 x86_64; do
    lipo "$BIN" -verify_arch "$arch" || { echo "error: $BIN lacks $arch" >&2; exit 1; }
  done
fi

APP="build/AIUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/AIUsage"
# SwiftPM's Bundle.module accessor looks in Contents/Resources for this bundle.
cp -R "$RES" "$APP/Contents/Resources/"
# The binary links Sparkle via @rpath/../Frameworks (see Package.swift linkerSettings).
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
# App icon (Finder, notifications, Sparkle dialogs). Regenerate with scripts/make-icon.sh.
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SPARKLE_PLIST=""
if [ -n "$SU_PUBLIC_KEY" ]; then
  SPARKLE_PLIST="  <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${SU_PUBLIC_KEY}</string>
  <key>SUEnableInstallerLauncherService</key><false/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleExecutable</key><string>AIUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>AIUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
${SPARKLE_PLIST}
</dict>
</plist>
PLIST

# Ad-hoc signatures so macOS runs it locally; replace with a Developer ID for distribution.
# Sparkle's helpers inside the framework must be signed before the app that embeds them.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework" 2>/dev/null
codesign --force --sign - "$APP" >/dev/null
rm -f build/AIUsage-universal
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/AIUsage"); updater $([ -n "$SU_PUBLIC_KEY" ] && echo on || echo off))"
