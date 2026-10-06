# Windows parity plan — 1.0.0 Lighto Edition (0.1.7 base)

Living status of the five agreed features, what each one needs, how macOS does it,
and how Windows implements it. The document began as a pre-implementation plan; §3
now records the completed Windows Desktop Mochi design and its remaining real-device
checks.

Read this alongside `DIVERGENCE-1.0.0-Lighto-vs-0.1.7.md`, which records what the
Windows fork already changed relative to upstream.

---

## Where things stand

| # | Feature | Progress | Remaining work |
|---|---------|----------|----------------|
| 1 | Global keyboard shortcuts | Implemented in the Windows parity work | Recheck actual registrations/conflicts on the installed build |
| 2 | Codex agent support | **Built and tested** | Live Codex session test only |
| 3 | Desktop Mochi | **Windows port implemented; NSIS built** | Install/test dragging/taskbar, sizing, Music and approval behavior on-device before claiming visual success |
| 4 | Wardrobe | Not started | Largest item — Swift outfit drawing to port |
| 5 | Chat provider (Claude / Pi) | **Built, verified end-to-end** | Live check with a reachable model |

Decisions taken so far:

- Chat uses a **separate Pi process**, never the running agent's session. Coucou chat
  is a small window to talk to a model; it must not disturb or attach to whatever an
  agent is doing. `--no-session` confirmed.
- The `pi-permission-system` patch stays **hand-applied**. Coucow does not manage it,
  including on uninstall. Recorded in `PI-PERMISSION-SYSTEM-NOTES.md`.

Also fixed while preparing this plan:

- Settings window opened **behind** the always-on-top island, so its title bar was
  unreachable and you had to resize it before it could be dragged clear. The window
  now shares the island's z-order.

Current verification for the Windows tree (counts change as tests are added):

```
npx tsc --noEmit                         clean
npm run test:mochi                       pass
npm run test:pills                       pass
npm run build                            Vite production build succeeds
cargo fmt --all --check                  clean
cargo test --manifest-path src-tauri/Cargo.toml  33 passed, 2 ignored (latest run)
```

A fresh Windows NSIS installer has been built at
`windows/target/release/bundle/nsis/Coucou_1.0.0_x64-setup.exe` (SHA-256
`C9A3EA805C3A18F29E80BC7A99C691A520AFA509D0E597685DEC203CC0FF63C0`). It has not been
installed. Build/test results are not visual verification. Desktop Mochi's latest drag,
taskbar, Music and permission behavior still needs an installed-app test.

---

## 1. Global keyboard shortcuts

### What macOS does

`HotKeyCenter.swift` registers `Carbon` hot keys process-wide. `ShortcutLogic.swift`
decides what each chord does, `ShortcutsSettingsView.swift` exposes them, and the
`KeyboardShortcuts` entry in the notch settings toggles registration.

Registered in the 0.1.7 merge:

| Chord | Action |
|---|---|
| `Ctrl+Alt+C` | Toggle Coucou |
| `Ctrl+Alt+O` | Quick Ask |
| `Ctrl+Alt+K` | Quick Keys / bring island forward |

### Why Windows needs something different

macOS `Carbon` global hot keys have a Windows equivalent, but the naive port has a
trap: **`RegisterHotKey` needs a message loop on the thread that registered it**, and
Tauri's main thread already has one. Registering from a random thread silently
produces hot keys that never fire.

So the Windows work is:

1. A dedicated hot-key thread with its own message pump.
2. `RegisterHotKey` calls with failure reporting per chord.
3. `UnregisterHotKey` on shutdown and on settings change — re-registering without
   unregistering first leaks handles.
4. **Conflict UI**: if a chord is already taken by another app,
   `RegisterHotKey` returns `ERROR_HOTKEY_ALREADY_REGISTERED`. That must surface as
   a per-shortcut warning, not a silent no-op.

### Island-scoped shortcuts (first pass)

Before going global, the island already handles **Y / N** on the approval card —
this works today and must keep working. The first pass extends plain `keydown`
handling inside the island so the common actions work whenever the island is open,
without needing a global registration at all:

| Key | Action |
|---|---|
| `Y` / `Enter` | Allow |
| `N` / `Esc` | Deny |
| `Enter` on a note | Submit note |
| `Esc` on a note | Clear note |

**No front-window capture.** These are decided entirely by the island having focus.
Nothing is read from, or written to, the focused foreground application — no
window title, no window rect, no screenshot. That stays true for both passes.

---

## 2. Codex agent support — done

### What macOS does

Writes `~/.codex/hooks.json`, shaped like Claude Code's matcher map. From
`HookServer.swift`:

```swift
static var codexHooksURL: URL {
    ...appendingPathComponent(".codex/hooks.json")
}
```

Event table, with the `PermissionRequest` deliberately long because a human has to
answer it:

| Event | Timeout | Note |
|---|---|---|
| `SessionStart` | 10s | |
| `UserPromptSubmit` | 10s | |
| `PreToolUse` | 10s | |
| `PermissionRequest` | 120s | Shows `Waiting for your answer in the notch (Coucou)` |
| `PostToolUse` | 10s | |
| `Stop` | 10s | |
| `SubagentStop` | 10s | |
| `SessionEnd` | 3s | |

Pill `agent_codex`, colour `#2DD4BF`.

### What Windows does now

Implemented and tested:

- `settings_path_for_agent("codex")` → `~/.codex/hooks.json`
- Same matcher-map shape, same event names, same timeouts — including
  `SessionEnd` at 3s and `PermissionRequest` at 120s, so the two platforms behave
  identically
- Pill `agent_codex` / `#2DD4BF`
- Added to the Windows agent picker with its own restart hint

Rather than copy the Antigravity merge, the Claude-shaped merge was generalised into
`matcher_merged(agent, existing, events)` and both Antigravity and Codex call it.
Claude Code, Antigravity and Codex now share one code path.

**Tests added:**

- `codex_uses_the_matcher_shape_and_leaves_foreign_hooks_alone` — a user's own
  `PreToolUse` hook survives install *and* uninstall; unrelated config (`model`) is
  untouched; `SessionEnd` is 3s
- `codex_and_antigravity_do_not_share_a_file` — guards against two agents being
  pointed at one settings file, which is how integrations clobber each other
- `every_agent_gets_its_own_settings_file` — extended to include `codex`

**Still to do:** live test against a real Codex session. There is no Codex
installation on this machine yet.

---

## 3. Desktop Mochi — Windows port implemented; parity verification remains

### macOS reference

`NotchBuddy/Sources/App/DesktopMochiLogic.swift` owns portable geometry/lifecycle
rules; `DesktopMochi.swift` owns the native macOS window and renderer. Keep this as
the behavior reference, not as a reason to copy AppKit APIs into Windows.

### Windows architecture

Windows has a transparent Tauri WebView window (`mochi.html`) created hidden during
Tauri setup, then shown on demand. The desktop window reuses the island's `BotEngine`
so appearance, state transitions and particles share one renderer. It has an
independent render loop, which keeps the desktop pet alive when the island retracts.

Relevant implementation:

- `windows/src/mochi/desktop.ts` — pure geometry, hit testing and sleep/lifecycle rules.
- `windows/src/mochi/desktop-main.ts` — renderer, gestures and 50 ms native runtime poll.
- `windows/src/mochi/engine.ts` — shared Mochi drawing, state animations and particles.
- `windows/src-tauri/src/desktop.rs` — WebView window, monitor bounds, cursor polling,
  click-through and position persistence.
- `windows/src-tauri/src/settings.rs` — persisted `desktop_mochi`, size and position.
- `windows/src/island/island.ts` / `windows/src/main.ts` — island animations and state
  synchronization.

### Current behavior and deliberate choices

- The pet is free-floating, draggable, clickable, transparent and topmost; it reuses
  `BotEngine` rather than introducing another renderer.
- Default size is **120 logical px**; island Settings has a **72–240 px** slider and
  Reset-to-120 control beside Sound. The Mochi controls wrap together if the row is
  constrained, so the slider/reset remain accessible. Old settings files use the default.
- First launch is inset in the work area. Saved positions and drag use full physical
  monitor bounds with zero edge margin, allowing taskbar overlap while staying on-screen.
- Rust polls the **global physical cursor** for both circular click-through hit testing
  and drag movement. Drag tracking continues if the pointer leaves the WebView/enters the
  taskbar; it persists the final position once the mouse is released.
- The runtime poll carries focused pill ID/color/state, cursor offset, visibility and
  drag state. This avoids relying on event delivery between separate WebViews.
- Sleep is based on the existing idle timeout plus cursor distance, not on island
  visibility. A proximity wake resets the idle timer so it cannot immediately fall back
  asleep when the cursor leaves.
- Music playback produces floating notes/mouth movement on the Music mini-pet and when
  Music is focused. `BotEngine.update` consumes **seconds**; the desktop RAF converts
  browser milliseconds before updating so transient particles stay alive.
- A visible desktop pet receives the pending-permission flag, shows the approval warning,
  then briefly animates home and hides. The island re-forms Mochi when the settings state
  changes.
- The Music card places Music and Playing/Paused side-by-side with aligned status dot
  diameter, typography and spacing.

### Parity / verification status

These are implemented in the Windows source, but the latest changes are not yet visually
verified in a fresh installed build. Build only NSIS (`npm run tauri build -- --bundles
nsis`); do not build MSI. On the real display test bottom-taskbar reach at the smallest and
largest sizes, taskbar occlusion/z-order, multi-monitor DPI, release persistence, wake,
Music playing/paused, permission arrival/resolution, and bring-home/release flows.

Music playback data uses Windows GSMTC. The existing macOS music controller is separate;
compare the user-visible singing behavior there before claiming cross-platform parity.
Likewise, verify the native Swift permission-return flow before claiming the Windows
warning/return animation is at parity. A successful build/test suite only proves code
compiles and pure rules pass.

If a pet seems to stop at a visible gap before the taskbar, inspect the actual physical
monitor bounds, `outer_position`, `inner_size`, scale factor and taskbar z-order. Do not
move it off-screen or assume the work-area clamp is still active: current drag clamps use
the full monitor rectangle, while initial placement intentionally uses the work area.

### Risks

- WebView2 initialization order and Windows topmost/taskbar z-order need a real install test.
- Physical vs logical pixels differ on scaled/mixed-DPI displays; Rust must remain the
  authority for physical positioning and global cursor math.
- A click-through WebView cannot reliably see pointer events, which is why click-through
  and drag movement are polled natively rather than repaired with frontend mouse events.

---

## 4. Wardrobe

### What macOS does

The largest single item. Roughly 1,464 lines in the Swift sources, mostly drawing:
outfits are composed from layered pieces, each with its own colour, trim and
accessory rules.

### Windows implementation

This is a drawing port, not a feature port. The shapes on macOS are drawn with
SwiftUI / CoreGraphics paths; on Windows they have to be redrawn in whatever the
Mochi renderer already uses — most likely SVG in the webview, since that is how the
existing pet is drawn.

Practical sequence:

1. Extract the **outfit data model** from the drawing code — which pieces exist,
   which combine, what each is called. This part is portable and is the whole
   "wardrobe" concept.
2. Port the data model to TypeScript.
3. Redraw the pieces as SVG, one per garment, validating each against the Swift
   original visually.
4. Add unlock/persistence once the pieces render correctly.

Doing it in that order means the model is right before any pixels are drawn, and
each step is independently verifiable.

**This is a multi-session item.** It should not be attempted until items 1, 3 and 5
are working, because it has the worst effort-to-feedback ratio of the five.

---

## 5. Chat provider — Claude or Pi

### The actual problem

Right now the island chat always goes to Claude. `windows/src-tauri/src/lib.rs`
sends through `claude::send(...)` using `settings.model`, regardless of which agent
is active. So if you are working in Pi, the island chat still talks to Claude Code.

Pi must not be represented as a model. It is a different *thing*: a full agent with
its own sessions, tools and permissions.

### What Pi actually offers

Pi ships an RPC mode. `@earendil-works/pi-coding-agent` 1.0.2 exposes:

```
pi --mode rpc --no-session
```

It then speaks JSONL over stdin/stdout. Requests look like:

```json
{"id":"req-1","type":"prompt","message":"..."}
```

and events stream back on stdout. That is a real agent interface — the same Pi that
runs your terminal session, with your own extensions, including the Coucou
permission extension installed above.

### Windows implementation — done

**Settings** gained a `chatProvider` field, separate from `model`, defaulting to
`claude` so every existing install keeps working unchanged.

**`pi.rs`** mirrors `claude.rs`:

- Spawns `pi --mode rpc --no-session` on demand and kills it rather than reusing it
- Writes JSONL to stdin, reads records until `agent_settled`
- **No fallback to Claude.** If Pi is unavailable the island says why instead of
  quietly answering from a different provider, which would leave you with no way of
  telling which model you were actually talking to.
- `chat_reset` tears the process down too — Pi holds the conversation itself, so
  leaving it alive would carry the old history into a chat you believe is empty.
- A failed turn kills the process, because its state can no longer be vouched for.

**Settings UI**: a Claude / Pi segmented control. Choosing Pi shows **no API key
field and no model list** — the Claude rows are removed from the tree rather than
hidden, so they are genuinely gone from the accessibility tree too. Pi is already
authenticated; offering a key would imply a configuration that does not exist.

### Four things that only live testing found

The docs are not wrong, but they are quiet about the details that decide whether
this works at all. Each of these was found by running it, and each would have
shipped as "Pi is broken":

1. **Text does not always stream.** `message_update` / `text_delta` appear on some
   turns and not others. A short reply, or a failed turn, emits `message_end`
   alone. Reading only the streaming events returns **nothing at all** for those
   turns — an empty island with no error. The text is therefore read from the
   finished assistant message as well.

2. **Model failures are not a separate record.** They arrive as
   `stopReason: "error"` with `errorMessage` on the assistant message. There is no
   error record to match on, so without this a quota or auth failure is
   indistinguishable from the model choosing to say nothing.

3. **`pi` is a `.cmd` shim on Windows.** `CreateProcess` cannot execute it, and
   Rust's `Command` cannot either. It has to go through `cmd.exe /c`. Getting this
   wrong fails with a misleading "bad executable format" rather than anything
   mentioning the shim.

4. **Closing stdin means shut down.** Pi reads an EOF on stdin as "exit". A client
   that writes a prompt and closes stdin gets no answer at all, and the symptom is
   a silent timeout. The stdin handle is held open for the life of the session.

Also handled: extensions can ask the client for UI. Fire-and-forget methods
(`notify`, `setStatus`, `setWidget`, `setTitle`) expect no reply; dialog methods
(`select`, `confirm`, `input`, `editor`) do, and are answered `cancelled` so
nothing stalls waiting for a dialog that a chat window has no way to show.

### Verification

`pi::tests::a_real_pi_turn_either_answers_or_says_why_it_could_not` runs against the
installed `pi` and is `#[ignore]`d by default since it needs Pi and a reachable
model. Run against this machine it reports:

```
Pi reported: Pi could not reach its model: {"error":{"message":"...code": 429,
  "You exceeded your current quota..."}}
```

That is the correct outcome: the installed Pi defaults to `gemini-3.1-pro-preview`,
whose free-tier quota is exhausted. The point of the test is that the failure
surfaces as the provider's real reason rather than as silence — which is exactly
what fix 2 buys. With a model that answers, the same path returns its text.

`--no-session` was confirmed working; an earlier apparent failure was a test
harness that closed stdin, not the flag.

### Open question

**Settled: `--no-session`.** Coucow chat runs its own `pi --mode rpc --no-session`
process. It never attaches to, shares history with, or otherwise touches the session
an agent is using. Coucou chat is a small window for talking to a model, not a
remote control for a running agent — attaching would mean the island could act on
live work, and a permission prompt from the island would belong to somebody else's
session.

A separate process also means no shared state to corrupt: killing the island's Pi
cannot interrupt an agent's Pi, and vice versa.

---

## Appendix: the Pi hook

**Settled: the `pi-permission-system` patch is not Coucou's to manage.** It stays
hand-applied, including on uninstall. The full record of what was changed and why is
in **`PI-PERMISSION-SYSTEM-NOTES.md`** — that document is the reference if this is
ever revisited.

What remains here is the part that *was* wrong and has been fixed.

### The bug

Coucou was saying:

> There is already a Pi extension at `C:\Users\msi\.pi\agent\settings.json` that
> Coucou did not write…

Two faults, both real:

1. **Wrong file.** `settings.json` is Pi's own settings file, not an extension. On
   this machine it holds `theme`, `defaultProvider`, `defaultModel` and `packages` —
   no Coucou content. Coucou never intended to write there. The file it actually
   manages is `~/.pi/agent/extensions/coucou.ts`.
   `status("pi")` was filling `settings_path` from `settings_path_for_agent("pi")`,
   so the status object reported one path while acting on another.

2. **Wrong reason for refusing.** Ownership was tested by byte-equality with the
   generated extension. That can never hold on a live machine, because the relay
   path is substituted per install and the file gets corrected by hand as the
   integration matures. So a working Coucou extension was reported as a stranger's,
   and install and uninstall were **permanently refused** for Pi.

### The fix

**Ownership is now a signature test**, not byte-equality: an extension is Coucou's if
it references `coucou-hook`. Every Coucou extension must name the relay to work, and
no unrelated Pi extension has any reason to.

The property that actually matters is unchanged and still tested: an extension Coucou
did not write is never overwritten on install and never deleted on uninstall. A
hand-written extension of your own carries no relay reference, so it is still left
alone.

**`status("pi")` now reports `pi_extension_path()`**, so the UI names the file Coucou
manages instead of one it never wrote.

### Shared-file model

`settings.json` is **never written**. It is not an extension, it holds only Pi's own
configuration (`theme`, `defaultProvider`, `defaultModel`, `packages`), and Coucou
has nothing to put in it. The extension file is the only artefact Coucow manages
for Pi.

### No backup, by design

The Pi extension is **generated** — it lives in the binary as `PI_EXTENSION_CODE`
with the relay path substituted at write time. Any version Coucou has ever written
can be regenerated exactly, so an old generated file is never something worth
restoring. A backup could only ever preserve a hand-edit to Coucou's own extension,
and the next Coucou update would overwrite that edit anyway.

So: **install writes, uninstall deletes.** What replaces a backup is the preview —
both operations show a diff of the current file first, so a difference is visible
and confirmed rather than silently destroyed.

The one guard that is *not* negotiable: an extension Coucou did not write is never
overwritten on install and never deleted on uninstall. That is tested.

---

## Suggested remaining work

1. Rebuild the Windows NSIS installer after the current desktop/Music/UI edits, then verify
   the installed app on the user's display. Do not install it without explicit approval.
2. Run live Codex/shortcut checks where the corresponding tools and conflicts are present.
3. Decide and implement wardrobe as its own drawing-port project; it remains the largest
   unstarted feature.
4. Compare Windows Music/permission-return behavior against the native Swift implementation
   before recording those features as cross-platform parity.

The Pi path and ownership fixes described in the appendix remain in place. The working
tree is intentionally uncommitted.
