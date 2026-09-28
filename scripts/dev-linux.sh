#!/usr/bin/env bash
# Development mode for Coucou Linux (Vite UI + optional Node hook socket).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/linux"

export PATH="${HOME}/.cargo/bin:${PATH}"

cd "$APP"
npm install

# Ensure sounds symlink for Web Audio in the browser
mkdir -p public
if [[ ! -e public/sounds ]]; then
  ln -sfn ../../../NotchBuddy/Resources/sounds public/sounds
fi

# Start a small Unix-socket hook server so Claude Code hooks work without Tauri.
# Socket: $XDG_DATA_HOME/coucou/nb.sock (same as the Rust backend).
node "$ROOT/scripts/linux-hook-dev-server.mjs" &
HOOK_PID=$!
trap 'kill $HOOK_PID 2>/dev/null || true' EXIT

echo "Hook socket server pid=$HOOK_PID"
echo "UI: http://localhost:1420  (browser / Vite)"
echo "Tip: with system GTK/WebKit deps installed, use: npm run tauri:dev"

npm run dev -- --host 127.0.0.1 --port 1420
