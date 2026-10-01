# Coucou — guide for AI coding agents

Read [AGENTS.md](AGENTS.md) first for the shared macOS/Windows contribution
guide, provider invariants and regression checks. This file retains the
original Claude-specific notes. Codex coding hooks are separate from API chat;
see [docs/CODEX.md](docs/CODEX.md).

Coucou is a native macOS app: Mochi, a small animated character living in the MacBook notch, shows Claude Code sessions and a few integrations, and lets the user approve, answer, chat and drop files from the notch.

## Where things are
- `NotchBuddy/Sources/App/` — all Swift code. `NotchBuddy/Resources/sounds/` — the 28 WAV sounds. `NotchBuddy/project.yml` — XcodeGen project (never edit the `.xcodeproj` by hand).
- `docs/SPEC.md`, `docs/INTEGRATIONS.md` — behaviour, views, states, integrations (in French).
- `design/prototype/notch-buddy.html` — original prototype, the visual source of truth. `design/captures/` — target screenshots.
- `docs/*.html` — the GitHub Pages site (privacy, terms, support, legal notice).

## Build
```
cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build
```

## Rules
- Swift 6, SwiftUI + AppKit. No third-party dependencies unless truly unavoidable. The character is drawn in code (`Canvas` + `TimelineView`), no Rive/Lottie/images.
- Secrets live in the Keychain, never on disk or in git.
- No telemetry. Network calls only to services the user configured.
- Never block Claude Code: if the app doesn't answer, the hook exits immediately.
- Never overwrite `~/.claude/settings.json`: dated backup, merge, show the diff, write only after the user confirms.
- Never send an email or approve a Claude Code permission without an explicit click.
- Performance: 0 % CPU when the island is hidden.
- Keep the bundle identifier `fr.louisraille.NotchBuddy` (Keychain items, preferences and permissions depend on it).
- Visual changes must match the prototype and the screenshots in `design/captures/`.
