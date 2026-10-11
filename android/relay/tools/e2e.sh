#!/usr/bin/env bash
# End to end through a real relay: the Rust computer side and the Kotlin phone side, with the Cloudflare Worker (under
# `wrangler dev`, i.e. workerd on this machine) or the Node twin in between. Nothing is deployed, nothing leaves this
# computer: the relay listens on 127.0.0.1 and the credentials are fixed test values.
#
#   android/relay/tools/e2e.sh worker      # the real Worker code in workerd (default)
#   android/relay/tools/e2e.sh node        # the Node twin
#
# PHONE_CMD overrides how the Kotlin test is run (default: Gradle, as CI does). The test task is cleaned first: Gradle does not
# treat the environment as an input, so a cached "up to date" result would silently skip the test.
set -euo pipefail

MODE="${1:-worker}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PORT="${PORT:-8799}"
# base64url of 32 bytes of 0x33: the same value both test halves use as the access key.
ACCESS="MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM"
LOG="$(mktemp -d)"
export WRANGLER_SEND_METRICS=false
export COUCOU_E2E_RELAY_URL="ws://127.0.0.1:${PORT}"

cleanup() { kill "${RELAY_PID:-0}" "${PC_PID:-0}" 2>/dev/null || true; }
trap cleanup EXIT

case "$MODE" in
  worker)
    (cd "$ROOT/android/relay" && exec npx wrangler dev --ip 127.0.0.1 --port "$PORT" --var "ACCESS_KEY:$ACCESS" >"$LOG/relay.log" 2>&1) &
    RELAY_PID=$!
    ;;
  node)
    (cd "$ROOT/android/relay" && ACCESS_KEY="$ACCESS" PORT="$PORT" HOST=127.0.0.1 exec node --experimental-strip-types --no-warnings tools/dev-relay.ts >"$LOG/relay.log" 2>&1) &
    RELAY_PID=$!
    ;;
  *) echo "usage: e2e.sh [worker|node]" >&2; exit 2 ;;
esac

echo "waiting for the relay ($MODE) on port $PORT"
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -q "Coucou link relay"; then break; fi
  sleep 1
done
curl -fsS "http://127.0.0.1:${PORT}/" | grep -q "Coucou link relay" || { echo "the relay did not start"; cat "$LOG/relay.log"; exit 1; }

# Build the Rust test binary first: with a cold cache it takes minutes, longer than the phone side waits for the welcome.
echo "building the computer side (Rust)"
(cd "$ROOT/windows" && cargo test -p coucou --lib --no-run)

echo "starting the computer side (Rust)"
(cd "$ROOT/windows" && cargo test -p coucou --lib relay_client::tests::e2e -- --ignored --nocapture >"$LOG/pc.log" 2>&1) &
PC_PID=$!

echo "running the phone side (Kotlin)"
PHONE_CMD="${PHONE_CMD:-cd $ROOT/android && ./gradlew cleanTestDebugUnitTest testDebugUnitTest --tests '*RelayE2ETest' --console=plain}"
if ! bash -c "$PHONE_CMD"; then
  echo "the phone side failed"; tail -30 "$LOG/pc.log" || true; exit 1
fi

if wait "$PC_PID"; then
  echo "END TO END OK ($MODE): the Rust computer and the Kotlin phone talked through the relay and the approval was decided"
else
  echo "the computer side failed"; tail -40 "$LOG/pc.log"; exit 1
fi
