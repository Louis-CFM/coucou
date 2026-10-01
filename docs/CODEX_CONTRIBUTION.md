# Codex provider upstream contribution

## Contribution scope

Add optional Codex session monitoring and explicit approvals alongside Claude
Code on Windows and macOS. Claude remains the default, and the built-in
Anthropic API chat is unchanged. This contribution extends the existing local
companion; it does not add a cloud agent, chat backend or separate product.

It reuses native relay/IPC, adds provider identity, isolated hook setup,
provider-bound approval cleanup and regression tests. Chat, integrations,
assets and release destinations remain intact.

## Suggested review order

1. Provider state/approval ownership with Claude compatibility tests.
2. Windows Codex relay, installer and optional settings/pill with native tests.
3. Mac relay, installer/settings and both native build gates.
4. Docs and regression CI (tests can accompany each earlier PR).

These are review areas within one provider-support contribution, not separate
pull requests. The contribution is based on upstream
`835421c7fff260f0f0be48927591b96bfad81cad` and preserves its latest relay fixes
and Windows-download pause.

## Validation evidence

Local checks pass: 13 Windows state/handler tests, 8 native Rust relay tests,
15 native release-library tests, 6 real Windows relay-process tests and 10
embedded Mac relay/shell-wrapper tests. TypeScript typecheck, frontend build,
Rust workspace source check and release relay build also pass.

Local native Windows checks use the portable GNU toolchain, not MSVC. Native
MSVC/NSIS and Xcode build results, clean installed-app smoke tests and UI dogfood
must be recorded separately. See [Windows readiness](WINDOWS_CODEX_READINESS.md)
for the public-release acceptance matrix. Passing fixtures is not an installed
binary release certification.

## Checklist

- [x] Claude defaults/legacy routing preserved; Codex is optional.
- [x] Coding providers do not consume service-integration slots.
- [x] Separate reviewed setup/removal with byte backup and stale detection.
- [x] Foreign handlers preserved, including shared matcher groups.
- [x] Provider-correct explicit decisions; timeout never means deny.
- [x] State/relay/installer tests use disposable fixtures.
- [x] No native Mac dependency, chat SDK, telemetry or rebranding added.
- [x] Local frontend and embedded-relay checks executed.
- [ ] Record Mac native builds and Windows MSVC CI results.
- [ ] Record release packaging before claiming release readiness.
- [ ] Attach native UI capture and lifecycle/approval dogfood evidence.
- [ ] Maintainer review of provider protocol, version support and UI integration.

## Result-reporting template

```text
Baseline revision:
Provider/state fields changed:
Executed commands, exit codes and literal summaries:
Native checks not executed:
Dogfood client/version and hook trust/setup:
Claude-default compatibility:
Approval/timeout/closed-app behavior:
Uninstall + foreign hooks:
UI evidence and idle CPU:
```

See [analysis](PROJECT_ANALYSIS.md), [setup/protocol](CODEX.md) and `AGENTS.md`.
Ignored `_prive/` baseline copies, toolchains and rollback packages are excluded
from the public contribution.
