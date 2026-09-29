#!/usr/bin/env bash
# Coucou ↔ Hermes bridge installer.
#
# Sets up the two small servers the Coucou app talks to, and keeps them running:
#   - hermes_feed_server.py  :8645  GET /hermes/feed    (alerts the notch polls)
#   - hermes_chat_server.py  :8646  POST /chat          (chat with your agent)
#
# Usage:  ./install.sh
# Env:    HERMES_COUCCO_DIR (default ~/.hermes/coucou)
#         HERMES_FEED_PORT   (default 8645)
#         HERMES_CHAT_PORT   (default 8646)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COUCCO_DIR="${HERMES_COUCCO_DIR:-$HOME/.hermes/coucou}"
FEED_PORT="${HERMES_FEED_PORT:-8645}"
CHAT_PORT="${HERMES_CHAT_PORT:-8646}"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Coucou ↔ Hermes bridge installer"
say ""

# ── prerequisites ────────────────────────────────────────────────────────────
if ! have hermes; then
  warn "hermes not found on PATH."
  say  "    Install Hermes Agent first: https://hermes-agent.nousresearch.com"
  exit 1
fi
if ! have python3; then
  warn "python3 not found"; exit 1
fi
PY="$(command -v python3)"
ok "hermes and python3 found"

# ── files + token ────────────────────────────────────────────────────────────
mkdir -p "$COUCCO_DIR"
install -m 0644 "$SRC/hermes_feed_server.py" "$COUCCO_DIR/hermes_feed_server.py"
install -m 0644 "$SRC/hermes_chat_server.py" "$COUCCO_DIR/hermes_chat_server.py"

if [ ! -s "$COUCCO_DIR/token" ]; then
  "$PY" -c 'import secrets; print(secrets.token_urlsafe(24))' > "$COUCCO_DIR/token"
fi
chmod 600 "$COUCCO_DIR/token"
TOKEN="$(cat "$COUCCO_DIR/token")"

[ -s "$COUCCO_DIR/feed.json" ] || printf '{"updated":0,"items":[]}' > "$COUCCO_DIR/feed.json"
ok "installed to $COUCCO_DIR"

# ── firewall ─────────────────────────────────────────────────────────────────
if have ufw && sudo -n true 2>/dev/null; then
  sudo -n ufw allow "${FEED_PORT}/tcp" >/dev/null 2>&1 || true
  sudo -n ufw allow "${CHAT_PORT}/tcp" >/dev/null 2>&1 || true
  ok "opened ${FEED_PORT} and ${CHAT_PORT} in ufw"
else
  warn "open ${FEED_PORT}/tcp and ${CHAT_PORT}/tcp yourself if a firewall is active"
fi

# ── keep it running (systemd user units, else nohup) ─────────────────────────
UNITS="$HOME/.config/systemd/user"
if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
  mkdir -p "$UNITS"
  write_unit() { # name port script
    cat > "$UNITS/coucou-hermes-$1.service" <<EOF
[Unit]
Description=Coucou ↔ Hermes $1 bridge
After=network-online.target

[Service]
Type=simple
Environment=HERMES_COUCCO_DIR=$COUCCO_DIR
Environment=HERMES_$( [ "$1" = chat ] && echo CHAT || echo FEED )_PORT=$2
ExecStart=$PY $COUCCO_DIR/$3
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  }
  write_unit feed "$FEED_PORT" hermes_feed_server.py
  write_unit chat "$CHAT_PORT" hermes_chat_server.py
  systemctl --user daemon-reload
  systemctl --user enable --now coucou-hermes-feed.service coucou-hermes-chat.service >/dev/null 2>&1
  ok "services coucou-hermes-feed + coucou-hermes-chat enabled (start on boot)"
  warn "so they survive logout:  sudo loginctl enable-linger $USER"
  RESTART_HINT="systemctl --user restart coucou-hermes-chat coucou-hermes-feed"
else
  pkill -f hermes_feed_server.py >/dev/null 2>&1 || true
  pkill -f hermes_chat_server.py >/dev/null 2>&1 || true
  HERMES_COUCCO_DIR="$COUCCO_DIR" nohup "$PY" "$COUCCO_DIR/hermes_feed_server.py" >/dev/null 2>&1 &
  HERMES_COUCCO_DIR="$COUCCO_DIR" nohup "$PY" "$COUCCO_DIR/hermes_chat_server.py" >/dev/null 2>&1 &
  ok "started both servers with nohup (no systemd — they will not survive a reboot)"
  RESTART_HINT="pkill -f hermes_chat_server.py; pkill -f hermes_feed_server.py; then re-run this script"
fi

# ── verify ───────────────────────────────────────────────────────────────────
sleep 1
if curl -sf -m 5 "http://127.0.0.1:${FEED_PORT}/hermes/health" >/dev/null 2>&1; then
  ok "feed server responding on :${FEED_PORT}"
else
  warn "feed server not responding yet — check: $RESTART_HINT"
fi
if curl -s -m 5 -o /dev/null "http://127.0.0.1:${CHAT_PORT}/chat"; then
  ok "chat bridge listening on :${CHAT_PORT}"
else
  warn "chat bridge not responding yet"
fi

HOST="$(curl -4 -s -m 5 ifconfig.me 2>/dev/null || true)"
if [ -z "$HOST" ]; then HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
if [ -z "$HOST" ]; then HOST="<this-machine>"; fi
say ""
say "──────────────────────────────────────────────────────────────"
say " Paste this into Coucou → Settings → Chat → Provider → \"Hermes\""
say "──────────────────────────────────────────────────────────────"
say "  Bridge URL   http://${HOST}:${CHAT_PORT}/chat"
say "  X-Hermes-Key ${TOKEN}"
say "  Thread name  coucou"
say ""
say " Then enable the Hermes pill under Integrations (uses the same key)."
say " Health check: http://${HOST}:${FEED_PORT}/hermes/health"
say ""
say " ⚠  This bridge can run tools on this machine. Keep the key secret and"
say "    put it behind HTTPS (e.g. a Cloudflare tunnel) on untrusted networks."
say ""
say " To attach an alert feed, append items to $COUCCO_DIR/feed.json"
say " (see server/hermes/README.md for the format)."
