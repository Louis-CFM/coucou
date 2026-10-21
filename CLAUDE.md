# Orca Notch — guide for AI coding agents

Orca Notch is a native, Mac-only notch app (`NotchBuddy/`). A small placeholder mascot lives in the MacBook notch, shows AI coding agent sessions (Claude Code, Gemini CLI, Antigravity and more) and lets the user approve, answer, chat and drop files from the notch. It is a fork of [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) (MIT), stripped down and rebranded; it is meant to become the notch companion of Orca, the agent workspace manager.

## Where things are
- `NotchBuddy/Sources/App/` — Mac-only Swift code (island window, state machine, hook server, settings, chat). `NotchBuddy/Sources/NotchKit/` — shared model code: the mascot (`Mascot.swift`), pills, diff, island types and geometry.
- `NotchBuddy/Sources/OrcaKit/` — Orca data sources (added by a separate change; new files only).
- `NotchBuddy/Sources/NotchKit/PillCatalog.swift` — single source of truth for all declared pills (workspace tools, agents, the Claude chat, services). Every pill ID, color, category and subtitle lives here.
- `NotchBuddy/project.yml` — XcodeGen project (never edit the `.xcodeproj` by hand). One target, `NotchBuddy`, product "Orca Notch".
- `tests/` + `scripts/test-*.sh` — plain Swift test programs, each compiled and run by its script.
- `scripts/make-icons.swift` — generates the placeholder app and menu bar icons.
- `LICENSE-ASSETS.md` — the upstream name, character, icon and sounds are not free to reuse and are not in this repo.

## Build
```
cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build
```
To run it day to day: `./scripts/dev-install.sh` (installs the only copy in `~/Applications`).
Tests: `for t in scripts/test-*.sh; do bash "$t"; done`

## Rules
- Swift 6, SwiftUI + AppKit. No third-party dependencies unless truly unavoidable. The mascot is drawn in code (`Canvas` + `TimelineView`), no image or animation assets, and no upstream artwork or sounds.
- Bundle identifier is `dev.hfps.orca-notch`; the support folder is `~/Library/Application Support/OrcaNotch` (socket, hook relay, inbox). The old `fr.louisraille.NotchBuddy` identifier no longer applies to this fork.
- Secrets live in the Keychain, never on disk or in git.
- No telemetry. Network calls only to services the user configured.
- Never block Claude Code: if the app doesn't answer, the hook exits immediately.
- Never overwrite `~/.claude/settings.json`: dated backup, merge, show the diff, write only after the user confirms.
- Never approve a Claude Code or Codex permission without an explicit click.
- Performance: 0 % CPU when the island is hidden.
- Pill IDs are stable contract values (Keychain, UserDefaults, hook routing): never rename an existing pill ID.
- Never restyle existing views (pills, cards, Settings, chat…) unless asked. New views follow the existing style.
- Hook payload fields are `orca_notch_agent`, `orca_notch_kind` and `orca_notch_has_transport`.
- Every change that users can see adds an entry to CHANGELOG.md.
