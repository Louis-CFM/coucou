# Coucou Linux — Migration Architecture (Phase 1)

## Verdict

Keeping SwiftUI/AppKit on Linux is impractical (no AppKit, no notch `NSPanel`, SwiftUI Linux is immature).  
**Linux implementation: Tauri 2 + TypeScript/Canvas frontend**, with platform services in Rust.

macOS (`NotchBuddy/`) stays untouched. Linux lives under `apps/linux/`.

## Mapping

| macOS | Linux |
|-------|-------|
| `NSPanel` + click-through | Transparent always-on-top Tauri window, hit-test CSS / `ignoreCursorEvents` |
| Notch geometry | Floating top-center companion (184×32 default) |
| `IslandStateMachine` | TS port (`core/fsm.ts`) |
| `AppState` | TS store (`core/state.ts`) |
| `BotEngine` + Canvas | Canvas 2D (`bot/engine.ts`) from prototype + Swift |
| `HookServer` + Unix socket | Rust `hook_server` → events to frontend |
| `nb-hook` (Python) | Same protocol; XDG path `$XDG_DATA_HOME/coucou/nb.sock` |
| Keychain | Secret Service (`secret-service` crate) + clear warning if unavailable |
| `AVAudioPlayer` | Web Audio API decode of bundled WAVs (no heavy multimedia stack) |
| AX / AppleScript window title | X11: `_NET_WM_*`; Wayland: document limits + optional GNOME/KDE portals |
| Status item menu | Tray icon (libappindicator / StatusNotifier) |
| Pollers + Anthropic API | TypeScript (platform-independent HTTP) |

## Repository layout

```
NotchBuddy/                 # macOS — unchanged
apps/linux/                 # Linux Tauri app
  src/                      # Frontend (island UI, bot, FSM, pollers)
  src-tauri/                # Rust: window, hooks, secrets, tray
  resources/nb-hook         # Claude Code relay (Python)
scripts/build-linux.sh      # AppImage + .deb
docs/linux.md               # User-facing Linux docs
docs/linux-architecture.md  # This file
```

## Platform abstractions (Rust + TS bridge)

- `WindowManager` — position, always-on-top, transparency, multi-monitor
- `DisplayService` — primary/active monitor, config-change events
- `SecretStorage` — Secret Service / fallback status
- `AudioService` — frontend Web Audio (WAV); optional native later
- `ClaudeHookService` — Unix socket + hook install/merge
- `ActiveWindowService` — best-effort title/app; Wayland limitations documented
- `NotificationService` — tray + optional desktop notifications

## Claude Code IPC (unchanged protocol)

- Line-delimited JSON over `AF_UNIX` / `SOCK_STREAM`
- Socket: `$XDG_DATA_HOME/coucou/nb.sock` (default `~/.local/share/coucou/nb.sock`)
- `PermissionRequest` holds FD until allow/deny/always (≤115s app / 118s hook)
- Other events: fire-and-forget, 0.3s timeout, never block Claude Code
- `~/.claude/settings.json` merge identical to macOS (backup + confirm)
- VS Code / Cursor detection: `term_program`, `TERM_PROGRAM`, Cursor env

## UI target

- Top-center floating island; transparent stage
- Modes: hidden / compact (+160w) / expanded (640 × view height)
- Springs: open `cubic-bezier(.32,1.22,.42,1)` ~0.52s; close 0.34s `cubic-bezier(.45,0,.2,1)`
- Mochi Canvas engine; greeting + upload sequences
- Avoid focus steal except chat `TextField` / prompt input

## Wayland / X11

- Prefer Wayland session (`XDG_SESSION_TYPE` / `WAYLAND_DISPLAY`)
- Transparent + always-on-top via wlr-layer-shell where available; otherwise compositor-dependent always-on-top
- Active window / attach-drag: full on X11; on Wayland use portal/extension when possible, else degrade with UI notice
- Never silently bypass Wayland security

## Licensing (packages)

Code: MIT. Branding/sounds/Mochi: see `LICENSE-ASSETS.md`.  
Release packages that redistribute Coucou assets need author permission; forks must rebrand for distribution.

## Phased delivery

1. Architecture (this doc)  
2. App shell + island UI  
3. Hooks + IPC  
4. Mochi animations  
5. Window/display  
6. Audio + secrets  
7. Wayland/X11 notes + fallbacks  
8. Packaging  
9. Test / fix  
10. `docs/linux.md` + README section  
