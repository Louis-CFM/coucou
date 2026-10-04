#!/usr/bin/env bash
# Builds, notarizes and publishes Coucou for macOS (GitHub build).
#
#   ./scripts/release.sh 0.1.2            build, sign, notarize, staple, tag, publish
#   ./scripts/release.sh 0.1.2 --finish   finish after an interrupted notarization wait
#
# Run it from a clean checkout of main. CFBundleShortVersionString in
# NotchBuddy/project.yml must match the version, and CHANGELOG.md needs a
# "## <version>" section: it becomes the release notes.
set -euo pipefail

VERSION="${1:?Usage: $0 <version> [--finish]}"
MODE="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/coucou-release-$VERSION"
APP="$BUILD_DIR/Coucou.app"
ZIP="$BUILD_DIR/Coucou.zip"
COMMIT_FILE="$BUILD_DIR/commit"
TAG="v$VERSION"

die() { echo "error: $*" >&2; exit 1; }

case "$MODE" in
  ""|--finish) ;;
  *) die "unknown option '$MODE' (the only option is --finish)" ;;
esac

cd "$REPO_ROOT"

# ── Checks shared by both modes ───────────────────────────────────────────────
command -v gh >/dev/null || die "gh is not installed (brew install gh)"

# The "## <version>" section of CHANGELOG.md, without leading or trailing blank lines.
CHANGES=$(awk -v head="## $VERSION" '
  index($0, head " ") == 1 || $0 == head { found = 1; next }
  found && /^## / { exit }
  found {
    if ($0 ~ /^[ \t\r]*$/) { if (started) blanks++; next }
    while (blanks > 0) { print ""; blanks-- }
    print; started = 1
  }
' CHANGELOG.md)
[ -n "$CHANGES" ] || die "CHANGELOG.md has no '## $VERSION' section"

grep -q "| \[$VERSION\]" README.md || die "README.md has no row for $VERSION in the Versions table"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "tag $TAG already exists here"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists on GitHub"
fi

if [ "$MODE" != "--finish" ]; then
  # The release must match a commit: no uncommitted changes to tracked files.
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "commit or stash your changes first, the release has to match a commit"
  fi
  COMMIT=$(git rev-parse HEAD)

  # ── 1. Developer ID identity ────────────────────────────────────────────────
  # "|| true": with pipefail, grep finding nothing would end the script silently.
  IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(Developer ID Application[^"]*\)".*/\1/' || true)
  [ -n "$IDENTITY" ] || die "no 'Developer ID Application' certificate found. Install it via Xcode → Settings → Accounts."
  echo "Signing with: $IDENTITY"

  # ── 2. xcodegen + Release build ─────────────────────────────────────────────
  cd "$REPO_ROOT/NotchBuddy"
  xcodegen generate
  PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  [ "$PLIST_VERSION" = "$VERSION" ] || die "the app is version $PLIST_VERSION, not $VERSION: update CFBundleShortVersionString in NotchBuddy/project.yml"

  rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
  echo "$COMMIT" > "$COMMIT_FILE"

  xcodebuild \
    -project NotchBuddy.xcodeproj \
    -scheme NotchBuddy \
    -configuration Release \
    build \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR"

  # ── 3. Zip + notarize ───────────────────────────────────────────────────────
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo
  echo "Sending to Apple for notarization. If you stop the wait (Ctrl+C), Apple keeps going:"
  echo "  check it with  xcrun notarytool history --keychain-profile coucou-notary"
  echo "  once Accepted  ./scripts/release.sh $VERSION --finish"
  echo
  xcrun notarytool submit "$ZIP" --keychain-profile coucou-notary --wait \
    || die "notarization failed: see xcrun notarytool log <id> --keychain-profile coucou-notary (the id is printed above)"
  cd "$REPO_ROOT"
else
  [ -d "$APP" ] && [ -f "$COMMIT_FILE" ] || die "nothing to finish in $BUILD_DIR, run ./scripts/release.sh $VERSION first"
  COMMIT=$(cat "$COMMIT_FILE")
fi

# ── 4. Staple + verify ────────────────────────────────────────────────────────
xcrun stapler staple "$APP" \
  || die "stapling failed: Apple has not accepted the build yet. Check xcrun notarytool history --keychain-profile coucou-notary, then run ./scripts/release.sh $VERSION --finish"
spctl -a -vv "$APP"

# ── 5. Re-zip (with the stapled app) ──────────────────────────────────────────
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release zip ready: $ZIP"

# ── 6. Tag the built commit + GitHub release ──────────────────────────────────
NOTES="Coucou $VERSION for macOS 15 or later (Apple silicon and Intel).

Signed with a Developer ID and notarized by Apple.

## What's new

$CHANGES

## Install

1. Download Coucou.zip below and unzip it.
2. Move Coucou.app to your Applications folder, replacing the old one if you have it.
3. Launch it, and click Open when macOS asks you to confirm.

Linux and Windows: see the [README](https://github.com/Louis-CFM/coucou#readme)."

echo
echo "──────── Release notes ────────"
echo "$NOTES"
echo "───────────────────────────────"
echo
read -r -p "Tag $(git rev-parse --short "$COMMIT") as $TAG and publish this release? [y/N] " ANSWER
case "$ANSWER" in
  y|Y|yes|oui|o|O) ;;
  *) die "stopped before tagging. Run ./scripts/release.sh $VERSION --finish to publish later." ;;
esac

git tag "$TAG" "$COMMIT"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" \
  --repo Louis-CFM/coucou \
  --title "Coucou $VERSION" \
  --latest \
  --notes "$NOTES"

echo "✓ $TAG released: https://github.com/Louis-CFM/coucou/releases/tag/$TAG"
