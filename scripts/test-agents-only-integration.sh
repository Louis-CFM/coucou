#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_REPO="$PWD"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mode-contracts.XXXXXX")"
cleanup() {
  if [[ -f "$TEST_DIR/Info.plist" ]]; then
    TASK_TEST_DOMAIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TEST_DIR/Info.plist")"
    if [[ "$TASK_TEST_DOMAIN" == local.coucou.contracts.* ]]; then
      /usr/bin/defaults delete "$TASK_TEST_DOMAIN" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
MODE="${1:-github}"
if [[ "$MODE" != github && "$MODE" != appstore ]]; then echo 'Use github or appstore' >&2; exit 2; fi
# Reuse application sources with an isolated entry point and diagnostic log sink.
# A unique test bundle domain keeps all UserDefaults writes away from Coucou.
ruby -ryaml -rsecurerandom - "$TASK_REPO" "$TEST_DIR" "$MODE" <<'RUBY'
repo, dir, mode = ARGV
base = YAML.load_file("#{repo}/NotchBuddy/project.yml")
target = {
  'type' => 'application', 'platform' => 'macOS',
  'sources' => [
    {'path' => "#{repo}/NotchBuddy/Sources", 'excludes' => ['Phone/**', 'Widgets/**', 'NotificationContent/**', 'App/NotchBuddyApp.swift', 'App/AppLog.swift']},
    {'path' => "#{repo}/tests/AgentsOnlyIntegrationTests.swift"}
  ],
  'info' => {'path' => "#{dir}/Info.plist", 'properties' => {'CFBundleIdentifier' => "local.coucou.contracts.#{SecureRandom.hex(8)}"}},
  'settings' => {'base' => {
    'PRODUCT_NAME' => 'ModeContracts', 'CODE_SIGNING_ALLOWED' => 'NO', 'CODE_SIGNING_REQUIRED' => 'NO',
    'SWIFT_VERSION' => '6.0', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' => mode == 'appstore' ? 'DEBUG APPSTORE PHONE_LINK' : 'DEBUG PHONE_LINK',
    'OTHER_SWIFT_FLAGS' => '-strict-concurrency=complete', 'SWIFT_EMIT_LOC_STRINGS' => 'NO'
  }},
  'dependencies' => [{'package' => 'FluidAudio'}]
}
File.write("#{dir}/project.yml", {'name' => 'ModeContracts', 'options' => {'deploymentTarget' => {'macOS' => '15.0'}},
  'packages' => base['packages'], 'targets' => {'ModeContracts' => target}}.to_yaml)
RUBY
xcodegen --spec "$TEST_DIR/project.yml" > "$TEST_DIR/generate.log"
xcodebuild -project "$TEST_DIR/ModeContracts.xcodeproj" -scheme ModeContracts -configuration Debug \
  -derivedDataPath "$TEST_DIR/build" -clonedSourcePackagesDirPath "${COUCOU_TEST_PACKAGES:-$TEST_DIR/packages}" \
  build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO > "$TEST_DIR/build.log" 2>&1 || {
    cat "$TEST_DIR/build.log"; exit 1;
  }
"$TEST_DIR/build/Build/Products/Debug/ModeContracts.app/Contents/MacOS/ModeContracts"
