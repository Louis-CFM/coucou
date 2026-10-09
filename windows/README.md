# NOVA — Phase 1 candidate

Windows 11 x64 desktop island fork. This candidate rebrands the existing island;
it does **not** yet implement the managed agent engine, new safety modes, widgets,
or the remaining phases of the project brief. Existing direct model chat remains.

## Build on Windows

Node.js 24/npm, Rust via rustup, Visual Studio Build Tools 2022 with Desktop
Development with C++, and the Microsoft Edge WebView2 runtime are required.
No additional global package manager is required. NSIS is handled by Tauri.

```powershell
cd windows
npm ci
npm run icons
npm test
npm run pack
```

Installer: `windows/release/Nova-Windows-setup.exe`.
Portable: keep `nova.exe` and `nova-hook.exe` side by side; WebView2 is required.
Portable means no installer, not zero prerequisite software or zero local data.
Settings are in `%APPDATA%\Nova`; relay/log data in `%LOCALAPPDATA%\Nova`.
Old application credentials/settings are not silently imported.

Unsigned builds may show SmartScreen. Only if you trust the build and its source,
select **More info → Run anyway**. Do not bypass antivirus detections blindly.

## Phase 1 manual acceptance (not yet verified)

1. Launch on Windows 11: no console or taskbar entry; tray and island appear.
2. Hover/click, expand/collapse, blink, drag and sleep behaviour remain intact.
3. Verify the teal chamfered mascot and replacement tray/installer icons.
4. Open Settings and model chat; verify provider switching still works.
5. Install hooks only after reviewing the displayed config diff; verify activity,
   file diffs and Claude approval behaviour. Existing terminal fallback remains.
6. Quit and reopen; verify preferences use the Nova directories.
7. Test the installer and portable pair separately, including high-DPI displays.

MIT source attribution is preserved in LICENSE. Restricted upstream media/sounds
are not included. The replacement changes geometry/palette, not tuned motion.
