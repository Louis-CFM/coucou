# Windows Chat Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not commit unless the user explicitly requests a commit.

**Goal:** Offer Anthropic, OpenAI and Moonshot/Kimi API-key-backed chat in Coucou for Windows, with an independent model selection for each provider.

**Architecture:** Keep Anthropic's existing Messages API behavior and add fixed-endpoint Rust text clients for OpenAI and Moonshot. A single conversation coordinator commits successful turns and invalidates old replies when provider/model or context changes. Keys stay in Windows Credential Manager; Settings edits are validated and synchronized across both windows.

**Tech Stack:** Rust/Tauri 2, serde, reqwest, keyring, TypeScript/Vite, existing Rust test suites.

**Spec:** `docs/superpowers/specs/2026-10-01-windows-chat-providers-design.md`

## Global Constraints

- Three independent API keys, stored only in Windows Credential Manager; no frontend key-reading command.
- Provider/model switching starts a fresh conversation and must not accept a late reply from the old conversation.
- Anthropic retains existing web-search, PDF and image behavior; OpenAI and Moonshot v1 support text chat and <=200,000-byte UTF-8 text-file context only.
- API endpoints are fixed per provider; manual model IDs are bounded identifiers, never URLs.
- An unreadable/oversized/unsupported attachment is an explicit error, not a silent omitted context.
- Do not add a TypeScript test runner to a repository that has none; use existing Rust tests plus builds and real app checks.
- Do not log or echo raw keys, prompts, file contents or full provider response bodies.

## Review Focus

- Legacy `settings.json` with a non-default Claude model retains that model on upgrade; pin in Task 1 migration test.
- Switch during an in-flight send discards the late response and leaves both windows reset; pin in Task 4 coordinator tests and Task 5 manual two-window check.
- Failed/malformed/empty API response never commits a phantom user or assistant turn; pin in Task 3 and Task 4 tests.
- File exactly 200,000 bytes is accepted; 200,001 bytes, invalid UTF-8, PDF/image and missing file explicitly fail before API call; pin in Task 3.
- A stale whole-settings save from the other window cannot restore an older provider/model; pin in Task 5 tests and manual check.

---

## File ownership map

- `windows/src-tauri/src/settings.rs`: persisted provider and per-provider models, migration and validation.
- `windows/src-tauri/src/secrets.rs`: fixed credential-key allowlist.
- `windows/src-tauri/src/openai.rs`, `windows/src-tauri/src/moonshot.rs` (new): fixed-endpoint text request/response adapters.
- `windows/src-tauri/src/chat.rs` (new): conversation history, generation, turn serialization and context validation.
- `windows/src-tauri/src/claude.rs`: existing Anthropic request and history, adapted to transactional commit.
- `windows/src-tauri/src/lib.rs`: chat dispatch, atomic selection/reset and authoritative settings events.
- `windows/src/core/state.ts`, `windows/src/core/bridge.ts`: frontend state, typed bridge, chat generation tracking.
- `windows/src/settings/main.ts`, `windows/src/views/chat.ts`, `windows/src/main.ts`, `windows/src/island/island.ts`: settings and island sync, context chips and visible provider.
- `windows/README.md`: setup, feature parity and limits.

### Task 1: Migrate Settings to Per-Provider Models

**Files:** Modify `windows/src-tauri/src/settings.rs:7-47`; mirror in `windows/src/core/state.ts:84-109`.

**Interfaces:** Produces serde `ChatProvider { Anthropic, OpenAi, Moonshot }` and `ChatSelection { provider: ChatProvider, model: String }`; `Settings::selection() -> ChatSelection` and `Settings::select(&mut self, selection: ChatSelection) -> Result<(), String>`. Preserve old `model` only as deserialize migration input, not a second writable setting.

- [ ] **Step 1: Write failing Rust tests** that deserialize a legacy settings fixture containing `"model":"claude-sonnet-5"` and assert Anthropic selection retains that value, absent new fields default correctly, unknown provider is rejected, and model IDs with blank/control/URL/path/overlong input are rejected.
- [ ] **Step 2: Run `cargo test --workspace` from `windows/`; observe migration/validation tests fail.**
- [ ] **Step 3: Add provider enum and per-provider model defaults, explicit backward-compatible deserialization, and `Settings::select` server validation.** Mirror exactly in `windows/src/core/state.ts`; use curated choices only after checking current API/model documentation. For manual IDs, accept a conservative bounded identifier and never arbitrary URL or request options.
- [ ] **Step 4: Run `cargo test --workspace` and `npm run build` until migration and type checking pass.**

### Task 2: Add Separate Key Storage

**Files:** Modify `windows/src-tauri/src/secrets.rs:8-19`.

**Interfaces:** `secrets::get/set/clear/present` accept `openai-api-key` and `moonshot-api-key` along with existing `anthropic-api-key`; reject unrecognized keys.

- [ ] **Step 1: Add a Rust test asserting the three provider keys are in `KNOWN_KEYS` and `"arbitrary-secret"` is rejected.**
- [ ] **Step 2: Run `cargo test --workspace` and confirm the new assertion fails.**
- [ ] **Step 3: Extend only `KNOWN_KEYS`; leave existing Credential Manager service and no-read frontend boundary intact.**
- [ ] **Step 4: Run `cargo test --workspace`; verify key tests pass.**

### Task 3: Implement and Test Text Provider Contracts

**Files:** Create `windows/src-tauri/src/openai.rs`, `windows/src-tauri/src/moonshot.rs`, and a text-file context helper in `windows/src-tauri/src/chat.rs`; register modules in `windows/src-tauri/src/lib.rs:3-13`.

**Interfaces:** Each adapter consumes `{key, model, messages: &[TextMessage]}` and produces `Result<String, ChatError>` without mutating shared history. `TextMessage { role: TextRole, content: String }`. Context helper `first_turn_text_context(&ChatContext) -> Result<String, ChatError>` only accepts UTF-8 text files <=200,000 bytes, or a safely formatted window context; reject unsupported file formats. Rust side reads bytes, not browser JS.

- [ ] **Step 1: Check current OpenAI and Moonshot docs for fixed endpoint, selected models and minimal text request parameters.** OpenAI: `https://api.openai.com/v1/chat/completions` only for confirmed Chat Completions-capable models. Moonshot: `https://api.moonshot.ai/v1/chat/completions`. Do not assume model-specific optional settings transfer between providers.
- [ ] **Step 2: Write failing Rust request/parse tests.** First request includes system and user text, second includes prior user/assistant pair plus new user; neither contains Anthropic content/tool blocks or an arbitrary caller URL. Empty/missing `choices[0].message.content`, tool-only/refusal, malformed JSON, 401 and timeout produce short errors without body disclosure.
- [ ] **Step 3: Write failing file-context tests.** UTF-8 file at exactly 200,000 bytes passes; 200,001 bytes, invalid UTF-8, unreadable/missing, PDF and image fail before request construction. Validate window context separately if enabled in the source UI.
- [ ] **Step 4: Implement provider-specific body builders/parsers, bearer auth and explicit network timeout using existing `reqwest`.** Keep endpoints compile-time constants; return redacted, actionable errors.
- [ ] **Step 5: Run `cargo test --workspace`; adjust until all contract and boundary tests pass.**

### Task 4: Transactional, Race-Safe Conversation

**Files:** Create/extend `windows/src-tauri/src/chat.rs`; modify `windows/src-tauri/src/claude.rs:30-158` and `windows/src-tauri/src/lib.rs:241-258`.

**Interfaces:** `Conversation::send(selection: ChatSelection, query: String, context: Option<ChatContext>) -> Result<ChatReply, String>`; `Conversation::reset() -> u64` invalidates any older generation; `Conversation::generation() -> u64`. Provider adapters receive snapshots and only successful nonempty user+assistant turns are committed atomically. Preserve Anthropic's tool block history with its own format.

- [ ] **Step 1: Write failing Rust tests for a two-turn history, a failed call, an Anthropic malformed/empty reply, and a reset during a pending mocked response.** The pending result must be discarded, and a new provider request must see empty history. Test concurrent sends preserve order rather than interleave assistant replies.
- [ ] **Step 2: Run `cargo test --workspace`; confirm relevant tests fail.**
- [ ] **Step 3: Introduce a per-conversation async turn gate and monotonic generation.** Capture provider/model and generation consistently with settings; increment generation on reset or selection change, clear history immediately, and check generation before committing/returning a late reply. Never hold a synchronous lock across a network `.await`.
- [ ] **Step 4: Refactor Anthropic send to build from a snapshot and commit user and assistant only after valid, nonempty text.** Preserve its web-search, PDF and image request shape; avoid historical mutation on errors. Wire dispatcher into Tauri `chat_send` and `chat_reset`.
- [ ] **Step 5: Run `cargo test --workspace`; confirm all history and race tests pass.**

### Task 5: Atomic Chat Selection and Two-Window UI

**Files:** Modify `windows/src-tauri/src/lib.rs:62-87,241-258`, `windows/src/core/bridge.ts:13-20,31-91`, `windows/src/core/state.ts:84-109,134-145`, `windows/src/settings/main.ts:174-255,454-456`, `windows/src/main.ts:55-61`, `windows/src/views/chat.ts:39-133`, `windows/src/island/island.ts:387-412`, `windows/src/views/views.ts:273-285`, and `windows/src/views/upload.ts` if it advertises unsupported file types.

**Interfaces:** Tauri `chat_select(selection: ChatSelection) -> Result<Settings, String>` persists before in-memory mutation, resets conversation, emits authoritative selection/settings generation; frontend `Bridge.chatSelect(selection)` throws on error and updates only on success. Ordinary whole-settings saves must retain the latest provider selection rather than overwrite it with a stale window copy.

- [ ] **Step 1: Add failing Rust tests for invalid selection and simulated persistence failure.** Neither can alter the active model, reset history, or emit success. Test a stale general-settings payload cannot revert a newer selection.
- [ ] **Step 2: Run `cargo test --workspace`; confirm tests fail.**
- [ ] **Step 3: Implement dedicated, validating `chat_select` plus an authoritative settings event.** Keep selection and generation consistent with Task 4, merge unrelated settings updates so a stale object cannot revert selection; propagate save errors instead of `save_settings`'s current silent failure.
- [ ] **Step 4: Replace Claude-only settings controls with provider/model selector and a key control per provider.** Show Credential Manager presence, curated choices plus validated manual ID, and the explicit fresh-chat-on-switch rule. Re-render on `settings-changed` from the other window; disable controls while a switch is pending and restore old value on failure.
- [ ] **Step 5: In the island, clear visible history/context and invalidate pending UI sends on a selection/reset event.** In `submit()`, capture a UI generation and ignore both success and error from an obsolete request. Coordinate file-drop reset before a new send; show provider/model near chat. Preserve dropped-file visibility but explicitly reject unsupported file types for text providers.
- [ ] **Step 6: Run `cargo test --workspace` and `npm run build`.** Manually test two Tauri windows, switching during an in-flight call, invalid key, failed selection persistence, and stale general-preference saves. No old reply should reappear.

### Task 6: Documentation and Real-API Verification

**Files:** Modify `windows/README.md` and comments affected by Tasks 1-5.

**Interfaces:** Setup guidance for provider keys/models and clearly stated differences between tracked CLIs and Coucou's own chat.

- [ ] **Step 1: Explain independent keys and API billing, fresh history on provider/model switches, fixed endpoints, text-only OpenAI/Moonshot v1 attachments, and Anthropic's existing search/image/PDF behavior.**
- [ ] **Step 2: Run `cargo test --workspace`, `npm run build`, and the project's `npm run tauri dev` smoke test; `npm run pack` only if an installer is requested.** Confirm the Windows app renders both windows and no logs contain secrets or full prompts.
- [ ] **Step 3: With user-provided keys installed via the app UI (not pasted into chat), run two real turns for each provider, switch model and provider, and try missing/bad keys, timeout, supported text attachment and unsupported PDF/image.** If keys or network are unavailable, mark the real API paths unverified and do not call the fork complete.
