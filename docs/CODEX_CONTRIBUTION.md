# Upstream contribution proposal / PR draft

## Suggested title

Add optional Codex coding-agent hooks alongside Claude Code

## Maintainer proposal

I'd like to contribute Codex session monitoring and approvals to Coucou while
keeping Claude Code as default and retaining the existing companion UI. This
is an upstream extension, not a separately branded fork or cloud-agent product.

It reuses native relay/IPC, adds provider identity, isolated hook setup,
provider-bound approval cleanup and regression tests. Chat, integrations,
assets and release destinations remain intact.

Would you prefer a single provider-support PR or this review stack?

1. Provider state/approval ownership with Claude compatibility tests.
2. Windows Codex relay, installer and optional settings/pill with native tests.
3. Mac relay, installer/settings and both native build gates.
4. Docs and regression CI (tests can accompany each earlier PR).

The current branch contains the complete candidate. This is a proposed review
split, not a claim that separate PRs have been submitted.

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
- [ ] Maintainer review of version support, UI and PR split.

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
