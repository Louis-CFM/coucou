#!/usr/bin/env bash
# Runs the Swift unit tests (macOS only: they compile with swiftc).
#
#   scripts/test.sh              every scripts/test-*.sh, 4 at a time
#   scripts/test.sh voice        only the ones whose name contains "voice"
#   scripts/test.sh -l           list them
#   JOBS=8 scripts/test.sh       change the parallelism
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "-l" ]]; then
    for f in test-*.sh; do f="${f#test-}"; echo "${f%.sh}"; done
    exit 0
fi

filter="${1:-}"
tests=()
for f in test-*.sh; do
    [[ "$f" == *"$filter"* ]] && tests+=("$f")
done
if [[ ${#tests[@]} -eq 0 ]]; then
    echo "No test matches '$filter' (scripts/test.sh -l lists them)." >&2
    exit 2
fi

out="$(mktemp -d "${TMPDIR:-/tmp}/coucou-tests.XXXXXX")"
trap 'rm -rf "$out"' EXIT

# Each script compiles with swiftc and runs on its own: they share nothing, so they go in parallel.
printf '%s\n' "${tests[@]}" | xargs -P "${JOBS:-4}" -I{} bash -c \
    'if bash "$1" >"$2/$1.log" 2>&1; then echo "ok   $1"; else echo "FAIL $1"; touch "$2/$1.failed"; fi' _ {} "$out" | sort

failed=("$out"/*.failed)
if [[ -e "${failed[0]}" ]]; then
    for f in "${failed[@]}"; do
        name="$(basename "$f" .failed)"
        echo; echo "── $name ──"; cat "$out/$name.log"
    done
    exit 1
fi
echo "${#tests[@]} test scripts passed."
