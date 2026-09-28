#!/usr/bin/env bash
# Build Coucou Linux release artifacts (AppImage + .deb via Tauri bundler).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/linux"
OUT="$ROOT/dist/linux"

export PATH="${HOME}/.cargo/bin:${PATH}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need cargo
need npm
need pkg-config

echo "==> Checking Linux / Tauri prerequisites (pkg-config)"
for pc in gtk+-3.0 webkit2gtk-4.1; do
  if ! pkg-config --exists "$pc"; then
    cat >&2 <<'EOF'
Missing development package for pkg-config module.

On Ubuntu/Debian, install:
  sudo apt install -y \
    build-essential curl wget file pkg-config \
    libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
    librsvg2-dev patchelf libssl-dev libsecret-1-dev libasound2-dev

See docs/linux.md for GNOME / KDE / Wayland notes.
EOF
    exit 1
  fi
done

echo "==> Frontend deps"
cd "$APP"
npm ci --ignore-scripts 2>/dev/null || npm install

echo "==> Typecheck + frontend build"
npm run typecheck
npm run build

echo "==> Ensure sounds are available for bundling"
if [[ ! -d "$APP/public/sounds" ]] || [[ -L "$APP/public/sounds" ]]; then
  mkdir -p "$APP/public"
  if [[ ! -e "$APP/public/sounds" ]]; then
    ln -sfn ../../../NotchBuddy/Resources/sounds "$APP/public/sounds"
  fi
fi

echo "==> Tauri release build (AppImage + deb when supported)"
cd "$APP"
npm run tauri build -- --bundles deb,appimage

mkdir -p "$OUT"
find "$APP/src-tauri/target/release/bundle" -type f \( -name '*.deb' -o -name '*.AppImage' -o -name '*.rpm' \) \
  -exec cp -v {} "$OUT/" \; 2>/dev/null || true

if [[ -f "$APP/src-tauri/target/release/linux" ]]; then
  cp -v "$APP/src-tauri/target/release/linux" "$OUT/coucou" || true
elif [[ -f "$APP/src-tauri/target/release/coucou" ]]; then
  cp -v "$APP/src-tauri/target/release/coucou" "$OUT/coucou" || true
fi

echo
echo "Done. Artifacts (if any) are in: $OUT"
ls -la "$OUT" 2>/dev/null || true
echo
echo "Licensing: see LICENSE-ASSETS.md before redistributing Coucou branding/sounds."
