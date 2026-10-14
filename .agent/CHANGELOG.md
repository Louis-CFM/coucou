# Coucou ZirconX Changelog

All notable changes, customizations, and enhancements developed by **ZirconX (ZXD44)** are documented in this file.

---

## [0.4.0-zirconx] - 2026-10-12

### Added
- **Full Thai (`th`) Language Support**:
  - Translated 747 localization keys across `strings.json` and `extra.json`.
  - Registered Thai locale in frontend (`windows/src/i18n/i18n.ts`) and backend (`windows/src-tauri/src/i18n.rs`).
- **Antigravity Auto-Connect**:
  - Added `ensure_antigravity_installed()` in `agents.rs`.
  - Wired automatic startup hook initialization in `lib.rs` to detect and link `~/.gemini/config/hooks.json`.
- **Antigravity (agy) Native Chat Provider**:
  - Integrated `agy` CLI into Coucou's Chat Model Picker (`windows/src/core/providers.ts`).
  - Added seamless background execution with `CREATE_NO_WINDOW` (no popup CMD windows).
  - Implemented continuous conversational memory preserving turn history and system prompt context.
- **One-Click Upstream Sync & Rebuild**:
  - Added `sync_and_update.bat` for one-click fetch, merge, build, and re-install on Windows.
- **Automated GitHub Workflow**:
  - Added `.github/workflows/sync-upstream.yml` for scheduled daily upstream sync.
- **Dedicated Agent Workspace**:
  - Created `.agent/` directory with `SYSTEM.md`, `rules/RULES.md`, and project guides.

### In Progress / Known Issues
- **Voice Wake Word ("เฮ้ คูกู" / "Coucou")**:
  - Web Speech API integration structure drafted in `windows/src/island/voice.ts`.
  - Microphone capture in Windows WebView2 currently pending native audio capture pipeline / hotkey audio daemon for full reliability. Scheduled for next session.
