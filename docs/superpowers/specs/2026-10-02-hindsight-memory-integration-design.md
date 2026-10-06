# Hindsight Memory Integration Design

## Purpose

Add durable Hindsight memory to Coucou chat on Windows and macOS. Coucou should recall relevant information before a model call, retain durable information after a successful turn, and provide a full interface for reviewing and managing memories.

The integration must not make chat availability depend on Hindsight. It must keep credentials in platform credential stores and exclude sensitive or transient chat data from automatic retention.

## Scope

This release includes:

- Native Hindsight REST clients for Windows and macOS.
- Automatic recall for ordinary chat.
- Explicit and inferred retention.
- A private-chat mode that bypasses recall and retention.
- A full memory manager on both platforms.
- Secure bearer-token storage.
- Connection settings and diagnostics.
- Consistent behavior, data types, and errors across platforms.

This release does not add durable transcript storage. Hindsight stores durable knowledge, while current chat history remains a separate concern. It also does not add a shared bridge daemon or expose memory operations as model-controlled MCP tools.

## Deployment Configuration

The initial configuration is:

- Base URL: `https://hindsight.example.com/hindsight`
- Tenant: `default`
- Bank: `hieu`
- Authentication: bearer token

The bearer token is entered through Coucou settings. It must never be committed, embedded in defaults, copied into JSON settings or `UserDefaults`, exposed to frontend state, logged, or included in exports.

The base URL is user-configurable. URL construction must preserve reverse-proxy prefixes such as `/hindsight`. HTTPS is required by default. An explicit development-only override may permit HTTP; Coucou must never silently downgrade from HTTPS to HTTP.

## Architecture

Each platform implements a native client behind the same conceptual contract:

```text
testConnection
recall
retain
listMemories
searchMemories
getMemory
updateMemory
deleteMemory
bulkDeleteMemories
exportMemories
```

The Windows implementation uses Rust, `reqwest`, and narrow Tauri commands. The macOS implementation uses Swift and `URLSession`. Provider-specific model clients do not own memory behavior. A chat coordinator invokes Hindsight before and after the provider call.

The adapter owns API paths, authentication, request and response mapping, pagination, timeouts, cancellation, and response-size limits. This keeps Hindsight API details out of chat views and the memory manager.

### Windows components

- `windows/src-tauri/src/hindsight.rs`: typed REST client and error mapping.
- `windows/src-tauri/src/settings.rs`: non-secret Hindsight settings and migration-safe defaults.
- `windows/src-tauri/src/secrets.rs`: allowlisted Hindsight credential account.
- `windows/src-tauri/src/lib.rs`: chat coordination and narrow memory commands.
- `windows/src/core/bridge.ts`: typed frontend command wrappers that never read the token.
- `windows/src/settings/main.ts`: connection and retention settings.
- A dedicated full-size Memory Manager WebView registered with Vite and created at startup.

### macOS components

- A dedicated `HindsightService.swift`: typed REST client and error mapping.
- A chat-memory coordinator separate from `ClaudeService` and SwiftUI views.
- Matching non-secret preferences in `AppState`/`UserDefaults`.
- An allowlisted Keychain account for the Hindsight token.
- A resizable `MemoryManagerView` opened from Settings and the menu bar.

## Security and Privacy

Windows stores the token in Windows Credential Manager. macOS stores it in Keychain using `WhenUnlockedThisDeviceOnly` and no synchronization. Frontends may only query whether the credential exists, replace it, or delete it.

All memory operations are scoped to the configured tenant and bank. Empty values are normalized to safe defaults or rejected; they never mean “all tenants” or “all banks.” Destructive confirmations display the tenant and bank.

Automatic retention excludes:

- Bearer tokens, credentials, and authentication headers.
- Hidden system prompts.
- Raw tool calls and tool results.
- File contents, attachments, and dropped-file bytes.
- Failed, cancelled, or incomplete turns.
- Temporary presentation requests that are not durable preferences.

File or window context may contribute a user-visible label, but not its contents, unless the user explicitly selects and retains that content.

Retrieved memories are untrusted data. Coucou places them in a bounded context section that identifies them as memory, not instructions. Retrieved text cannot override system or developer instructions or grant tool permissions.

Hindsight memory-protection features remain defense in depth. Coucou enforces its own retention filters before submitting content.

## Chat Data Flow

For an ordinary enabled chat turn:

1. Coucou assigns an immutable local turn ID and timestamp.
2. Coucou sends the user query to `recall` with a strict context budget.
3. It formats returned results as untrusted memory context.
4. It invokes the selected chat provider with the current conversation and bounded memory context.
5. It displays a successful model response immediately.
6. It asynchronously submits the completed exchange for inferred retention.
7. It associates returned remote memory IDs with local provenance where the Hindsight API provides them.

Recall and retention are bypassed when memory is disabled or private-chat mode is active.

### Recall

Recall runs before Anthropic or 9router on Windows and before Claude on macOS. It has bounded connection and request timeouts. Failure produces no memory context and does not prevent the provider call.

The memory-context formatter has a strict token or character budget and deterministic separators. It includes only fields needed to help the model answer and excludes internal Hindsight metadata unless it contributes safe provenance.

### Explicit retention

A user can invoke “Remember this” on selected text or a completed turn. Explicit retention records `retentionKind = explicit` and the relevant source span. It is independent of inferred retention settings but unavailable in private-chat mode unless the user first exits private mode.

### Inferred retention

After a successful turn, Coucou submits the user and assistant exchange with a restrictive retain mission. Eligible information includes:

- Durable user preferences.
- Project facts and stable terminology.
- Decisions and their stated rationale.
- Corrections to earlier information.
- Durable workflow conventions.

The response remains available if inferred retention fails. Coucou displays a non-blocking “Memory not saved” status. It does not create a plaintext retry queue.

### Reset and forget semantics

Resetting chat clears only the active conversation. It does not change Hindsight memories.

“Forget this” resolves the remote memory or memories associated with the selected turn and retires them with Hindsight’s supported invalidation state after confirmation. Retired memories are excluded from ordinary recall and browsing, remain visible in a retired-memory view, and can be restored. If no remote association is available, Coucou opens a scoped search rather than claiming retirement succeeded. Permanent source-document deletion is outside the first-release scope because it can remove multiple extracted memories.

## Provenance

Coucou uses a matching cross-platform provenance model containing:

- Local turn ID.
- Source role and selected span, when applicable.
- Turn timestamp.
- Platform.
- Provider and model.
- Safe context kind and display label.
- Retention kind: explicit or inferred.
- Tenant and bank.
- Remote memory IDs when returned.
- Remote creation and update timestamps when returned.

Only the minimum local mapping needed for turn-to-memory actions is retained. It contains no bearer token, raw tool payload, hidden prompt, or file content.

## Memory Manager

The Memory Manager is a full-size, resizable window rather than part of the compact island chat.

### Browse and search

- Native limit/offset pagination matching Hindsight’s API.
- Text search through Hindsight.
- Date, source, and explicit/inferred filters.
- Newest-first ordering. Oldest-first ordering is deferred until Hindsight supports it without requiring Coucou to load an unbounded bank.
- Cancellation of obsolete requests when search criteria change.
- Valid memories by default, with a separate retired-memory view.

### Inspect and correct

The detail view shows memory content, metadata, source turn, timestamps, platform, provider/model, retention type, and Hindsight evidence where available.

Users can edit or replace incorrect memory. Hindsight does not expose an atomic concurrency token, so Coucou reloads the remote memory before updating it. If the current value differs from the value the user opened, Coucou warns and requires confirmation before sending the update.

### Export

Users can export selected memories or the current filtered result set through a native save dialog:

- JSON preserves structured content and provenance.
- Markdown produces a readable archive.

The token and authentication metadata are never exported.

### Retire and restore

Users can retire one memory, selected memories, or every memory matching the active filter. Before requests, Coucou shows the count, filter scope, tenant `default`, and bank `hieu`. Retirement uses Hindsight’s supported invalidation state and is reversible from the retired-memory view.

A partial bulk retirement refreshes the list and reports outcomes per memory. The UI never reports complete success if any requested retirement failed. Permanent source-document deletion is not exposed in the first release.

### Settings and status

The settings surface includes:

- Memory enabled/disabled.
- Base URL, tenant, and bank.
- Credential present/not present, replace, and remove actions.
- Test connection.
- Automatic recall toggle.
- Inferred retention toggle.
- Private-chat control in the chat interface.

The token field clears after saving and never initializes from stored credential text.

## Error Model

Both platforms map failures to the same user-facing categories:

- Disabled.
- Authentication required.
- Forbidden.
- Invalid configuration.
- TLS or connection failure.
- Timeout.
- Server failure.
- Invalid or oversized response.
- Conflict/stale edit.
- Partial bulk failure.
- Cancelled.

An authentication failure suppresses further automatic requests for the current app session and shows an action to update credentials. A manual connection test or credential replacement clears this suppression.

Coucou displays exact actionable connection details without logging secrets or full authorization headers. It never falls back to an alternate endpoint automatically.

## Cross-Platform Consistency

Windows and macOS use matching defaults, retention categories, provenance fields, settings meanings, error categories, and confirmation language. They use platform-native networking, credential storage, windows, and save dialogs.

Credential storage identities may differ by application service name, but the credential account name is consistent. No automatic credential migration occurs between platforms.

The memory contract is documented and tested independently of each UI so that platform implementations can evolve without changing user-visible semantics.

## Testing

### Unit and contract tests

- Base URL validation and reverse-proxy-prefix preservation.
- Rejection of embedded credentials, query strings, and fragments.
- HTTPS requirement and explicit development HTTP override.
- Authorization-header construction without exposing the token in errors or logs.
- Tenant and bank scoping.
- Request/response decoding, pagination, cancellation, and response-size limits.
- Recall context truncation and untrusted-context delimiters.
- Automatic-retention eligibility and exclusions.
- Successful-turn-only retention.
- Private-chat bypass.
- Reload-before-edit conflict warnings.
- JSON and Markdown export redaction.
- Individual and partial bulk retirement and restore behavior.
- Legacy settings migration and safe defaults.

### Integration tests

A configurable disposable test bank is used for create, update, export, retirement, and restore scenarios. Tests do not mutate bank `hieu`.

### Final validation

Against the configured `hieu` bank, validation is limited to:

1. Authenticated connection test.
2. Non-destructive recall.
3. One explicitly approved disposable memory if end-to-end retain/retire/restore validation is required.

The app must also be tested with Hindsight unavailable to verify that chat remains functional and that status reporting is non-blocking.

## Acceptance Criteria

The integration is complete when:

- Windows and macOS can securely configure and test the same Hindsight deployment.
- Ordinary chat recalls bounded relevant memory without treating it as instructions.
- Explicit and inferred retention follow the approved exclusions.
- Private chat performs no Hindsight requests.
- Hindsight outages do not prevent chat responses.
- Users can browse, search, inspect, correct, export, retire, and restore memories on both platforms.
- Credentials are absent from settings, frontend state, logs, source, and exports.
- Tests do not mutate bank `hieu` without explicit approval.
- Platform test suites and end-to-end chat checks pass.
