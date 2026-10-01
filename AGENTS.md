# Coucou — coding-agent guide

Coucou is a local desktop companion with two implementations: native Swift on
macOS and Tauri/Rust/TypeScript on Windows. Claude Code and Codex session hooks
are separate from the built-in Anthropic API chat.

## Map
- `NotchBuddy/Sources/App/`: SwiftUI/AppKit, state, hook socket, chat and pollers.
- `NotchBuddy/project.yml`: XcodeGen source; regenerate, do not hand-edit `.xcodeproj`.
- `windows/src/`: framework-free TypeScript, Canvas character, island and settings.
- `windows/src-tauri/`: native Rust commands, named pipe, credentials and pollers.
- `windows/hook/`: bounded, fail-open native hook relay.
- `docs/PROJECT_ANALYSIS.md`: architecture, findings and implementation plan.
- `docs/CODEX.md`: provider setup, protocol, compatibility and verification.
- `docs/SPEC.md`, `docs/INTEGRATIONS.md`: older French product specifications.
- `design/prototype/`, `design/captures/`: visual references.

## Checks
Windows, from `windows/`:
```powershell
npm ci
npm test
npm run typecheck
npm run build:frontend
cargo test --workspace --locked
npm run pack
```
The frontend checks do not require Rust. Packaging requires Rust, MSVC and WebView2.
macOS:
```sh
python3 -m unittest discover -s tests -p 'test_*.py'
swiftc NotchBuddy/Sources/App/CodexHooks.swift tests/codex-hooks/main.swift -o /tmp/coucou-codex-tests
/tmp/coucou-codex-tests
cd NotchBuddy && xcodegen
xcodebuild -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO
```
Use the native CI jobs for platforms absent from the current machine. Report
executed checks separately from unexecuted native builds.

## Invariants
- Preserve Claude support when changing Codex; default untagged legacy events to Claude.
- Follow each provider's documented protocol, not assumptions from the other provider.
- Hooks exit with no output when Coucou is unavailable or no explicit decision is made.
- Hook installation requires a reviewed preview, byte-preserving dated backup,
  stale-preview detection and an explicit confirmation. Preserve foreign handlers
  even when they share a matcher group with Coucou.
- Never modify the developer's real agent configuration as a side effect of tests.
  Local tests use disposable fixtures without production access.
- Permission decisions require an explicit user click; timeouts do not mean deny.
- Secrets stay in Keychain/Credential Manager. No telemetry; network only to
  configured services. Do not add credentials, transcripts or local backups to git.
- Keep existing bundle identifiers and stored preference compatibility.
- Swift 6 strict concurrency. No new runtime dependency for the native macOS app.
- Keep Canvas-based visuals and idle CPU behavior; compare UI changes to references.
- Do not rebrand upstream media or change release destinations as part of agent support.

## Reusable task prompt
```text
Implement the requested change in Coucou using AGENTS.md. Inspect the affected
provider and both platform boundaries. Preserve existing behavior, add regression
tests for the changed protocol/state transitions, run available checks, and report
the precise changes, check results and any native checks still unexecuted.
```
