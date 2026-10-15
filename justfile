# One entry point for the whole repo. `just` lists the recipes. https://github.com/casey/just
# The Mac app is built with xcodegen/xcodebuild (see CLAUDE.md); these cover the rest.

default:
    @just --list

# Windows / Linux app, live reload
dev:
    cd windows && npm install && npm run tauri dev

# Front end only, in a browser (no Tauri)
dev-web:
    cd windows && npm run dev

# Windows / Linux checks, as the CI runs them: types, island tests, Rust tests
check: types test-web test-rust

types:
    cd windows && npx tsc --noEmit

# Island tests. `just test-web island/foo` for one file, `just watch` to re-run on save.
test-web *files:
    cd windows && if [ -n "{{files}}" ]; then npm run test:one -- {{files}}; else npm test; fi

watch:
    cd windows && npm run test:watch

test-rust:
    cd windows && node scripts/build-hook.mjs --fast && cargo test --workspace --locked

# Swift tests (macOS). `just test-swift voice` for the ones matching "voice".
test-swift filter="":
    scripts/test.sh {{filter}}

# Mac app
mac:
    cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build
