#!/usr/bin/env bash
set -euo pipefail
# Run inside the project's Fedora build container, with /work as this checkout.
# Preserve the exact upstream relay the user reviewed and trusted. Neither npm
# prebuild nor a local cargo-hook binary may silently replace it.
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir/windows"
relay="$project_dir/.build/upstream/coucou-hook"
printf '%s  %s\n' '92bf5488ce4ff290d4573ceca24ad3d3e63520d1c16cd30b22073bffe14b8b67' "$relay" | sha256sum -c -
mkdir -p target/release
install -m 755 "$relay" target/release/coucou-hook
node node_modules/@tauri-apps/cli/tauri.js build --config src-tauri/tauri.linux.conf.json --config ../linux/tauri.fork.conf.json --bundles rpm
printf '%s  %s\n' '92bf5488ce4ff290d4573ceca24ad3d3e63520d1c16cd30b22073bffe14b8b67' target/release/coucou-hook | sha256sum -c -
