#!/usr/bin/env bash
# Real local Unix sockets; no Pi settings, network, or app installation.
set -euo pipefail
cd "$(dirname "$0")/.."
node --test tests/pi-coucou-extension.test.ts
