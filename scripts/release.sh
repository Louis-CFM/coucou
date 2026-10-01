#!/usr/bin/env bash
# Usage: ./scripts/release.sh 0.1.1
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/alfred-release-$VERSION"
APP="$BUILD_DIR/Alfred.app"
ZIP="$BUILD_DIR/Alfred.zip"

# ── 1. Find Developer ID identity ─────────────────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(Developer ID Application[^"]*\)".*/\1/')
if [ -z "$IDENTITY" ]; then
  echo "error: No 'Developer ID Application' certificate found. Install it via Xcode → Settings → Accounts." >&2
  exit 1
fi
echo "Signing with: $IDENTITY"

# ── 2. xcodegen + Release build ───────────────────────────────────────────────
cd "$REPO_ROOT/NotchBuddy"
xcodegen generate
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

xcodebuild \
  -project NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration Release \
  build \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"

# ── 3. Zip + notarize ─────────────────────────────────────────────────────────
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile alfred-notary --wait

# ── 4. Staple + verify ────────────────────────────────────────────────────────
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

# ── 5. Re-zip (with stapled app) ──────────────────────────────────────────────
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release zip ready: $ZIP"

# ── 6. Tag + GitHub release ───────────────────────────────────────────────────
cd "$REPO_ROOT"
git tag "v$VERSION"
git push origin "v$VERSION"

gh release create "v$VERSION" "$ZIP" \
  --repo Patriot5701/alfred \
  --title "Alfred $VERSION" \
  --notes "$(cat <<EOF
## Install

Download **Alfred.zip**, unzip and move **Alfred.app** to \`/Applications\`. Launch — no extra steps needed.

## Build from source

\`\`\`bash
brew install xcodegen
git clone https://github.com/Patriot5701/alfred.git
cd alfred/NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
\`\`\`
EOF
)"

echo "✓ v$VERSION released: https://github.com/Patriot5701/alfred/releases/tag/v$VERSION"
