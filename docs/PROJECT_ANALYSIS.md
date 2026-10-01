# Project analysis: optional Codex coding-agent provider

Analysis date: 2026-10-01. Baseline: `3cc3333203f60f63326ee949b7b86c7549992a1f`.
Contribution branch: `codex/codex-agent-provider`.

## Objective

Extend **upstream Coucou**, not create a separate product. Codex is a
coding-agent provider beside Claude Code, not a chat-model switch or an
autonomous cloud agent. Keep Coucou, Mochi, media, identifiers and release
destinations. Tests neither install hooks nor touch production credentials.

## Repository-wide architecture

| Area | macOS | Windows | Contribution impact |
|---|---|---|---|
| App lifecycle/windows/preferences | `AppDelegate.swift`, `IslandWindowController.swift`, `AppState.swift` | `lib.rs`, `tray.rs`, `island.rs`, `settings.rs`, `main.ts` | Optional provider flag; old preference defaults retained |
| State/views | `IslandTypes.swift`, `IslandViewContent.swift`, `IslandStateMachine.swift` | `core/state.ts`, `island/*`, `views/*` | Provider identity, independent status and approval ownership |
| Agent transport | `HookServer.swift`, embedded Python, Unix socket | `hook/src/main.rs`, `pipe.rs`, per-user named pipe | Explicit provider tag; existing transport reused |
| Hook setup | Existing Claude setup in `HookServer.swift` / `SettingsView.swift` | `hooks.rs`, `settings/main.ts` | Separate Codex config, preview, confirmation, dated byte backup, stale detection |
| API chat/file context | `ClaudeService.swift`, `FileDropView.swift`, `WindowContextCapture.swift` | `claude.rs`, `files.rs`, chat/upload views | Anthropic chat and drop choreography unchanged |
| Credentials | Keychain | `secrets.rs`, Credential Manager | No new adapter key |
| Service integrations | Individual `*Poller.swift` files | `integrations.rs`, `island/integrations.ts` | Polling gates, settings and four-service limit retained |
| Mascot/audio | Canvas, `BotEngine.swift`, `SoundEngine.swift` | Canvas `bot/*`, `core/sound.ts` | No asset/character/sound change |
| Build/release | XcodeGen `project.yml`, two app schemes | npm/Vite, Cargo workspace, Tauri bundler | Add PR regression CI; no release destination/Xcode project edit |
| Documentation/design | Legacy French specs, Pages site, `design/` | Windows guide/screenshots | Add current integration docs; retain presentation |

Both implementations already separate session UI from API chat. The right seam
is **hook provider -> normalized local event -> provider task**, not a second
chat SDK. A generic plugin runtime would add unnecessary complexity here.

## Findings and decisions

| Baseline finding | Code evidence | Decision / implementation |
|---|---|---|
| All coding events target Claude | Hard-coded `integration_claude` in handlers/approval cleanup | Dispatch explicit Claude/Codex identity; untagged events remain Claude |
| Provider protocols differ | Claude-only event list and Always suggestions | Separate Codex registrations and Allow/Deny; no persisted Claude suggestions |
| Old finish resets can overwrite new work | Delayed idle reset after Stop | Per-provider timer cancellation / generation guard |
| Approvals conflict across sessions | Single card/FD and fixed cleanup task | Bind task/session/request; release competitors to terminal; guard FD reuse |
| Existing model has one current coding task | Persistent integration task, not session collection | One latest-session pill per provider; ignore stale non-start events |
| Codex need not use VS Code | Mac Claude terminal-context filter | Preserve Claude filter; accept Codex from other terminals |
| Group-level removal can erase foreign hooks | Windows original ownership filter | Remove individual Coucou handlers only, preserving matcher/siblings |
| Preview and write need one byte snapshot | Original reparsing/backup naming | Single snapshot per phase, existence-aware fingerprint, exclusive backup, atomic write |
| Preferences must remain compatible | Rust JSON Settings structure | Default the new flag to false |
| Coding provider is not a service slot | Default Claude + four services | Separate coding identity and protect service-toggle path |
| Old specs are not current implementation | Legacy spec describes a different relay | Document observed implementation separately |
| Regression coverage was incomplete | Mac build job; Windows release-only pipeline | Add state, relay, installer and native CI checks |
| Legacy file-ingestion test uses the production inbox | `files.rs` test calls the production entry point | Inject a disposable inbox into the internal helper; keep runtime behavior unchanged |

The installed `codex-cli 0.153.3` reports hooks stable/enabled. The adapter was
checked against the [official hook contract](https://learn.chatgpt.com/docs/hooks).
That identifies the inspected version, not an oldest supported release or proof
of identical behavior in every Codex client. Hook monitoring is not a universal
view of hosted tools or cloud tasks.

## Comprehensive implementation plan / status

1. **Analyze/preserve baseline — done.** Inspect both app boundaries, transport,
   setup, UI, chat, credentials, pollers, build/release, guides and visual assets.
   Save tracked-file hashes and byte copies before modifying source.
2. **Provider boundary — implemented.** Keep Claude defaults and task IDs,
   reuse IPC, add Codex identity. Unknown providers are not silently Claude.
3. **Codex adapter — implemented.** Register its own lifecycle events in its own
   config; do not edit `config.toml` or Claude config. Reuse native/Python relays
   and discard unused transcript/response fields.
4. **State and approval — implemented.** Independent task, stable pill label,
   activity, cancellation, finish and explicit approval. Guard old timers and
   session events; do not replace an already reviewed approval with a competitor.
5. **Reviewed setup/removal — implemented.** Provider-specific Windows section;
   separate Mac group and App Store security-scoped folder selection. Preview
   stays read-only; apply confirms/backups and rejects stale bytes.
6. **Regression evidence — implemented, native gates tracked below.** Exercise
   actual state/handler and embedded relay code, disposable config, native
   installer/normalization, and isolated named-pipe I/O.
7. **Upstream review — prepared.** Keep the complete candidate on a contribution
   branch; propose review stages and acceptance gates, without implying that a
   PR or release has already been submitted.

## Verification and acceptance gates

See [setup/protocol](CODEX.md) and [upstream proposal](CODEX_CONTRIBUTION.md).
Exact local commands, output and rollback evidence live in ignored
`_prive/codex-support/`, not in the public PR.

Locally executed: frontend typecheck/build, 13 Windows state tests and 6 tests
of both embedded Mac relay scripts. Native Rust results are recorded in the
verification artifact. A portable GNU toolchain is isolated under `_prive/`;
it is not the supported MSVC release-packaging environment.

The Swift installer test and both native Xcode app builds must run on a Mac or
in the new Mac CI job. Windows MSVC packaging and interactive lifecycle/approval
dogfood remain release gates. Adding a workflow does not establish its success.

## Retained behavior and follow-on work

- Anthropic chat remains unchanged. No OpenAI credential or runtime SDK is added.
- Open-project uses the existing VS Code action, not guaranteed Codex terminal/
  thread routing. No Dots/cloud event integration is assumed.
- The UI is not a concurrent-session dashboard. A later design can key cards by
  `(provider, session_id)`. Start/tool activity from a displaced session can
  become the latest again; its non-start events are ignored while displaced.
- Mac Claude's legacy setup flow deserves a separate hardening review, rather
  than a silent unrelated rewrite in the Codex contribution.
- Service/API boundaries were inspected, not live-tested against accounts.
  Provider tests do not establish service health or an all-site security audit.
- No transcript tailer, new timer loop, background daemon or telemetry is added.
  Native idle CPU, pill overflow and visuals still need dogfood captures.

## Reusable review prompt

```text
Review Coucou's optional Codex provider using AGENTS.md and docs/CODEX.md.
Trace installer -> relay -> IPC -> provider task -> explicit approval. Preserve
Claude defaults, foreign hooks, preferences, assets and release targets. Use
disposable config/isolated IPC. Check cancellation, competing approvals, stale
sessions/finish timers, silence on timeout, and uninstall. Run both native CI
jobs; report executed results separately from pending interactive dogfood.
```
