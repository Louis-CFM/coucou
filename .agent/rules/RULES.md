---
trigger: always_on
---

# Project Guidelines & Rules (Coucou ZirconX)

## 1. Identity & Authorship
- **Author**: ZXD44 (`gonhackergamer0@gmail.com`)
- **Project**: Coucou (Thai Edition & Antigravity Enhanced)
- **Repository**: [https://github.com/ZXD44/coucou](https://github.com/ZXD44/coucou)
- **Upstream Repository**: [https://github.com/Louis-CFM/coucou](https://github.com/Louis-CFM/coucou)

## 2. Localization Standards
- All newly added user-facing strings must include Thai (`th`) translation entries in `windows/src/i18n/strings.json` and `windows/src/i18n/extra.json`.
- Keep placeholder variables intact (e.g. `{name}`, `{seconds}`, `{count}`).
- For plural forms, ensure both single and plural mapping rules are covered.

## 3. Code Integrity & Safety
- **No Telemetry**: Coucou never transmits user telemetries or private codebase information.
- **Safety**: Do not overwrite configuration files without safe checks or backup fallbacks.
- **Agent Interactivity**: Never block agent operations unnecessarily.
- **Build Verification**: Always verify TypeScript compilation (`npx tsc --noEmit`) before committing.

## 4. Git & Branching
- `main`: Tracks the personal main release with custom features (Thai, Antigravity integration, automation).
- `feat/*`: Topic branches for specific features or Pull Requests to upstream.
- Commits must use descriptive semantic prefixes: `feat:`, `fix:`, `chore:`, `docs:`, `i18n:`.
