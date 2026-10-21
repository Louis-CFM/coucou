# Changelog

## Unreleased — fork of Coucou, stripped and rebranded as Orca Notch

Orca Notch starts from [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) at the merge of pull request #831 (`1e51809`). The history before that point lives upstream.

### Added

- Orca data in the island: the closed island shows three agent counters (spinner running, check-circle finished today, bell needs you), only the non-zero ones, and stays out of the way when everything is idle. The open island lists the workspaces flat, most urgent first, with state, repo, branch, PR, agents and time since activity, plus a usage footer per provider. Live data comes from `orca worktree ps` polled every 2.5 s while the island is visible and every 15 s when hidden or asleep (`docs/orca-polling.md`).

### Changed

- The home view and the compact grid no longer show Claude Code session pills or the Claude/Codex plan pill; they show the Orca view instead.

### Removed

- Platforms: the Android app, the Windows and Linux (Tauri) app, the relay Worker, the iPhone app with its widgets, notification extension and phone link, the Homebrew cask, the GitHub Pages site and the README media.
- Features: Flow dictation and Parakeet, the Notetaker, crypto and portfolio, mail, Apple Music and Spotify, the Stripe, n8n, Notion, Resend, Cal.com and Vercel pollers, OK Coucou voice control, WhatsApp, chat providers other than Claude, the weekly recap, desktop mascot, wardrobe and outfits, greeting animation, machine vitals, screen capture, the in-app updater, demo mode, the Settings language picker and the App Store variant.
- All upstream artwork: the character, the app and menu bar icons and the 28 sounds.

### Kept

The notch island window and its state machine, display choice, hover and hide-when-idle behavior, the pill infrastructure, approvals and `AskUserQuestion` cards, terminal jump, global hotkeys, the Settings window, the hook server and its relay, the Claude chat, plan usage and the GitHub pulse.

### Changed

- Name **Orca Notch**, bundle identifier `dev.hfps.orca-notch`, support folder `~/Library/Application Support/OrcaNotch`, logs in `~/Library/Logs/OrcaNotch`.
- Hook payload fields renamed from `coucou_*` to `orca_notch_*`; generated agent plugins and config files are named `orca-notch`.
- The mascot is a placeholder whale drawn with `Canvas` (`NotchKit/Mascot.swift`), the icons come from `scripts/make-icons.swift`, and sounds are macOS system sounds (`SoundEngine.swift`).
- Single XcodeGen target, no third-party dependencies (FluidAudio removed).
