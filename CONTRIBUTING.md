# Contributing to Coucou

Thanks for wanting to help Mochi grow up! 🫶

## Getting started

```bash
brew install xcodegen
cd NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
```

Never edit `NotchBuddy.xcodeproj` by hand: change `project.yml` and run `xcodegen`.

For Windows, see [windows/README.md](windows/README.md). Run the checks in
[AGENTS.md](AGENTS.md) for both affected provider/platform boundaries; report
native builds separately from frontend or fixture tests. The Codex provider
[analysis](docs/PROJECT_ANALYSIS.md) and [review guide](docs/CODEX_CONTRIBUTION.md)
describe the optional upstream contribution, not a rebranded product.

## Good first contributions

- A new integration (a poller + a pill + a detail card). Look at `StripePoller.swift` for a compact example.
- A new emote or sound for Mochi.
- Bug fixes — please describe how to reproduce.

## Rules of the house

- Swift 6, SwiftUI + AppKit, **no third-party dependencies** unless there's really no other way.
- Secrets go in the Keychain, never on disk or in git.
- No telemetry, no network calls except to services the user configured.
- Never block Claude Code: if the app doesn't answer, the hook must exit right away.
- Never write `~/.claude/settings.json` without a backup and the user's confirmation.
- Keep it light: 0 % CPU when the island is hidden.

## Pull requests

- One topic per PR, with a short GIF or screenshot for anything visual.
- Build must pass with no new warnings.
