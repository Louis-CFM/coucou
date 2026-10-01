# Coucou — guide for AI coding agents

Coucou is a native macOS app: Mochi, a small animated character living in the MacBook notch, shows coding-agent sessions and a few integrations, and lets the user approve, answer, chat, and drop files from the notch.

This is the repository-wide source of truth for coding-agent instructions. `CLAUDE.md` points Claude Code here so shared rules are maintained in one place.

## Where things are

- `NotchBuddy/Sources/App/` — all Swift code. `NotchBuddy/Resources/sounds/` — the 28 WAV sounds. `NotchBuddy/project.yml` — the XcodeGen project definition.
- `NotchBuddy/Sources/App/AI/` — provider-neutral agent models, protocols, reducer, registry, and runtime manager.
- `NotchBuddy/Sources/App/Agents/<Runtime>/` — runtime-specific discovery, transport, protocol codec, and event translation. Keep native payload handling behind this boundary.
- `NotchBuddy/Sources/App/Providers/<Provider>/` — provider API adapters. Keep authentication and wire payloads behind this boundary.
- `NotchBuddy/Tests/` — Swift tests for normalized agent behavior and runtime translation.
- `windows/src/core/ai/`, `windows/src/agents/`, and `windows/tests/` — the corresponding provider-neutral contracts, adapters, and tests for the Windows implementation.
- `docs/SPEC.md`, `docs/INTEGRATIONS.md` — behavior, views, states, and integrations (in French).
- `design/prototype/notch-buddy.html` — the original prototype and visual source of truth. `design/captures/` — target screenshots.
- `docs/*.html` — the GitHub Pages site (privacy, terms, support, legal notice).

## Build and test

```sh
cd NotchBuddy
xcodegen
xcodebuild -scheme NotchBuddy -configuration Debug build
xcodebuild -scheme NotchBuddy -configuration Debug test
```

```sh
cd windows
npm test
npm run build
```

Edit `NotchBuddy/project.yml`, then regenerate the Xcode project with `xcodegen`. Never edit `NotchBuddy.xcodeproj` by hand.

## Rules

- Swift 6, SwiftUI + AppKit. No third-party dependencies unless truly unavoidable. The character is drawn in code (`Canvas` + `TimelineView`), with no Rive, Lottie, or image-based character rendering.
- Secrets live in the Keychain, never on disk or in git. Agent runtimes must use the user's existing CLI authentication; do not copy, log, or persist provider credentials or raw protocol streams.
- No telemetry. Network calls only go to services the user configured. Do not add analytics, background reporting, or silent provider fallbacks.
- Never block Claude Code when Coucou is unavailable: hook connection failures must return immediately. Permission requests may remain open only while Coucou is actively presenting the decision, and must fall back safely on timeout or disconnect.
- Never overwrite `~/.claude/settings.json`: create a dated backup, merge Coucou hooks with existing settings, show the resulting diff, and write only after the user explicitly confirms.
- Never send an email, approve a coding-agent permission, answer a coding-agent question, start a turn, or expand an approval's scope without an explicit user action.
- Treat provider output and tool payloads as untrusted. Decode them into the normalized domain, preserve runtime request IDs, validate them against the selected session, and render them as text rather than executable content.
- Keep the normalized domain provider-neutral. Add runtime-specific behavior in `Agents/<Runtime>/`; do not scrape private databases or logs when an official runtime protocol is available.
- Discover models and reasoning options from the runtime. Do not hard-code a provider model catalog.
- Performance: 0% CPU when the island is hidden. Event readers may wait on blocking I/O, but hidden-state code must not busy-poll and animation timers must stop when their view disappears.
- Keep the primary bundle identifier `fr.louisraille.NotchBuddy`; Keychain items, preferences, and permissions depend on it.
- Visual changes must extend the component language, spacing, typography, colors, and layouts of the prototype and the screenshots in `design/captures/`.

## Change discipline

- Preserve behavior for existing Claude Code hooks while extending the normalized agent layer.
- Add or update focused tests for protocol translation, state reduction, approvals, and user-input routing.
- Do not commit generated audits, agent transcripts, private planning notes, local credentials, or machine-specific files. Product and architecture documentation belongs in the existing project docs when it is part of the product; personal working notes stay outside the repository.
- Before claiming completion, run the relevant build and tests plus `git diff --check`. Do not commit, push, publish, or create a pull request unless the user explicitly asks.
