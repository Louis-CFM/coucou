# Contributing to Orca Notch

## Getting started

```bash
brew install xcodegen
cd NotchBuddy && xcodegen && open NotchBuddy.xcodeproj
```

Never edit `NotchBuddy.xcodeproj` by hand: change `project.yml` and run `xcodegen`.

## Tests

Each test is a small Swift program compiled and run by its script:

```bash
for t in scripts/test-*.sh; do bash "$t"; done
```

## Pull requests

- Keep the notch fast: nothing should cost CPU while the island is hidden.
- Never block an agent: hooks must exit immediately when the app does not answer.
- No third-party dependencies and no upstream artwork or sounds (see `LICENSE-ASSETS.md`).
- Add a line to `CHANGELOG.md` for anything users can see.
