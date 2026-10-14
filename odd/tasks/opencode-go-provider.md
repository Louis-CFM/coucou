# OpenCode Go chat provider

## Objective
Port the fork's OpenCode Go chat support (branch `performance`) into upstream's native
multi-provider chat as one more `ChatProvider` case (`.opencodeGo`), not a parallel provider layer.

## Problem / why
Upstream 0.3.0 ships native multi-provider chat (Anthropic, Google, OpenAI, Ollama, LM Studio).
The fork's earlier OpenCode Go support was built on its own ChatProvider/ChatService layer that
upstream superseded. Rebasing the feature onto upstream's enum keeps one provider system.

## Scope
- `ChatProvider.opencodeGo` (raw `opencode-go`, pill `ai_opencode-go`), display name, accent,
  default model `kimi-k3`, Keychain account `opencode-go-api-key`.
- Pure helpers in `NotchBuddy/Sources/App/OpenCodeGo.swift`: base URL, routing by model-ID prefix
  across Go's three API shapes (`/messages`, `/chat/completions`, `/responses`), text flattening,
  request bodies, response/error parsing.
- ClaudeService: `chatOpenCodeGo` with session-ID + user-agent headers (fork e9d66f0), Go system
  prompt (no web search promise), error handling; model list fetch from `/models`.
- AppState: `opencodeGoChatModel` persisted under the fork's key `opencodeGoModel`.
- Settings "Other providers" row + island pill/picker wiring, same as OpenAI.
- Out of scope: the fork's ChatProvider protocol/ChatService/ChatBackend layer, Codex placeholder
  UI, Swift warning fixes, Responses-API transport (still rejected with an explicit error, as in
  the fork).

## Constraints
Swift 6, no deps, secrets in Keychain only, never restyle shipped views, stable pill IDs.

## Tasks
- [x] OG-01 Provider case + routing helpers + chat transport + tests (route: inline) — `e2bfe40`
- [x] OG-02 Settings key row, island pill status/switch and model picker wiring (route: inline) — `09b7dd0`
- [x] OG-03 Island close-after-leave fix (fork 140f117): **not needed** — upstream already syncs
  `fsm.homeToPetitDelay` with `autoCloseInterval` and schedules collapse on `mouseLeft()`
  (plus opt-in open-on-hover with 0.6 s close). The fork's remaining deltas (1 s default,
  1/3/10 s presets, leave-based countdown bar, "s after leaving" label) change shipped defaults
  and visuals, which CLAUDE.md forbids without an explicit request.

## Acceptance criteria
- `bash scripts/test-opencode-go-routing.sh` passes.
- Debug build succeeds.
- OpenCode Go appears in the model-picker chips, AI pills and Settings; selecting it routes chat to Go.

## Checks / evidence
- OG-01: RED observed (`OpenCodeGo.swift` missing), then GREEN: `scripts/test-opencode-go-routing.sh`
  → 47 assertions passed. Debug build: BUILD SUCCEEDED. `test-chat-parsing`, `test-conversation-context`,
  `test-claude-response`, `test-pill-colors` pass. Regenerated `project.pbxproj` committed (adds
  OpenCodeGo.swift; xcodegen also reshuffles IDs of Voice files, no functional change).
- OG-02: Debug build: BUILD SUCCEEDED; routing and pill-colour tests pass.
- Pending: manual run with a real OpenCode Go key (no network call made in tests).
- Not ported: voice EntityResolver alias for "opencode go" (file outside scope); Windows/Tauri app.

## Next step
Manual smoke test in the app with a Go key: pick OpenCode Go in the model picker, send a message
to a chat-completions model (kimi-k3) and a messages model (minimax-*).
