# Windows Coucou: selectable chat providers

## Outcome and scope

Coucou's own Windows chat can use Anthropic, OpenAI, or Moonshot/Kimi with separately stored API keys and a model selection for each. This chat is independent of the tracked CLI agents. Switching provider or model starts a fresh Coucou conversation. The first release supports text chat and bounded inline text-file context; Anthropic's existing image, PDF and web-search behavior remains available when Anthropic is selected. No desktop-app login or subscription is reused.

## Provider boundary and settings

Extend `windows/src-tauri/src/settings.rs` and its TypeScript mirror in `windows/src/core/state.ts` with a typed provider identifier and saved model choice per provider. Older `settings.json` loads as Anthropic with the user's previous Claude model retained. Validate provider and model server-side so UI values cannot select arbitrary request URLs or invalid configuration. Saving a new provider or changing its model must reset the Rust conversation in `windows/src-tauri/src/lib.rs` and clear the island history in the same user action. Prevent a send from racing a switch: serialize changes against chat turns or tag sends with a conversation generation and discard a late response. Settings-window changes propagate through the existing `settings-changed` event, including the reset in other windows. A model-change failure must leave the previous selection usable, not silently desynchronize UI and Rust.

Keep Anthropic's Messages request and history in `windows/src-tauri/src/claude.rs`. Add provider-specific request builders/parsers under `windows/src-tauri/src/` for OpenAI and Moonshot using existing `reqwest`, and a narrow dispatcher that owns one active conversation. Do not reuse Anthropic content/tool blocks as OpenAI history. For the first release, OpenAI and Moonshot may use their documented Chat Completions text shape if supported by the selected model; do not assume every model supports every optional parameter. Moonshot's documented OpenAI-compatible endpoint is `https://api.moonshot.ai/v1/chat/completions`; use a fixed endpoint for each provider. Provide curated, documented model choices and a validated manual model ID fallback instead of pretending all provider models have identical capabilities. Before implementation, check the then-current OpenAI API contract for the chosen models and test with real keys.

Extend `windows/src-tauri/src/secrets.rs` with separate `openai-api-key` and `moonshot-api-key` entries. Store them only in Windows Credential Manager; the frontend may check presence and set/clear them but cannot read their values. In `windows/src/settings/main.ts`, show provider, per-provider model choice, key presence and a clear description of what changes on switching. The chat UI in `windows/src/views/chat.ts` names the currently selected provider/model and reflects a reset immediately.

## Context and failure behavior

On the first turn, a text attachment is read on the Rust side within the existing 200 KB limit and sent as ordinary text to OpenAI or Moonshot; unreadable, oversized, PDF and image attachments receive an explicit unsupported-file error rather than silently dropping context. Keep Anthropic's current file behavior unless a regression test reveals an existing defect. Do not send window context or file bytes to a provider without the user's chat action. Never log API keys, prompts, attachment contents or complete error bodies. Return a short actionable error for missing/invalid key, HTTP failure, malformed response and timeout; failed sends do not corrupt the history or create a phantom assistant reply.

## Verification

Use existing Rust tests to cover legacy-settings migration, provider/model validation, request/response parsing, context limits, reset and late-reply race handling. Add frontend tests only if this repository already has a test runner. Run the standard Windows Rust and frontend build/test commands and exercise two-turn conversations with each of three real provider keys; switch providers and models mid-session, confirm fresh history in both windows, and test missing/invalid keys and unsupported attachments. Without keys, report live API behavior as unverified rather than claiming end-to-end completion.

## Out of scope

Provider-neutral web search, PDF/image parity, chat inside an active CLI session, arbitrary user-supplied API base URLs, account/subscription login, and remote synchronization of histories are not part of this milestone.
