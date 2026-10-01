<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Coucou icon">

# Coucou for Windows

**Mochi doesn't get a notch on a PC — so it lives at the top of your screen instead.**

Approve Claude Code permissions, watch your session work, drop a file, chat with Claude, keep an eye on your services — without leaving what you're doing.

![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4?logo=windows)
![Tauri 2](https://img.shields.io/badge/Tauri-2-FFC131?logo=tauri&logoColor=black)
![Rust](https://img.shields.io/badge/Rust-backend-000?logo=rust)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

<img src="screenshots/greeting.png" width="640" alt="Mochi waving hello at launch">

> **Linux too.** The same sources build a Linux app (AppImage, .rpm, .deb),
> made with Bazzite in mind. See [Linux](#linux-bazzite-fedora-and-others).

---

## Install

The downloadable installer is **temporarily unavailable**. Microsoft Defender
wrongly flags the unsigned installer as malware (`Trojan:Win32/Wacatac.H!ml`, a
machine-learning false positive). A report is under review at Microsoft, and the
installer will be published again once it is cleared and code-signed.

Until then, [build it yourself](#build-it-yourself): it takes a few minutes and
installs for the current user only — no admin prompt.

## Using it

<img src="screenshots/compact.png" width="292" alt="The compact island, with the integration pills as mini Mochis">
<img src="screenshots/overview.png" width="640" alt="The overview: the focused integration on the left, the other pills on the right">
<img src="screenshots/approval.png" width="640" alt="A Claude Code permission request, with Deny and Allow">
<img src="screenshots/chat.png" width="640" alt="Chatting with Claude from the island">
<img src="screenshots/drop.png" width="640" alt="Mochi turned into a box, waiting for a file">

| What you do | What happens |
|---|---|
| Move the mouse to the very top-centre of the screen | Mochi peeks out |
| Click the small island | It opens |
| Click Mochi | It gets annoyed. Three times in a row and it goes dizzy |
| Rest the pointer on Mochi for two seconds | Hearts |
| Drag a file onto the island | Mochi turns into a box, swallows it, then offers to answer questions about it |
| `Esc` | Closes the island |
| Tray icon | Open, Settings…, Pause, Quit |

Everything else happens on its own: a Claude Code permission request opens the
island with **Deny / Allow**, a finished session shows what it did, and
your integrations sit in the coloured pills next to Mochi.

## Claude Code

<img src="screenshots/settings.png" width="562" alt="The settings window">

Open **Settings… → Claude Code → Install hooks…**. You get the exact diff of what
will change in `%USERPROFILE%\.claude\settings.json`, the path of the dated backup
that will be taken, and nothing is written until you click. Your own hooks are
never touched, and uninstalling removes only Coucou's entries.

The relay is a tiny executable, `coucou-hook.exe`, copied to
`%LOCALAPPDATA%\Coucou\bin\` at launch. It is given 300 ms to reach Coucou and
exits cleanly if the app is closed, slow or crashed — **a Claude Code session is
never blocked or slowed down by Coucou.** If nobody answers a permission request
in time, Coucou stays quiet and Claude Code asks in the terminal as usual.

It works from any terminal — Windows Terminal, PowerShell, VS Code, Git Bash.

## Chat and keys

**Settings… → Claude** takes your Anthropic API key. Keys live in the **Windows
Credential Manager**, never on disk and never in the interface — the island can
only ask whether a key exists. Same for every integration key.

No telemetry. The only network requests Coucou makes are to the services you
configure yourself.

## Build it yourself

You need [Rust](https://rustup.rs), [Node 20+](https://nodejs.org), and the
**MSVC build tools** (Visual Studio Build Tools with "Desktop development with
C++"). WebView2 ships with Windows 10/11.

```powershell
cd windows
npm install
npm run tauri dev      # live-reloading development build
npm run pack           # builds the installer and drops it in windows/release/
```

`npm run dev` alone serves the front end in an ordinary browser, which is enough
to work on the island's looks. It also serves `dev/upload-preview.html`, which
replays the whole file-drop choreography on a loop — the one part of the UI that
otherwise needs a real drag from Explorer to see. Neither page ships in the app.

`npm run pack` leaves two files in `windows/release/`, the same names the release
workflow publishes:

```
Coucou-Windows-X.Y.Z-setup.exe    the versioned installer
Coucou-Windows-setup.exe          the same file under the rolling name
```

Installing is optional — `target/release/coucou.exe` runs on its own. There is no
window in the taskbar and no console: the island at the top of the screen and the
Mochi in the notification area are the whole app, and Quit lives in its menu.

The 28 sounds are the macOS app's own files; they are never duplicated in this
folder. The path is declared once, in `SOUNDS_DIR` at the top of
`vite.config.ts` — when they move to `shared/sounds/`, change that one line.

The app icon and the tray icon are drawn in code, like Mochi itself:

```powershell
npm run icons          # regenerates src-tauri/icons from scripts/gen-icons.mjs
```

### Layout

```
windows/
  src/                 island front end (TypeScript, no framework)
    mochi/             Mochi and the launch greeting, in Canvas 2D
    island/            state machine, hooks, integrations
    views/             every island view
    settings/          the settings window
  src-tauri/           Rust backend: window, pipe/socket, chat, pollers
  hook/                coucou-hook(.exe), the hook relay
  scripts/             icon generator
```

### Log

`%LOCALAPPDATA%\Coucou\coucou.log` — hook events, permission decisions, poller
problems. It stays on your machine.

## Linux (Bazzite, Fedora and others)

The same code runs on Linux; only the parts that touch the OS change:

| | Windows | Linux |
|---|---|---|
| Relay | named pipe `\\.\pipe\coucou-<sid>` | Unix socket `$XDG_RUNTIME_DIR/coucou.sock` (mode 0600, same-user check) |
| `coucou-hook` | `%LOCALAPPDATA%\Coucou\bin\` | `~/.local/share/coucou/bin/` |
| Keys | Windows Credential Manager | Secret Service — KWallet on KDE, GNOME Keyring on GNOME |
| Settings | `%APPDATA%\Coucou\settings.json` | `~/.config/coucou/settings.json` |
| Log | `%LOCALAPPDATA%\Coucou\coucou.log` | `~/.local/share/coucou/coucou.log` |
| Packages | NSIS installer | AppImage, .rpm, .deb |

### Install on Bazzite

Bazzite is an image-based Fedora, so the AppImage is the easy way in:

1. Get `Coucou-Linux-x86_64.AppImage` — from the repo's **Actions → Linux → Run
   workflow** (the packages are attached to the run), from a `linux-v*` release, or
   [build it yourself](#build-it-on-bazzite).
2. `chmod +x Coucou-Linux-x86_64.AppImage && ./Coucou-Linux-x86_64.AppImage`
   (or open it with an AppImage manager such as Gear Lever, from Flathub, to add
   it to the menu).
3. Tray icon → **Settings… → Install hooks…**, exactly as on Windows.

The .rpm works too (`rpm-ostree install ./Coucou-Linux-*.rpm`, then reboot), but
layering packages on Bazzite is best kept for things that need it.

### Build it on Bazzite

Build inside a Fedora distrobox, so nothing is layered onto the host:

```bash
distrobox create --name coucou-build --image registry.fedoraproject.org/fedora-toolbox:latest
distrobox enter coucou-build

sudo dnf install -y webkit2gtk4.1-devel gtk3-devel libappindicator-gtk3-devel \
  librsvg2-devel openssl-devel patchelf nodejs npm gcc
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env

cd coucou/windows      # your clone of this repo
npm install
# A container has no FUSE for linuxdeploy, and its `strip` is older than
# Fedora's libraries: these two keep the AppImage step happy.
export APPIMAGE_EXTRACT_AND_RUN=1 NO_STRIP=1
npm run pack           # → release/Coucou-Linux-X.Y.Z-x86_64.AppImage, .rpm, .deb
```

Then run the AppImage from the host as above. `npm run tauri dev` works inside the
box as well, for live-reloading development.

On Debian/Ubuntu the packages are `libwebkit2gtk-4.1-dev libgtk-3-dev
libayatana-appindicator3-dev librsvg2-dev patchelf`.

### What's different on Linux

- **XWayland.** Wayland lets no ordinary window place itself, stay on top or
  skip the taskbar, and the island needs all three. On a Wayland session (the
  default on Bazzite, KDE and GNOME alike) Coucou therefore runs through XWayland,
  which every Bazzite desktop includes. Set `COUCOU_NATIVE_WAYLAND=1` to stay on
  native Wayland anyway — the island then goes wherever the compositor puts it —
  and a `GDK_BACKEND` you set yourself always wins. On a HiDPI screen, if the
  island looks too small, start it with `GDK_SCALE=2`.
- **Mochi's eyes follow the mouse only over the island.** Wayland tells no app
  where the pointer is over other windows. Hovering, clicking and the wake-up
  strip at the top of the screen work as usual.
- **Click-through** comes from an input region shaped like the island, so clicks
  next to it reach the window underneath.
- **Files** have to be dropped onto the island itself.
- **NVIDIA.** On Bazzite's `-nvidia` images Coucou sets
  `WEBKIT_DISABLE_DMABUF_RENDERER=1` for itself, which avoids WebKitGTK's blank
  windows on that driver.
- **Tray.** KDE shows it out of the box; GNOME needs the AppIndicator extension.
  Without a tray Coucou still runs, and the island's own ⚙ view has a
  **Settings…** button.
- "Open terminal" opens the folder in VS Code (or VSCodium) when `code` is on
  `PATH`, and in the file manager otherwise.

## What's different from the Mac version

- No notch, so the island lives at the top centre of the screen and retracts into
  the top edge instead of hiding in a notch.
- Permission approval works from **any** terminal; the Mac build only listens to
  VS Code sessions.
- Not in this version: sending a file by email, dragging Mochi onto a window to
  attach it as context, and jumping to a specific terminal window — "Open
  terminal" opens the working folder in VS Code when `code` is on your `PATH`.
- Cal.com shows the next bookings as a list rather than the Mac's calendar.
