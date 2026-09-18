#!/bin/bash
# Build a release binary and wrap it in a minimal .app bundle (no Xcode needed).
#   scripts/build-app.sh              → build/AIUsage.app for this Mac's architecture
#   scripts/build-app.sh --universal  → arm64 + x86_64 (two builds joined with lipo;
#                                        SwiftPM's --arch needs Xcode, explicit triples don't)
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

if [ "${1:-}" = "--universal" ]; then
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  mkdir -p build
  lipo -create -output build/AIUsage-universal \
    .build/arm64-apple-macosx/release/AIUsage \
    .build/x86_64-apple-macosx/release/AIUsage
  BIN="build/AIUsage-universal"
  RES=".build/arm64-apple-macosx/release/AIUsage_AIUsage.bundle"
else
  swift build -c release
  BIN=".build/release/AIUsage"
  RES=".build/release/AIUsage_AIUsage.bundle"
fi

APP="build/AIUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/AIUsage"
# SwiftPM's Bundle.module accessor looks in Contents/Resources for this bundle.
cp -R "$RES" "$APP/Contents/Resources/"
# The binary links Sparkle via @rpath/../Frameworks (see Package.swift linkerSettings).
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"

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
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleExecutable</key><string>AIUsage</string>
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
