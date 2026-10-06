# Desktop Mochi — implementation and extension guide

**Repository:** `C:\Users\msi\coucou` (Windows Coucou 1.0.0 Lighto Edition, based on 0.1.7)  
**Windows project:** `C:\Users\msi\coucou\windows`  
**Status:** implementation is in the working tree; builds/tests do not replace a real installed-app check. Do not claim taskbar, music, approval, or visual behavior verified until tested in the installed app.

## What Desktop Mochi is

Desktop Mochi is a borderless, transparent, always-on-top Tauri WebView containing the same TypeScript `BotEngine` used by the island. It is an independent renderer: the island can retract and stop rendering while the desktop window continues animating, polling global cursor position, and receiving focused-pill state. The desktop window is not the integration/pill itself; it is Mochi reflecting the island's current focus, with a few pill-specific effects (currently Music and pending permission).

The design keeps one source of truth for pet drawing and state behavior. Platform-specific work—window lifetime, monitor geometry, global cursor sampling, click-through, and settings persistence—belongs in Rust.

## Architecture / data flow

```text
Agent + integrations + media event handlers
                  │
                  ▼
              core/state.ts
       focusTask, effectiveState, color,
       Music playing, pendingApproval
                  │ State.subscribe
                  ▼
              src/main.ts
 desktopMochiSync(state, color, pillId,
                  musicPlaying, permissionPending)
                  │ Tauri command
                  ▼
       src-tauri/src/desktop.rs
       PET_SNAPSHOT + native runtime
                  │ desktop WebView polls ~50 ms
                  ▼
       src/mochi/desktop-main.ts
       BotEngine + canvas + gestures
```

Relevant files:

| File | Responsibility |
|---|---|
| `windows/src/mochi/desktop.ts` | Pure geometry, body hit test, sleep policy, transition rules and shared constants. Keep its Rust mirror and tests aligned. |
| `windows/src/mochi/desktop-main.ts` | Desktop WebView entry: canvas/render loop, gestures, native-runtime polling, music notes, permission return, wake/sleep. |
| `windows/src/mochi/engine.ts` | Shared Mochi renderer/state animations/particles; now includes music-note particles and singing mouth motion. |
| `windows/src/mochi/minibots.ts` | One `BotEngine` per visible mini Mochi in a pill/compact grid; Music mini sings when the media session is playing. |
| `windows/mochi.html` | Desktop pet HTML entry. Vite must include it. |
| `windows/src-tauri/src/desktop.rs` | Native window, physical monitor bounds, global cursor hit test and drag poll, settings position, runtime snapshot. |
| `windows/src-tauri/src/settings.rs` | Persisted desktop enablement, panel size and last physical position. |
| `windows/src-tauri/src/lib.rs` | Creates the hidden pet window during setup; registers commands and handles preference changes. |
| `windows/src/main.ts` | Subscribes to state and sends focused state/color/id plus Music and permission flags to Rust. |
| `windows/src/island/island.ts` | Island Mochi, mini-bot syncing, island render scheduling, home/out transitions. |
| `windows/src/island/hooks.ts` | Agent hook events, including `PermissionRequest` and pending-approval state. |
| `windows/src/views/integrations.ts` / `windows/src/style.css` | Integration cards and Music status/header styling. |

## Window, positioning, click-through and taskbar dragging

- Rust creates the pet window hidden in Tauri `setup()`, before showing it. WebView2 initialization is sensitive to creation timing; preserve this lifecycle unless a real installed-app test proves a change safe.
- The window starts at the configured square logical size. The UI setting is persisted as `desktopMochiSize` / `desktop_mochi_size`, default **120 logical px**, bounded to **72–240 px**. Existing settings JSON without the field loads with the default. Island Settings has a slider and **Reset** to 120 px, grouped alongside Sound; the group wraps as a unit on narrow layouts so the slider/reset do not get clipped.
- First launch uses the monitor work area, leaving an inset above the taskbar. Saved positions and active drags clamp to the **full physical monitor bounds**, with zero drag margin, so the window can overlap the taskbar but not leave the monitor. Logical window size is multiplied by the selected monitor's scale factor only when doing physical geometry.
- `desktop_mochi_drag_start` records the physical cursor and window origin in Rust. The native polling loop moves the window from the global cursor while the left button is down; it does not depend on continued WebView `mousemove` delivery. This matters when the pointer enters transparent/click-through areas or crosses the taskbar. During drag, Rust reasserts topmost z-order to avoid the shell taskbar covering Mochi. On release it logs final position, window size, monitor bounds/scale, and work area, then commits the position once.
- `cursor_offset()` reads global physical cursor/window geometry and converts the offset to panel-logical pixels. Rust switches click-through based on a circular body hit region; the transparent square corners pass input to the desktop. Never rely on frontend mousemove to recover hover while click-through is enabled.
- The runtime command returns the current focused-pill snapshot, cursor offset, visibility and drag state. Desktop frontend polls it instead of depending on events crossing between WebViews.

**Taskbar issue to verify:** the latest build reasserts topmost z-order during drag and logs the final physical geometry. Validate by dragging Mochi to the screen bottom; if it still stops early, inspect the `mochi: drag end ...` line in `%LOCALAPPDATA%\\Coucou\\coucou.log` before changing clamp constants. Do not “fix” it by placing the window off-screen.

## Pill/state synchronization

`main.ts` subscribes to `State` and sends these fields to `desktop_mochi_sync`:

- `State.effectiveState` — state of the focused task / current override.
- `State.focusTask.color` and `.id` — body color and identity.
- `musicPlaying` — true when Music is focused and its media data reports `playing: true`.
- `permissionPending` — true while an approval is awaiting the user.

Rust stores the latest snapshot. The desktop WebView applies state/color changes and logs them through `desktop_mochi_probe` to `%LOCALAPPDATA%\Coucou\coucou.log`. A new pill that uses the ordinary task model should automatically drive the pet's normal focused state/color. Add an explicit snapshot field only for behavior that cannot be represented by the task's normal state (Music playback and pending permission are examples).

State badge hues are semantic: BotEngine `thinking` uses purple; `working` uses blue. Pi hooks report `thinking` at prompt submission and `working` during tool execution, so the dots can change color as Pi changes phase. The focused pill body remains the pill's own color.

## Music singing behavior

Windows Media/GSMTC updates `State.integrations.integration_music.data` through the `media-changed` event. The Music mini-bot sets `engine.singing` from its playing flag and emits floating music-note particles plus a rhythmic mouth animation. When Music is focused, the island Mochi and desktop Mochi can use the same effect. Music playing keeps the visible island render loop active so the mini-pet's particles continue to animate.

`BotEngine.update(dt)` expects **seconds**. The desktop RAF loop must convert its `performance.now()` delta from milliseconds to seconds before calling it. Passing milliseconds makes short-lived particles (notes, hearts, teleport sparks) expire in one frame. This is also why a code build alone is not proof that notes are visible; test with a real playing media session.

## Permission warning and return-home flow

For a real blocking approval, `island/hooks.ts` sets the task to approval and stores `State.pendingApproval`. `main.ts` propagates `permissionPending` in the snapshot. If Desktop Mochi is visible, its WebView shows the approval state (including the exclamation/bounce) briefly, animates `teleportOut()`, then disables/hides the desktop window. On the island, the settings event first applies the returned setting and schedules the entrance for the next animation frame, after the canvas is visible again. If the island was hidden, it is revealed so the arrival is visible. A diagnostic line records the island-side entrance. If permission resolves before the warning delay completes, the pending flag clears and the scheduled return is cancelled.

Third-party transient agents that do not block for Coucou's answer must continue to be declined/handled according to `hooks.ts`; do not make an unusable approval card look actionable. Check `PermissionRequest` routing before adding another agent.

## Sleep/wake

Desktop Mochi uses the shared policy: it sleeps after the idle timeout (currently 120 seconds) **and** when the pointer is outside the configured radius. Moving the pointer close wakes it. The wake caused by cursor proximity must refresh `lastActiveMs`; otherwise the stale timer can put Mochi back to sleep as soon as the pointer leaves. This policy is independent of the island's hidden/visible render loop; the desktop WebView has its own RAF and Rust runtime poll.

## Adding a new pill / integration that Mochi can follow

Follow this sequence; do not add a pill only in the view layer:

1. **Identity and color:** add the stable task/integration ID, display name, color and source in `windows/src/core/state.ts`. Keep IDs/colors aligned with `NotchBuddy/Sources/App/PillCatalog.swift` when the same pill exists on macOS.
2. **Budget and enablement:** include it in the correct declared-agent/integration/disabled-agent lists and settings UI. Check `MAX_PILLS` and the shared agent/integration budget; add a `pill-budget.test.ts` case for inclusion, refusal-at-cap and disabling.
3. **Event/data source:** wire Rust/native events or hook events through `core/bridge.ts`, `main.ts` and/or `island/hooks.ts`/`island/integrations.ts`. Use the task's `state` for ordinary BotEngine states and call `State.notify()` after data changes.
4. **Card UI:** add a `renderIntegrationCard()` branch in `views/integrations.ts` only if the generic agent/activity card is insufficient. Keep title/status/controls in the common card layout and style in `style.css`.
5. **Mochi behavior:** ordinary focused pills need no new desktop code: the state subscription sends focused ID, color and state. For a special effect, add the minimum explicit signal to `DesktopMochiSnapshot` in `core/bridge.ts`, `PetSnapshot`/`desktop_mochi_sync` in Rust, the snapshot producer in `main.ts`, and the consumer in `desktop-main.ts` or `minibots.ts`. Keep the data boolean/simple and clear it on pause/stop/focus change. If the island Mochi or mini Mochis should also animate, update `island.ts`/`minibots.ts` and ensure RAF scheduling remains awake only while needed.
6. **Lifecycle:** decide what happens on idle, stop, permission, error, disable and session end. Do not leave a stale state or pending timer after focus changes or a permission is resolved.
7. **Tests:** extend `tests/pill-budget.test.ts`, `tests/desktop-mochi.test.ts`, and/or Rust tests for each pure rule. Add no unsupported visual claim.
8. **Parity:** port the same user-visible behavior to macOS if it is intended as shared Coucou behavior. The native Swift implementation is under `NotchBuddy/Sources/App/`; keep platform window/cursor code native and share only concepts/data, not Windows-specific APIs.

Useful searches before adding a pill: `INTEGRATION_AGENTS`, `TOGGLEABLE_INTEGRATION_IDS`, `MAX_PILLS`, `loadIntegrationTasks`, `renderIntegrationCard`, `media-changed`, `desktopMochiSync`, `syncMiniBotStates`.

## Verification and release

From `C:\Users\msi\coucou\windows`:

```powershell
npx tsc --noEmit
npm run test:mochi
npm run test:pills
npm run build
cargo fmt --all --check
cargo test --manifest-path src-tauri/Cargo.toml
cargo build --manifest-path src-tauri/Cargo.toml --release
```

Windows NSIS only (do not build MSI):

```powershell
npm run tauri build -- --bundles nsis
```

Expected NSIS output is under `windows\target\release\bundle\nsis\`. Do not install/reinstall or overwrite a known-good binary without approval. Validate installed behavior separately: show/hide, size persistence/reset, dragging across monitors and onto the taskbar, cursor wake/sleep, focused pill color/state, Music notes while playing/paused, and approval warning/return.

## Backup and cleanup

`C:\Users\msi\coucou - backup` is a source snapshot created at the user's request. It contains the source/docs and an NSIS installer copy, but intentionally excludes `.git`, `node_modules`, `windows\target` and `dist` build caches. Its installer was hash-verified against the preceding built installer. `C:\Users\msi\coucou-backup-1.0.0-working.zip` is an earlier source archive. The stale `C:\Users\msi\coucou - Copy` and `C:\Users\msi\coucou - Copy (2)` directories were compared against current source (build caches excluded), found to contain no unique source files, and removed at the user's request. No `.coucou` directory existed under `C:\Users\msi` at cleanup time.

## Current verification caveat

A fresh Windows NSIS build after the latest taskbar drag polling, Music animation/card styling, and resilient in-island Settings layout completed at:

```text
C:\Users\msi\coucou\windows\target\release\bundle\nsis\Coucou_1.0.0_x64-setup.exe
SHA-256: C9A3EA805C3A18F29E80BC7A99C691A520AFA509D0E597685DEC203CC0FF63C0
```

It has **not been installed or visually tested**. Successful TypeScript/Vite/Rust builds prove compilation, not rendering, WebView2 health, taskbar z-order, Music particles, or approval timing. Verify those in the installed app before claiming them done. Leave the working tree uncommitted unless the user asks otherwise.
