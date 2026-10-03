# OpenCode support — manual test checklist

The Swift side of this feature was syntax-checked only during development
(`swiftc -parse`; no Xcode in the dev environment). Run this checklist on a Mac
with Xcode, using the **GitHub build** of Coucou. The OpenCode plugin side was
tested live against OpenCode `v2.0.18` during development.

Work order matters: build first, then installer, then raw socket, then live
OpenCode.

## 1. Build (Xcode)

- [ ] Build the `NotchBuddy` target (GitHub build configuration) — zero errors.
  This is the first full type-check of `HookServer.swift`, `PillCatalog.swift`
  and `SettingsView.swift` changes.

## 2. Installer cycle — Settings → OpenCode Hooks

- [ ] Click **Install hooks** → a JSON diff appears showing only a `plugins`
      array being added to `~/.config/opencode/opencode.json`. All other keys
      (`$schema`, `mcp`, `plugin`, `lsp`, `agent`, `providers`, `websearch`)
      are untouched.
- [ ] Click **Confirm & write** → status "✓ OpenCode plugin installed — restart
      OpenCode to load it."
- [ ] `~/.config/opencode/plugins/coucou/index.mjs` exists and matches
      `opencode-coucou/dist/index.mjs`.
- [ ] `~/.config/opencode/opencode.json` now contains
      `"plugins": ["…/plugins/coucou/index.mjs"]` and a config backup file was
      created next to it.
- [ ] Row status flips to "Plugin installed — restart OpenCode to load it";
      the `agent_opencode` pill row in Settings no longer says "Hooks not
      installed".
- [ ] Run **Install hooks** again → diff shows the same single `plugins` entry
      (idempotent — no duplicate).
- [ ] Preview an install, edit `~/.config/opencode/opencode.json` by hand, then
      confirm → error "…changed since preview. Refresh and try again." and
      nothing is written.
- [ ] **Uninstall** → diff shows the `plugins` entry removed (key dropped if it
      became empty); confirm → plugin dir removed, all other config keys
      intact, status "✓ OpenCode plugin removed."
- [ ] **Uninstall** when nothing is installed → status
      "No OpenCode plugin to remove.", no diff.

## 3. Raw socket routing (no OpenCode needed)

With Coucou (GitHub build) running:

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"oc-t1","prompt":"hello","coucou_agent":"opencode"}' \
  | nc -U ~/Library/Application\ Support/NotchBuddy/nb.sock
```

- [ ] The OpenCode pill (green `#10B981` accent) appears in the island, state
      → thinking, "hello" in the ticker.
- [ ] Follow with `{"hook_event_name":"PreToolUse","session_id":"oc-t1","tool_name":"bash","coucou_agent":"opencode"}`
      → state → working, "bash" shown in the ticker.
- [ ] Send a `PermissionRequest` payload with `coucou_agent:"opencode"`
      (same shape Codex uses) → an approval card with **Allow / Always / Deny**
      appears on the OpenCode pill; each button writes a
      `{"permissionDecision":"…"}` line back to the connection.

## 4. Plugin lifecycle (live OpenCode)

With the plugin installed (Step 2) and Coucou running:

- [ ] Start OpenCode in a project directory and send a prompt → pill appears,
      thinking state.
- [ ] Have it use tools (read, edit, bash…) → working state, tool labels rotate
      in the ticker.
- [ ] Session goes idle → pill resets to idle (it is a declared pill, it
      stays visible).
- [ ] OpenCode's own output contains no `[coucou]` errors.

## 5. Approval round-trip (live OpenCode)

- [ ] In OpenCode, trigger a permission prompt (e.g. ask it to run a command
      that requires approval).
- [ ] Notch shows the approval card on the OpenCode pill while OpenCode's
      terminal waits.
- [ ] **Allow** → the tool runs once; the next matching prompt asks again.
- [ ] **Always** → subsequent matching prompts are auto-approved.
- [ ] **Deny** → OpenCode reports the rejection in the terminal.
- [ ] Leave a card unanswered for ~110 s → OpenCode falls back to asking in its
      terminal (fail-soft, nothing hangs).

## 6. Fail-soft

- [ ] Quit Coucou, then run OpenCode → OpenCode starts and works normally; its
      output shows one `[coucou] cannot reach …/nb.sock … plugin inactive`
      line and nothing is blocked.
- [ ] Start Coucou, restart the OpenCode session → pill works again (no
      mid-session reconnect by design).

## Known limitations (informational, by design)

- No socket reconnect if Coucou exits mid-session — restart the OpenCode
  session.
- The `question` tool renders its bare label in the ticker (no question text).
- The App Store build does not include OpenCode support (all of it is
  `#if !APPSTORE`); the plugin no-ops against the App Store socket path.
