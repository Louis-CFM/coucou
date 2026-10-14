# Instructions for AI Coding Agents (Coucou ZirconX)

When developing or modifying this repository, follow these guidelines:

1. **Always Maintain Thai Translations**:
   - Whenever editing or adding strings to UI components (`windows/src/views/`, `windows/src/settings/`, etc.), make sure corresponding Thai translations are registered in both `strings.json` and `extra.json`.
2. **Preserve Antigravity Hook Integration**:
   - Ensure `agents::ensure_antigravity_installed()` remains active during bootstrap in `windows/src-tauri/src/lib.rs`.
3. **Respect Upstream Merge Compatibility**:
   - Keep file changes surgical to minimize future merge conflicts when syncing with `Louis-CFM/coucou`.
4. **Build Verification**:
   - Always run `npx tsc --noEmit` before proposing commits.
