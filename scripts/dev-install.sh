#!/usr/bin/env bash
# Builds Orca Notch (Debug) and installs it in ~/Applications, replacing the previous copy.
#
#   ./scripts/dev-install.sh
#
# macOS keeps its permissions (Accessibility, Automation) per app path: one copy at one place
# keeps them from one build to the next.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="dev.hfps.orca-notch"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/OrcaNotchDev"
BUILT="${DERIVED}/Build/Products/Debug/Orca Notch.app"
TARGET="${HOME}/Applications/Orca Notch.app"

echo "Building (Debug)..."
cd "${REPO_ROOT}/NotchBuddy"
xcodegen >/dev/null
xcodebuild -scheme NotchBuddy -configuration Debug -derivedDataPath "${DERIVED}" -quiet build

echo "Quitting Orca Notch..."
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 1

echo "Installing in ${TARGET}..."
mkdir -p "${HOME}/Applications"
rm -rf "${TARGET}"
cp -R "${BUILT}" "${TARGET}"
open "${TARGET}"
