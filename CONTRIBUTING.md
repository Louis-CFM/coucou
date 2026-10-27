# Contributing to Coucou

Thanks for wanting to help Mochi grow up! 🫶

## Getting started

```bash
brew install xcodegen
cd NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
```

Never edit `NotchBuddy.xcodeproj` by hand: change `project.yml` and run `xcodegen`.

Check resting island dimensions on screens with and without a notch:

```bash
bash scripts/test-screen-geometry.sh
bash scripts/test-display-choice.sh
```

Check hook setup status:

```bash
bash scripts/test-hook-status.sh
```

Check local Codex IDE diagnostics and exact external-thread usage mapping:

```bash
bash scripts/test-codex-ide.sh
bash scripts/test-codex-thread-usage.sh
```

These checks use temporary fixtures; they do not sign in or run a model.

Check the desktop plugin, exported resources and the actual Mac question dispatch:

```bash
python3 scripts/test-codex-plugin.py
bash scripts/test-codex-plugin-export.sh
bash scripts/test-codex-plugin-mac.sh
```

These use subprocess/socketpair fixtures. Desktop plugin installation, live model
requests and UI acceptance remain separate manual checks.

Check the Codex assistant feature paths and owned-turn updates:

```sh
bash scripts/test-codex-text.sh
bash scripts/test-codex-flow-notes.sh
bash scripts/test-codex-voice.sh
bash scripts/test-codex-voice-actions.sh
bash scripts/test-codex-voice-controller.sh
bash scripts/test-codex-turn-state.sh
bash scripts/test-codex-parity.sh
```

These fixtures use fake credentials/models and in-memory boundaries. They check
isolated text requests, original-text/note preservation, the voice action allowlist,
stale/cancelled actions, plan progress and cumulative Mac diff reconciliation.
They do not validate a live ChatGPT account, voice hardware, Contacts, Music,
Desktop plugin trust or the UI. Keep those manual acceptance checks separate.


Check auto-close timing and live setting changes:

```bash
bash scripts/test-auto-close.sh
```

Check macOS translations:

```bash
python3 scripts/test-localization.py
```

Add English and Traditional Chinese entries for every new localized label. Keep
format arguments and plural paths intact. This check does not replace building
both Mac targets or checking the language and layout in the app.

## Good first contributions

- A new service integration (a poller + an entry in `PillCatalog.swift` in the `.service` category + a detail card). Look at `StripePoller.swift` for a compact example.
- A new agent: any agent already gets its own automatic pill by sending `coucou_agent` in its hook payload (see `docs/AGENTS.md`). Add an entry in `PillCatalog.swift` in the `.agent` or `.workspace` category only if you want it to be declarable in Settings → Active pills.
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
