# NOVA — Windows assistant fork

Windows 11 x64 desktop island built on an existing Tauri 2/Rust + TypeScript/Vite app. The UI is a face for the bundled OpenCode 1.18.35 engine; OpenCode owns the tool loop, sessions, tool permissions and context handling.

## Current verified baseline

- Tall, scrollable chat, light/dark themes, hide/reopen and explicit Quit.
- Managed native engine, provider profiles, endpoint-bound keys in Windows Credential Manager.
- File/photo attachments, local searchable conversation cache and real-session resume.
- Fresh approval for commands/edits, 60-second expiry and owned process-tree stop.
- Original NOVA white/orange mascot artwork and generated icons; tuned motion is preserved.

Clock/weather widgets, advanced engine affordances and final hardening are being completed in the remaining phases. Do not interpret this baseline as certification of all original-brief requirements.

## Build on Windows

Node.js 24/npm, Rust via rustup, Visual Studio Build Tools 2022 (Desktop development with C++) and Microsoft Edge WebView2. No extra global package manager is required; NSIS is handled by Tauri.

```powershell
cd windows
npm ci
npm run engine
npm run icons
npm test
npm run pack
```

Installer: `windows/release/Nova-Windows-setup.exe`. Portable must include `nova.exe`, `nova-hook.exe` and the complete `engine/` folder. See `windows/ASSISTANT-QUICKSTART.md` for setup, privacy and desktop acceptance steps.

CI checks frontend regressions, the real Windows engine against two local mock providers, file/shell approval and denial, child-process cleanup, packaging and an 8-second launch smoke test. Your paid provider/key, real desktop hover/DPI and hour-long widget behavior require separate acceptance checks; these are not claimed tested by a Linux preview.

MIT attribution remains in LICENSE. Replacement artwork/provenance is documented in LICENSE-ASSETS.md. Unsigned builds can show SmartScreen; review the source and scan downloads before deciding to run them.
