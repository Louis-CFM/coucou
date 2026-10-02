# Repository Guidelines

Coucou puts a small animated character, **Mochi**, in your Mac's notch — or at the top of your
screen on Windows and Linux — and surfaces AI coding-agent sessions (Claude Code, Gemini CLI,
Antigravity) there. It shows what each agent reads, edits and runs, and can approve permission
requests, answer questions, chat, and take dropped files, all without leaving the current task.

**Mochi is drawn in code.** No images, no Rive, no Lottie: a superellipse body with eyes projected
onto a sphere, rendered at 60 fps in SwiftUI `Canvas` or Canvas 2D. The 28 sounds are the only
binary assets involved.

> `CLAUDE.md` already holds the short house rules (zero third-party deps, no telemetry, never block
> Claude Code, never restyle a shipping view). Read it first. This file covers the *map*: where
> things live, how they fit together, and the conventions each language actually follows.

---

## Architecture & Data Flow

Three implementations, **no shared runtime code**:

| | Path | Stack |
|---|---|---|
| macOS | `NotchBuddy/` | Swift 6, SwiftUI + AppKit, zero third-party dependencies |
| Windows + Linux | `windows/` | Tauri 2 — Rust backend + TypeScript front end, no front-end framework |

The Tauri app is an explicit **port**, not a rewrite. Every ported file names its Swift source in
its header (`hooks.ts:2` → `HookServer.swift`; `engine.ts:1` → `BotEngine.swift`). **When you change
behaviour, change both platforms** — or state plainly in your summary why not. `hooks.ts:3-4` is the
model: it names the divergence ("Difference from macOS: no terminal filter").

Dependency direction is strictly downward on both sides — *views → state → services*. Nothing below
the state layer imports a UI framework.

### Three orthogonal state axes (do not conflate them)

This is the single most common source of confusion in this codebase.

1. **FSM state** — `hidden | petit | home | coucou`. Pure, no UI, no I/O
   (`NotchBuddy/Sources/App/IslandStateMachine.swift`, `windows/src/island/fsm.ts`). Both platforms
   share the identical transition table and the three timer defaults
   (`homeToPetitDelay` 15 s, `petitToHiddenDelay` 60 s, `greetAutoCollapseDelay` 0.6 s).
2. **Mode** — `hidden | compact | expanded`. The visual size. Mutated *only* inside `onTransition`.
3. **View** — 17 values (`overview`, `approval`, `upload`, `choose`, …). Which card is showing.

`home` never reaches `hidden` directly; it always passes through `petit`.

### Data flows worth knowing before you touch anything

**Hook event (the core path).** Claude Code spawns a relay process per event. It writes
newline-terminated JSON to a local socket and exits.

```
Claude Code ─▶ relay ─▶ AF_UNIX / named pipe ─▶ Rust|Swift ─▶ island state + sound
   (macOS: nb-hook sh wrapper → nb-hook.py → nb.sock)
   (Windows: coucou-hook.exe → \\.\pipe\coucou-<user-SID>)
   (Linux:  coucou-hook    → $XDG_RUNTIME_DIR/coucou.sock)
```

Non-permission events are fire-and-forget: the app acks and closes. **Permission requests are not.**

**Permission decision (Windows/Linux)** — the load-bearing sequence:

1. `pipe.rs` sees `PermissionRequest`, mints `request_id = "<pid>-<counter>"`, registers an
   `mpsc::Sender<Reply>` in `Pending`, injects the id into the payload, emits `hook`.
2. `hooks.ts` renders the card and calls `Bridge.approvalAck(id)` **synchronously** — the relay's ack
   window is 800 ms, so anything after that line is already too late.
3. Relay gets the ack, enters a 108 s decision wait. User clicks → `approvalDecision`.
4. Relay writes the bare word `allow` / `deny` + `\n` on the same connection; the hook prints the
   documented `hookSpecificOutput` JSON.

**Silence at any step means Claude Code re-asks in its own terminal.** That is the designed failure
mode, not an error path. Timeouts are deliberately staggered so the app always answers first:
hook 110 s → relay 108 s → UI watchdog 110 s; Claude Code's own hook budget is 120 s.

The macOS wire format differs (the app holds the socket fd in `pendingApprovalFD` and writes
`{"permissionDecision": …}` itself). Both are documented at the top of `pipe.rs` and
`HookServer.swift` respectively.

**Credentials.** Never cross the IPC boundary. There is deliberately **no command that returns a key
value** — only `secret_present(key) -> bool`. The Anthropic key is read inside `claude.rs` and
attached as `x-api-key`; file bytes are read inside `claude.rs` too. `secrets.rs` enforces a
`KNOWN_KEYS` allowlist. The UI physically cannot display a stored key.

**Settings.** macOS persists via `didSet` observers on `AppState`'s `@Published` properties into
`UserDefaults`. Windows/Linux use `settings.json` in `platform::config_dir()`. Both re-sanitise saved
pill ids against the catalog on every load. `save_settings` emits `settings-changed` so the island and
the settings window stay in step without a restart.

**Integration polling.** Seven pollers (Stripe, n8n, GitHub, Vercel, Resend, Notion, Cal.com) with
identical delay/interval pairs on both platforms — the Rust header literally says *"the macOS
delays"*. Each tick first checks `PAUSED || !enabled(id)` and `continue`s: the cadence is preserved
but **zero HTTP requests happen**, so Pause really pauses the network, not just the UI. The first
poll populates silently to anchor the last-seen id; only later items announce.

**Cursor and click-through.** The front end *describes* the island rect via `set_island_rect`, but
Rust owns the accept/reject decision so it lands in the same 16 ms tick as the cursor read — an IPC
round trip there loses clicks. On Linux `platform::CURSOR_POLL` is `false`; the page derives the
cursor from its own `mousemove` events and click-through becomes an input region.

### The platform split

All OS differences live in `windows/src-tauri/src/platform/{windows,linux}.rs`. Both expose the
**same function names**; `mod.rs` `pub use`s one and `#[cfg]` picks. Everything else calls
`platform::…` and never names Win32 or GTK. Adding a platform capability means adding the function to
**both** files — a missing one is a compile error on the other target. That is the enforcement
mechanism; don't route around it.

macOS splits on `#if APPSTORE` (sandboxed `CoucouAppStore` target vs the direct `NotchBuddy`
target), declared in `project.yml`.

---

## Key Directories

| Path | Purpose |
|---|---|
| `NotchBuddy/Sources/App/` | All macOS Swift. 30 files, ~13k LOC |
| `NotchBuddy/Resources/sounds/` | The 28 WAVs. **The only copy in the repo** |
| `NotchBuddy/project.yml` | XcodeGen source of truth for the macOS project |
| `windows/src/` | Island + settings front end, 23 TypeScript files, ~7.3k LOC |
| `windows/src/mochi/` | Mochi and the launch greeting, Canvas 2D |
| `windows/src/island/` | FSM, DOM shell, rAF loop, hook/integration handlers |
| `windows/src/views/` | One builder per island view |
| `windows/src/core/` | `bridge.ts` (the only Tauri boundary), `state.ts`, geometry, easing, audio |
| `windows/src-tauri/src/` | Rust backend: window, relay, hooks, Claude API, pollers, secrets |
| `windows/src-tauri/src/platform/` | The entire Windows/Linux split |
| `windows/hook/` | `coucou-hook`, the relay Claude Code spawns. Its own crate, one dependency |
| `windows/dev/` | Browser-only harness for the file-drop choreography. Never bundled |
| `tests/` | Two standalone Swift test binaries. Not XCTest |
| `scripts/` | macOS test runners and the local release pipeline |
| `design/prototype/` | The original HTML prototype — the visual source of truth |
| `design/captures/` | Target screenshots for visual comparison |
| `docs/` | Spec (French), integrations (French), and the public site |

---

## Development Commands

**macOS** — requires Xcode 16+ and XcodeGen.

```bash
brew install xcodegen
cd NotchBuddy && xcodegen && open NotchBuddy.xcodeproj   # then ⌘R
```

Never hand-edit `NotchBuddy.xcodeproj`: change `project.yml` and re-run `xcodegen`. CI regenerates
before every build, so a hand edit is silently discarded.

Unsigned build, which is what CI runs:

```bash
xcodebuild -project NotchBuddy/NotchBuddy.xcodeproj -scheme NotchBuddy \
  -configuration Release build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

**Windows / Linux** — requires Rust, Node 20+ (CI pins 22), MSVC Build Tools on Windows, and on Linux
`libwebkit2gtk-4.1-dev libgtk-layer-shell-dev libayatana-appindicator3-dev librsvg2-dev libssl-dev patchelf`.

```bash
cd windows
npm ci                              # or npm install
npm run tauri dev                   # real dev build, live reload
npm run dev                         # front end in a plain browser, no app shell
npm run build                       # tsc --noEmit && vite build  ← the type gate
npm run pack                        # installer → windows/release/
npm run icons                       # regenerate src-tauri/icons from code
```

`npm run tauri dev` triggers `predev`, which runs `cargo build --release -p coucou-hook`. This is
deliberate and not optional: `tauri dev` puts the app in `target/debug`, while `ensure_hook_exe`
looks for the relay in `../release/`. A missing release build means Claude Code hooks silently never
install.

`windows/release/` gets two identically-built files with different names
(`Coucou-Windows-<v>-setup.exe` and the rolling `Coucou-Windows-setup.exe`) so local builds and CI
publish byte-identical artifacts. `target/release/coucou.exe` also runs standalone.

**Any change to `NotchBuddy/project.yml` requires re-running `xcodegen` before building.**

---

## Code Conventions & Common Patterns

No formatter or linter is configured anywhere in the repo — no `.editorconfig`, no
`.prettierrc`, no eslint, no `rustfmt.toml`, no `.swiftlint.yml`. Formatting is hand-maintained and
visibly uniform. **Match the surrounding file; don't reformat.**

**Compiler strictness is the real gate.**

- Swift: `SWIFT_VERSION 6.0` with `-strict-concurrency=complete` on both targets
  (`project.yml`).
- TypeScript: `strict`, `noUnusedLocals`, `noUnusedParameters`, `verbatimModuleSyntax`, `noEmit`.
  An unused import fails the build. `verbatimModuleSyntax` means type-only imports must be
  `import type { X } from "…"`.

**Naming.**

| | Swift | TypeScript | Rust |
|---|---|---|---|
| Types | UpperCamelCase | PascalCase | UpperCamelCase |
| Functions | lowerCamelCase | lowerCamelCase | snake_case |
| Constants | `enum IslandConst { static let … }` | SCREAMING_SNAKE tables | SCREAMING_SNAKE |
| Enum cases | lowerCamelCase | string unions | — |

There is no leading-underscore privacy convention in Swift. Privacy module scoping is the
mechanism in TypeScript — a helper is private simply by not being exported.

**The singleton idiom, used consistently across all three languages.** Implement the class
module-private, export the instance:

```swift
private init(); static let shared = HookServer()          // Swift
class AppState { … }; export const State = new AppState()  // TypeScript
```

**`windows/src/core/bridge.ts` is an absolute boundary.** It is the only file permitted to import
`@tauri-apps/api/core`, `/event` or `/webview`. Nothing else may call `invoke` or `listen`. When you
need a new capability, add a command in Rust and wrap it there.

**State management.** One mutable store per platform: `@MainActor ObservableObject` with
`@Published` on macOS; a `subscribe()`/`notify()` dirty-flag observer in TypeScript
(`State.notify()` sets a flag, the rAF loop calls `syncDom()`). No reducers, no immutability, no
framework reactivity. Every mutator ends with `notify()`.

**Error handling.**

- Rust: `Result<_, String>` with user-facing prose for anything a human reads
  (`"{path} changed since the preview. Nothing was written — review the new diff."`);
  `let … else { return }` internally; deliberately ignored OS results via `let _ =`. Exactly one
  `panic!` in the whole backend, where the app genuinely cannot run.
- TypeScript: `try/await/catch` where the error becomes user-visible; `void` on intentionally
  unawaited promises (`void Bridge.approvalAck(...)`).
- Logging: one helper, `log::line(...)`, writing timestamped, mode-0600, rotated at 1 MB. The UI
  writes through the same file with a `ui  ` prefix.

**Comments explain *why*, never *what*.** Density is high and deliberate. `// Present or pending so
recent charges show up immediately`. `// The wake strip must always take the mouse, and a resize
invalidates the flag.` File headers are present on all Rust and TypeScript files and routinely name
what the file is a port of.

**Concurrency.**

- Swift: `@MainActor` at the type level, never custom `actor` declarations. Background work uses
  exactly four shapes — `final class X: @unchecked Sendable` + `static let shared`, raw
  `Thread.detachNewThread`, `Task { @MainActor in … }` to hop onto main, `Task.detached` for real
  off-main work. Callbacks use `[weak self]` + `guard let self`.
- Rust: tokio for pollers and the relay; a raw `std::thread` for the 60 Hz cursor poll (fixed cadence,
  must not share the async runtime); `Mutex`/`Atomic*`/`LazyLock` for the shared singletons. Never
  hold a lock across an `.await`.
- `panic = "abort"` is load-bearing in the release profile — `hook/src/main.rs` notes there is
  deliberately no `catch_unwind` because it would be dead code.

### Invariants you must not break

These are stated in the code, in comments, with the reasoning attached. Breaking one is the failure
mode the author already fixed once.

1. **Claude Code is never blocked.** Every failure path resolves to *silence*, never to an error the
   terminal has to read.
2. **`~/.claude/settings.json` is never overwritten blind.** Unreadable settings are an **error**,
   not `{}` — "not knowing is not the same as empty". Then: dated backup, merge without touching
   foreign hooks, show a unified diff, write only from an explicit click.
3. **The fingerprint must match the preview.** `hooks::write` recomputes an FNV-1a hash and refuses
   if it differs from what the user actually looked at.
4. **Secrets never reach the front end.** No command returns a key value. Ever.
5. **No network call to an unconfigured service.**
6. **One card, one request.** A second `PermissionRequest` is declined, never allowed to replace a
   pending one.
7. **External agents never get an approval card** — a card shaped like a Claude Code request would be
   a lie.
8. **`coucou_agent` is validated and `claude` is reserved.** `validateAgent` is duplicated verbatim in
   `hooks.ts` and `HookServer.swift`. Change one, change both.
9. **Pill ids are a stable contract.** `integration_claude`, `agent_gemini`, … are persisted and used
   as hook-routing keys. Never rename. The Tauri mirror `INTEGRATION_AGENTS` must stay in lockstep.
10. **The FSM and the mode must not desync.** Always drive the FSM; never assign `State.mode` behind
    its back.
11. **A hidden island costs nothing.** `0 % CPU hidden` is a stated requirement. Any animation that
    keeps a timer alive while hidden breaks it.
12. **No stale timer may fire.** The universal pattern: capture a token or the current fd before
    scheduling, re-check it inside the closure.
13. **Hook command must survive the shell Claude Code uses** — Git Bash on Windows, single-quote
    escaping on Linux.
14. **Only http/https URLs reach the OS** (`SafeWebURL.swift`, Rust `open_url`). Model output can
    carry `file://` or `smb://`.
15. **Never shell out with a user-controlled path** — a folder name can contain `& ^ % $`.
16. **The two `HIT_MARGIN` constants (14 in `island.rs`, 14 in `island.ts`) must stay equal.**

---

## Important Files

| File | Why it matters |
|---|---|
| `CLAUDE.md` | The short house rules. Read before anything else |
| `NotchBuddy/project.yml` | XcodeGen source of truth; defines both macOS targets, `APPSTORE` flag, versions |
| `NotchBuddy/Sources/App/PillCatalog.swift` | Single source of truth for every pill: id, colour, category. Ids are contract values |
| `NotchBuddy/Sources/App/HookServer.swift` | macOS relay server, hook installer (embedded sh + Python as string literals), permission round-trip |
| `NotchBuddy/Sources/App/IslandStateMachine.swift` | The 4-state FSM. Pure, no AppKit |
| `NotchBuddy/Sources/App/BotEngine.swift` | Mochi's model and renderer |
| `windows/src/core/bridge.ts` | The only Tauri boundary |
| `windows/src/island/island.ts` | DOM shell, geometry, rAF loop, all input handling |
| `windows/src/island/fsm.ts` | The FSM port |
| `windows/src/mochi/engine.ts` | Mochi in Canvas 2D |
| `windows/src-tauri/src/platform/` | The whole Windows/Linux split |
| `windows/src-tauri/src/pipe.rs` | Relay server; the timeout ladder is documented at the top |
| `windows/src-tauri/src/hooks.rs` | Preview / fingerprint / merge / atomic write |
| `windows/src-tauri/src/secrets.rs` | `KNOWN_KEYS` allowlist |
| `windows/hook/src/main.rs` | The relay Claude Code spawns; budget and fail-open logic |
| `windows/vite.config.ts` | `SOUNDS_DIR` — the one and only place the shared sound folder is declared |
| `docs/SPEC.md` | Authoritative macOS behaviour/geometry spec (French). §7 is the Mochi spec |
| `docs/INTEGRATIONS.md` | Per-integration behaviour and the mandatory hook-install procedure (French) |
| `docs/AGENTS.md` | **Third-party agent integration contract** — not an AI-assistant guide. Read it before changing `coucou_agent` or the relay |
| `design/prototype/notch-buddy.html` | The visual source of truth |

---

## Runtime / Tooling Preferences

- **Node 20+**, npm. There is no root `package.json` and no workspace root — `windows/package.json`
  is the only one. CI uses `npm ci` on Node 22, so `windows/package-lock.json` is committed and must
  stay in sync. No Bun, no pnpm, no yarn.
- **Rust**: rustup, no pinned toolchain — there is no `rust-toolchain.toml`. `stable-x86_64-pc-windows-msvc`
  on Windows.
- **Zero third-party dependencies on macOS**, enforced structurally: no SwiftPM manifest, no
  `packages:` in `project.yml`. The Tauri app has exactly four npm packages and the hook crate has
  one. Hand-rolled instead of added: base64, the unified diff, FNV-1a, PNG/ICO icon encoding.
- **The 28 WAVs are not duplicated.** They live only in `NotchBuddy/Resources/sounds/` and are served
  by the `SOUNDS_DIR` constant. Building `windows/` from a checkout without `NotchBuddy/` ships a
  silent, audio-less app — the plugin warns and continues rather than failing.
- **Three version files must agree**: `windows/src-tauri/tauri.conf.json`, `windows/package.json`,
  `windows/Cargo.toml`. CI hard-fails a tag that disagrees with any of them. Editing one means
  editing all three. macOS versions live in `project.yml`.
- **The changelog is a single `## Unreleased` section.** No version headings, no dates, no template.
  Append bullets in English, past tense, platform qualifiers in parentheses, `— thanks @handle` for
  contributors. Nothing reads or validates it.
- **Licensing split**: code is MIT; the name, character, icon, sounds and `design/` + `docs/media/`
  assets are © Louis Raillé and excluded. A fork shipping under its own name must rename.
- **Privacy page is a legal artifact.** `docs/privacy.html` is bilingual and enumerates every
  outbound request. Adding telemetry or a new data store means updating it in both languages.
- **No secrets on disk or in git.** `.env*` is ignored, as is `.claude/` and `_prive/`.

---

## Testing & QA

There are three suites and no TypeScript test runner. `find windows -name "*.test.ts"` returns
nothing: there is no vitest, jest or playwright anywhere.

| Suite | Command | Location |
|---|---|---|
| Swift geometry | `bash scripts/test-screen-geometry.sh` | `tests/IslandScreenGeometryTests.swift` |
| Swift URL filter | `bash scripts/test-safe-links.sh` | `tests/SafeWebURLTests.swift` |
| Rust | `cargo test --workspace` | inline `#[cfg(test)] mod tests` |

**Swift tests are not XCTest.** They are standalone `@main enum … { static func main() { precondition(…) } }`
binaries compiled directly by `swiftc` — one production file plus one test file — and run from a
sibling shell script. Note they print a **hand-written** case count as their last line; if you add an
assertion, update that string or the output becomes a lie. Do not introduce XCTest without also wiring
it into `build.yml`.

**Rust tests** live at the bottom of the file they test: `claude.rs` (1), `files.rs` (1), `hooks.rs` (8),
`platform/linux.rs` (2), `hook/src/main.rs` (3). Test names are full sentences describing the
guarantee — `unreadable_content_is_an_error_never_an_empty_object`,
`rewriting_settings_never_widens_its_permissions`, `anything_unrecognised_prints_nothing`. Follow
that style: name the guarantee, not the function. Several are `#[cfg(unix)]`-gated, so running
`cargo test` on Windows silently shows fewer tests with no skip notice.

**Type-checking is the only front-end gate**, and it is partial: `tsconfig.json` includes only
`"src"`, so `vite.config.ts`, `scripts/*.mjs` and `dev/upload-preview.ts` are never checked. And
`npm run dev` / `npm run tauri dev` do not type-check at all — errors accumulate silently until
`npm run build` or `npm run pack`.

**CI reality.** `build.yml` (every push/PR) compiles the macOS app and runs both Swift scripts — that
is the *only* PR-visible gate for `NotchBuddy/`. `linux.yml` runs `cargo test --workspace` and a full
`APPIMAGE_EXTRACT_AND_RUN=1 npm run pack`, but **only when a PR touches `windows/**`**. A PR touching
neither tree runs nothing. `windows.yml` only compiles. `release.yml` only build-checks macOS on a
tag — notarization happens locally via `scripts/release.sh`, which CI never runs.

**Manual QA you must do yourself.** There is no automated visual check. `design/captures/` holds the
target screenshots (16 views, 11 character states, 5 emotes) and `docs/SPEC.md` §11 defines the
milestone ritual: build → capture → compare against the references → commit. For the file-drop
choreography, run the browser harness:

```bash
cd windows && npm run dev
# → http://127.0.0.1:1420/dev/upload-preview.html  replays it on a 12 s loop
```

To exercise the real window, `npm run tauri dev`. To see the relay end to end, send a hook event by
hand — `coucou-hook.exe SessionStart` with JSON on stdin — and watch `%LOCALAPPDATA%\Coucou\coucou.log`.

**Adding a test?** Match the existing conventions of the suite you are adding to, and write one that
catches a plausible consumer-visible bug. Wiring wiring, forwarding, or "it did not throw" is not a
test.
