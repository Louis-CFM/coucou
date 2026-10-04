#!/usr/bin/env bash
# iPhone plan, step 2: builds the GitHub app (fr.louisraille.NotchBuddy) the
# way release.sh does — Release optimizations, Developer ID signature — plus
# the "Coucou Developer ID" provisioning profile, the iCloud entitlements and
# the PHONE_LINK probe. Not notarized, not published: it only proves that a
# Developer ID build can talk to iCloud.
#
#   ./scripts/cloud-test-build.sh
#
# The normal release (scripts/release.sh, Release configuration) is unchanged.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/coucou-cloud-test"
APP="$BUILD_DIR/Coucou.app"
PROFILE_NAME="Coucou Developer ID"
APP_ID="256AUJ9555.fr.louisraille.NotchBuddy"
CONTAINER="iCloud.fr.louisraille.Coucou"

die() { echo "error: $*" >&2; exit 1; }

# ── 1. Developer ID identity ──────────────────────────────────────────────────
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(Developer ID Application[^"]*\)".*/\1/' || true)
[ -n "$IDENTITY" ] || die "no 'Developer ID Application' certificate found. Install it via Xcode → Settings → Accounts."
echo "Signing with: $IDENTITY"

# ── 2. Provisioning profile ───────────────────────────────────────────────────
# Xcode looks in both folders depending on its version; double-clicking a
# downloaded .provisionprofile installs it in one of them.
TMP_PLIST=$(mktemp)
trap 'rm -f "$TMP_PLIST"' EXIT
FOUND=""
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.provisionprofile; do
    [ -f "$f" ] || continue
    security cms -D -i "$f" > "$TMP_PLIST" 2>/dev/null || continue
    NAME=$(/usr/libexec/PlistBuddy -c "Print :Name" "$TMP_PLIST" 2>/dev/null || true)
    [ "$NAME" = "$PROFILE_NAME" ] || continue
    FOUND="$f"
    break 2
  done
done
[ -n "$FOUND" ] || die "no provisioning profile named '$PROFILE_NAME' is installed.
  developer.apple.com → Profiles → + → Developer ID → App ID fr.louisraille.NotchBuddy,
  name it exactly '$PROFILE_NAME', download it and double-click it."
echo "Profile: $FOUND"

PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$TMP_PLIST" 2>/dev/null || true)
[ "$PROFILE_APP_ID" = "$APP_ID" ] || die "the profile is for '$PROFILE_APP_ID', not $APP_ID"
/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$TMP_PLIST" 2>/dev/null | grep -q "$CONTAINER" \
  || die "the profile has no iCloud container $CONTAINER. Turn on iCloud (CloudKit, with that container) on the App ID fr.louisraille.NotchBuddy, then regenerate and reinstall the profile."
EXPIRY=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$TMP_PLIST")
echo "Profile expires: $EXPIRY"

# ── 3. Build ──────────────────────────────────────────────────────────────────
cd "$REPO_ROOT/NotchBuddy"
xcodegen generate
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
xcodebuild \
  -project NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration ReleaseCloud \
  build \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  -quiet \
  || die "the build failed (see the errors above)"

# ── 4. Checks ─────────────────────────────────────────────────────────────────
[ -f "$APP/Contents/embedded.provisionprofile" ] || die "the profile was not embedded in the app"
codesign --verify --deep --strict "$APP" || die "the signature does not verify"
echo
echo "Entitlements of the built app:"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - || true

echo
echo "✓ Built $APP (Developer ID, not notarized)."
echo
echo "To test:"
echo "  1. Quit any other Coucou (menu bar icon → Quit) and stop it in Xcode."
echo "  2. open $APP"
echo "  3. tail -f ~/Library/Logs/NotchBuddy/nb.log | grep PhoneLink"
echo "  4. On the iPhone, pull to refresh, then tap Send pong."
