# Coucou on Linux

Native-feeling Linux companion for Claude Code: a floating top-center island with Mochi, approvals, chat, and integrations. The macOS app under `NotchBuddy/` is unchanged; Linux lives in `apps/linux/` (Tauri 2 + TypeScript/Canvas).

Architecture notes: [linux-architecture.md](./linux-architecture.md).

## Requirements

### Runtime
- Modern Linux desktop (GNOME, KDE Plasma, or similar)
- Wayland **or** X11 (`XDG_SESSION_TYPE`)
- Python 3 (for `nb-hook`)
- Optional: Secret Service (GNOME Keyring / KWallet) for API keys
- Optional: `xdotool` / `xprop` on X11 for active-window attach context

### Build (Tauri)
- Rust stable (`rustup`)
- Node.js 20+ and npm
- System packages — one shot:

```bash
./scripts/install-linux-deps.sh
```

Or manually (Ubuntu / Debian):

```bash
sudo apt install -y \
  build-essential curl wget file pkg-config \
  libwebkit2gtk-4.1-dev libgtk-3-dev \
  libayatana-appindicator3-dev librsvg2-dev \
  patchelf libssl-dev libsecret-1-dev
```

Fedora / Arch: see [Tauri Linux prerequisites](https://tauri.app/start/prerequisites/).

### Desktop control (Shift+M)
Global shortcut **Shift+M** opens the ask panel. Examples:
- `افتح يوتيوب ابحث عن lo-fi`
- `غير الأغنية` / `next song`
- `حلل شنو موجود بالشاشه` (needs Anthropic API key in Settings for vision)
- `افتح chatgpt وقل له hello` ثم `اضغط enter`

Uses `xdg-open`, `xdotool`/`wtype`, `playerctl`, and `grim`/`import` for screenshots.

## Development

```bash
# UI + Claude hook socket (browser, no GTK headers required)
./scripts/dev-linux.sh

# Or manually:
cd apps/linux
npm install
npm run typecheck
npm run dev          # Vite on http://127.0.0.1:1420
# In another terminal (optional hooks):
node ../../scripts/linux-hook-dev-server.mjs
```

Useful logs (dev only, not spammy):
- Hook / socket: `[hook] SessionStart` from the Node bridge, or `coucou.log` under `$XDG_DATA_HOME/coucou/`
- Browser console: category loggers in `src/core/logger.ts`
- Simulate a session:  
  `window.__coucou.simulateHook({ hook_event_name: "SessionStart", session_id: "dev", cwd: "/tmp/demo", term_program: "cursor" })`

### Tauri window (needs system deps)

```bash
cd apps/linux
npm run tauri:dev
```

## Build / packaging

```bash
./scripts/install-linux-deps.sh   # once
./scripts/build-linux.sh
```

Produces artifacts under `dist/linux/`:
- `.deb` — `sudo dpkg -i dist/linux/*.deb`
- `.AppImage` — `chmod +x dist/linux/*.AppImage && ./dist/linux/*.AppImage`

Flatpak is not wired yet; the `apps/linux` layout is compatible with adding a Flatpak manifest later.

**Assets license:** Coucou name, Mochi, icons and sounds are **not** MIT — see [LICENSE-ASSETS.md](../LICENSE-ASSETS.md). Do not publish redistributable packages under the Coucou brand without permission; forks must rebrand for distribution.

## Claude Code integration

Same protocol as macOS:

| Item | Linux path |
|------|------------|
| Socket | `$XDG_DATA_HOME/coucou/nb.sock` (default `~/.local/share/coucou/nb.sock`) |
| Hook script | `~/.local/share/coucou/nb-hook` |
| Inbox | `~/.local/share/coucou/inbox/` |
| Log | `~/.local/share/coucou/coucou.log` |

- Line-delimited JSON over a Unix domain socket
- Non-permission events: fire-and-forget (0.3s); **never blocks Claude Code**
- `PermissionRequest`: holds until Allow / Always / Deny (app timeout ~115s)
- Settings UI merges into `~/.claude/settings.json` with a dated backup first
- Editor filter: VS Code **and** Cursor (`term_program` / env)

Override socket: `COUCOU_SOCK=/path/to/nb.sock`.

## Secrets

- Preferred: FreeDesktop **Secret Service** (GNOME Keyring, KDE Wallet)
- Fallback: `~/.local/share/coucou/secrets.json` mode `0600` (UI reports backend via `secrets_status`)
- Same account keys as macOS (`fr.louisraille.NotchBuddy` service name)

## Window / display behavior

- Transparent, always-on-top, skip-taskbar window (720×320 stage)
- Island top-centered on the current monitor; repositions when you call `position_island`
- Click-through outside the island via `set_ignore_cursor_events` when supported
- Modes: hidden (184×32) → compact (+160 width) → expanded (640 × view height)

### Wayland (first-class)

- Session detected via `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE=wayland`
- Transparent + always-on-top depend on the compositor (Mutter, KWin generally OK)
- **Active window / attach-drag:** often restricted. Coucou does **not** try to bypass Wayland security. Expect degraded window-title capture unless a portal/extension is available.
- Optional GNOME Shell introspection may be attempted; failure is reported clearly.

### X11

- Full-ish active window via `xdotool` / `xprop` when installed
- Click-through and always-on-top are generally reliable

### GNOME

- Prefer Wayland session on recent Ubuntu
- Install GNOME Keyring for Secret Service
- Tray / StatusNotifier may need AppIndicator extension on some versions

### KDE Plasma

- KWallet provides Secret Service
- KWin handles always-on-top well on both Wayland and X11

## Audio

WAVs are played with the **Web Audio API** inside the webview (no large multimedia stack). Sounds are loaded from `/sounds/*.wav` (symlinked from `NotchBuddy/Resources/sounds` in development).

## Permissions / privacy

- No telemetry
- Network only to services you configure (Anthropic, Stripe, …)
- Accessibility-style window reading is best-effort and session-dependent (see Wayland notes)

## Known limitations

| Feature | Status on Linux |
|---------|-----------------|
| Notch geometry | Replaced by floating top-center companion |
| Mail.app send | Not available (use your MUA / mailto) |
| AppleScript browser URL | Not available |
| Active window attach | X11 OK; Wayland limited |
| Launch at login | Use desktop autostart manually for now |
| Full integration pollers UI | Core Claude path + settings; pollers can be extended like macOS |

## OpenAI Codex (ChatGPT sign-in)

See **[docs/codex-linux.md](./codex-linux.md)** for Sign in with ChatGPT, device-code fallback, session reuse, and security.

Quick install of the official SDK used by Coucou:

```bash
cd apps/linux
uv venv .venv-codex
uv pip install --python .venv-codex/bin/python -r codex-bridge/requirements-codex.txt
```

Or use the Codex CLI alone: `npm i -g @openai/codex` then `codex login` — Coucou reuses that session when possible.

## Project layout

```
apps/linux/           Tauri + Vite frontend
  src/                Island UI, BotEngine, FSM, hooks client
  src-tauri/          Window, hooks socket, secrets, display, Codex bridge
  codex-bridge/       Official openai-codex Python sidecar
NotchBuddy/           macOS app (unchanged)
scripts/build-linux.sh
scripts/dev-linux.sh
scripts/linux-hook-dev-server.mjs
```
