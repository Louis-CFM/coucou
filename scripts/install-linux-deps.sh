#!/usr/bin/env bash
# Install Ubuntu/Debian packages required to build and run Coucou (Tauri).
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  SUDO=(sudo)
else
  SUDO=()
fi

export DEBIAN_FRONTEND=noninteractive

"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y \
  build-essential curl wget file pkg-config pkgconf \
  libwebkit2gtk-4.1-dev libgtk-3-dev \
  libayatana-appindicator3-dev librsvg2-dev \
  patchelf libssl-dev libsecret-1-dev \
  libasound2-dev \
  xdotool x11-utils \
  playerctl \
  grim wl-clipboard \
  imagemagick

# Rust toolchain PATH for this shell
if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  . "${HOME}/.cargo/env"
fi

echo
echo "OK. Verify:"
command -v pkg-config
pkg-config --modversion glib-2.0 || true
pkg-config --exists gtk+-3.0 && echo "gtk+-3.0 ok"
pkg-config --exists webkit2gtk-4.1 && echo "webkit2gtk-4.1 ok"
echo
echo "Then: cd apps/linux && npm run tauri:dev"
echo "Or package: ./scripts/build-linux.sh"
