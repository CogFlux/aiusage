#!/bin/bash
# Cut a release: universal .app → zip → signed Sparkle appcast → git tag → GitHub release.
#   scripts/release.sh 0.1.1
#
# The zip is uploaded twice: versioned (AIUsage-0.1.1.zip) and as AIUsage.zip so
# https://github.com/CogFlux/aiusage/releases/latest/download/AIUsage.zip is a stable link.
# Sparkle signs the zip with the EdDSA private key in the maintainer's Keychain
# (created once with generate_keys); sparkle-public-key.txt in the repo is its public half.
# Until the app is Developer-ID signed and notarized, Gatekeeper will warn on first launch;
# the release notes and the website explain the workaround.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty; commit first" >&2
  exit 1
fi

SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
if [ ! -s sparkle-public-key.txt ]; then
  echo "sparkle-public-key.txt is missing; run $SPARKLE_BIN/generate_keys first" >&2
  exit 1
fi

VERSION="$VERSION" scripts/build-app.sh --universal

ZIP="build/AIUsage-$VERSION.zip"
rm -f "$ZIP" build/AIUsage.zip
# ditto preserves the bundle structure, symlinks and the ad-hoc signature.
ditto -c -k --keepParent build/AIUsage.app "$ZIP"
cp "$ZIP" build/AIUsage.zip
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

# Publish the signed appcast alongside the archive it references. The latest release
# provides a stable URL for clients, while each appcast references a versioned archive.
APPCAST_WORK="build/appcast"
APPCAST="build/appcast.xml"
rm -rf "$APPCAST_WORK" && mkdir -p "$APPCAST_WORK"
cp "$ZIP" "$APPCAST_WORK/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/CogFlux/aiusage/releases/download/$TAG/" \
  --link "https://github.com/CogFlux/aiusage" \
  -o "$APPCAST" "$APPCAST_WORK"

git tag -a "$TAG" -m "AIUsage $VERSION"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" build/AIUsage.zip "$APPCAST" \
  --latest \
  --title "AIUsage $VERSION" \
  --notes "$(cat <<NOTES
Universal binary (Apple Silicon + Intel), macOS 14+.

**Unsigned build.** macOS will refuse to open it on first launch. Either:

- open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, or
- run \`xattr -dr com.apple.quarantine /Applications/AIUsage.app\` in Terminal.

A signed and notarized build will replace this once the project has an Apple Developer ID.

SHA-256 (\`AIUsage-$VERSION.zip\`): \`$SHA\`
NOTES
)"

echo "released $TAG — sha256 $SHA"
