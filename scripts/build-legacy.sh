#!/bin/bash
# Legacy build: same project, lower macOS deployment target, set from the
# command line so project.yml (the macOS 15 default build) stays untouched.
# Unsigned Release build without the iPhone link (it needs signed iCloud entitlements).
# Usage: scripts/build-legacy.sh [12.0|13.0|14.0]   (default 12.0, the lowest that builds:
#        Mochi is drawn with Canvas/TimelineView, macOS 12+)
set -eo pipefail
TARGET="${1:-12.0}"
case "$TARGET" in
  12|12.*|13|13.*|14|14.*) ;;
  *) echo "usage: $0 [12.0|13.0|14.0] — macOS 15+ uses the normal build" >&2; exit 1 ;;
esac
cd "$(dirname "$0")/.."
(cd NotchBuddy && xcodegen)
mkdir -p NotchBuddy/build
xcodebuild \
  -project NotchBuddy/NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration Release \
  -derivedDataPath NotchBuddy/build \
  build \
  MACOSX_DEPLOYMENT_TARGET="$TARGET" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS= \
  PROVISIONING_PROFILE_SPECIFIER= \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS= 2>&1 | tee NotchBuddy/build/legacy.log
# Ad-hoc signature: Apple Silicon refuses to launch unsigned code.
codesign --force --deep --sign - NotchBuddy/build/Build/Products/Release/Coucou.app
echo "Built NotchBuddy/build/Build/Products/Release/Coucou.app (macOS $TARGET+)"
