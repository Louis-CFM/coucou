#!/usr/bin/env bash
# Build Coucou Linux release artifacts (AppImage + .deb via Tauri bundler).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/linux"
OUT="$ROOT/dist/linux"
TOTAL_STEPS=5

export PATH="${HOME}/.cargo/bin:${PATH}"
export NPM_CONFIG_PROGRESS=true
export NPM_CONFIG_LOGLEVEL=info
export CARGO_TERM_COLOR=always
export CARGO_TERM_PROGRESS_WHEN=always
export CARGO_TERM_PROGRESS_WIDTH=80

step() {
  local n="$1"
  shift
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  [$n/$TOTAL_STEPS] $*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need cargo
need npm
need pkg-config

step 1 "Checking system packages (pkg-config)"
for pc in gtk+-3.0 webkit2gtk-4.1; do
  if ! pkg-config --exists "$pc"; then
    cat >&2 <<'EOF'
Missing development package for pkg-config module.

On Ubuntu/Debian, install:
  sudo apt install -y \
    build-essential curl wget file pkg-config \
    libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
    librsvg2-dev patchelf libssl-dev libsecret-1-dev libasound2-dev

Or: ./scripts/install-linux-deps.sh

See docs/linux.md for GNOME / KDE / Wayland notes.
EOF
    exit 1
  fi
  echo "  ✓ $pc ($(pkg-config --modversion "$pc"))"
done

step 2 "Installing frontend deps (npm — may take a few minutes)"
cd "$APP"
echo "  Working directory: $APP"
if [[ -f package-lock.json ]]; then
  echo "  Running: npm ci --ignore-scripts"
  # Do not hide output — user needs to see download progress.
  if ! npm ci --ignore-scripts --progress=true --loglevel=info; then
    echo "  npm ci failed — falling back to npm install…"
    npm install --progress=true --loglevel=info
  fi
else
  echo "  Running: npm install"
  npm install --progress=true --loglevel=info
fi
echo "  ✓ node_modules ready"

step 3 "Typecheck + Vite production build"
npm run typecheck
npm run build
echo "  ✓ frontend dist ready"

step 4 "Prepare sounds for the bundle"
if [[ ! -d "$APP/public/sounds" ]] || [[ -L "$APP/public/sounds" ]]; then
  mkdir -p "$APP/public"
  if [[ ! -e "$APP/public/sounds" ]]; then
    ln -sfn ../../../NotchBuddy/Resources/sounds "$APP/public/sounds"
    echo "  linked public/sounds → NotchBuddy/Resources/sounds"
  fi
fi
echo "  ✓ sounds ok"

step 5 "Tauri release build (.deb + AppImage) — first compile can take 10–20 min"
cd "$APP"
echo "  Running: npm run tauri build -- --bundles deb,appimage"
npm run tauri build -- --bundles deb,appimage

mkdir -p "$OUT"
echo
echo "==> Collecting artifacts → $OUT"
find "$APP/src-tauri/target/release/bundle" -type f \( -name '*.deb' -o -name '*.AppImage' -o -name '*.rpm' \) \
  -exec cp -v {} "$OUT/" \; 2>/dev/null || true

if [[ -f "$APP/src-tauri/target/release/linux" ]]; then
  cp -v "$APP/src-tauri/target/release/linux" "$OUT/coucou" || true
elif [[ -f "$APP/src-tauri/target/release/coucou" ]]; then
  cp -v "$APP/src-tauri/target/release/coucou" "$OUT/coucou" || true
fi

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done. Artifacts:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ls -la "$OUT" 2>/dev/null || true
echo
echo "Licensing: see LICENSE-ASSETS.md before redistributing Coucou branding/sounds."
