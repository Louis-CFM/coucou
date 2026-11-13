#!/bin/bash
# Codex automatic-review filter tests — exercises the generated GitHub relay
# (nb-hook.py) embedded in HookServer.swift: pure classifier tests plus
# subprocess integration tests against an isolated temp Unix socket.
# The production socket and the real ~/.codex are never contacted.
set -euo pipefail
cd "$(dirname "$0")/.."

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  # /usr/bin/python3 is the interpreter the nb-hook wrapper itself uses; check
  # xcode-select first so machines without CLT never hit the install dialog.
  if [ -x /usr/bin/python3 ] && xcode-select -p >/dev/null 2>&1 \
     && /usr/bin/python3 -c 'import sys' >/dev/null 2>&1; then
    PY=/usr/bin/python3
  else
    PY=python3
  fi
fi

"$PY" tests/test_codex_auto_review.py
