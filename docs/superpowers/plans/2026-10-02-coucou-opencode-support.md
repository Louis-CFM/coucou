# Coucou — OpenCode Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenCode V2 as a first-class agent in Coucou — a live `agent_opencode` pill, tool steps, sounds, and Allow/Always/Deny approval cards — via an in-process OpenCode plugin that pushes events to Coucou's socket.

**Architecture:** Two components. (1) An OpenCode plugin (`opencode-coucou`) runs inside the OpenCode server, connects to Coucou's Unix socket, subscribes to the server event stream, and forwards canonical Coucou events tagged `coucou_agent:"opencode"`; it also relays approval decisions back via `ctx.permission.reply`. (2) Coucou (Swift) treats `coucou_agent == "opencode"` as a first-class agent (like Codex), adds an `agent_opencode` pill, shows an approval card, and gets a Settings "OpenCode" installer that writes the plugin into OpenCode's config.

**Tech Stack:** TypeScript (OpenCode plugin), Swift 6 / SwiftUI (Coucou macOS), newline-delimited JSON over a Unix socket.

**Spec:** `docs/superpowers/specs/2026-10-02-coucou-opencode-design.md`

## Global Constraints

- **Platform:** macOS (GitHub build) only. All OpenCode routing/installer code is wrapped in `#if !APPSTORE` so the App Store build is unaffected.
- **Agent tag:** `coucou_agent` value is exactly `"opencode"`. It must pass `Self.validateAgent` (lowercase `a-z`, digits, `-`, 1–24 chars) but is intercepted *before* that branch, exactly like `"codex"`.
- **Never block OpenCode:** if the Coucou socket connect fails, the plugin no-ops (mirrors the `nb-hook` "if Coucou isn't running, exit immediately" rule). A plugin mapping miss logs and is dropped (fail soft), never crashes OpenCode.
- **Socket protocol:** newline-terminated JSON, identical to `nb-hook`. Coucou replies on the held connection with `{"permissionDecision":"..."}`. GitHub-build socket path: `~/Library/Application Support/NotchBuddy/nb.sock`.
- **Approval semantics:** Coucou button → `ctx.permission.reply`: Allow→`once`, Always→`always`, Deny→`reject`.
- **Config field:** merge the plugin into OpenCode config using the V2 field `plugins` (user-ruled, confirmed 2026-10-03: "Use plugins (plural)"). Preserve all unrelated keys. Note (confirmed against the live v2.0.18 runtime): the runtime reads the singular `plugin` field (the user's working superpowers/ponytail entries live there), so the `plugins` entry is the docs-exact/ruleed marker. The plugin is ACTUALLY loaded via **auto-discovery** from `~/.config/opencode/plugins/` (the V2-documented local-plugin mechanism), which is the functional guarantee. A module-level idempotency guard in the plugin makes a double initialisation (auto-discover + config path) a harmless no-op.
- **Plugin artifact:** the installer ships a single self-contained `opencode-coucou/dist/index.mjs` (bundled via `bun build`, committed at `opencode-coucou/dist/index.mjs`). The installer embeds its content as a Swift **raw** `#""" ... """#` string constant (`opencodePluginSource`) — the bundle has zero `#` characters (verified), and backticks/`${}` template literals are literal in a Swift raw string, so no escaping is needed.
- **Plugin module resolution (open item #3):** a local plugin dir needs an `index.ts` (loaded as a plugin package directory under `~/.config/opencode/plugins/coucou/`). Use the **V2 plugin API** (user-ruled): `export default { id, setup(ctx) }` with `ctx.event.subscribe`, `ctx.permission.list/reply` — matching the bundled `ponytail` plugin, avoiding a `@opencode/plugin` package-resolution dependency.
- **Event mapping isolated in one file** (`src/mapping.ts`) so an OpenCode event-shape change touches only that file.
- **Accent colour:** `#10B981` (user-ruled; distinct from Codex `#2DD4BF`).

## Review Focus

The failure modes below are not exercised by any single task's tests but are the most likely to bite a user. Each is pinned to a task below.

- **Coucou not running when OpenCode starts.** The plugin's socket connect must no-op silently, never throw, never block OpenCode startup. → Task 1 test.
- **OpenCode event-shape drift.** An unknown/renamed event must be dropped with a log line, not crash the plugin. → Task 2 test (mapping unit test for unknown event).
- **Decision round-trip on a lost connection.** If the plugin's held socket for a permission request is lost, Coucou's ~115 s timeout applies and OpenCode re-asks in its own terminal; the plugin must not call `ctx.permission.reply` after the socket is gone. → Task 3.
- **Installer must not corrupt an existing `opencode.json`.** It must back up first, merge only the plugin entry, preserve all other keys, and reject if the file changed since preview (fingerprint guard, like the Gemini/Codex installers). → Task 6.
- **App Store build must not expose OpenCode.** `agent_opencode` is `githubOnly` and all routing/installer code is `#if !APPSTORE`. → Task 4 / Task 6.
- **Uninstall must remove the plugin dir and the config entry cleanly, leaving no stray Coucou plugin path.** → Task 6.

---

### Task 1: OpenCode plugin package + socket bridge

**Files:**
- Create: `opencode-coucou/package.json`
- Create: `opencode-coucou/index.ts`
- Create: `opencode-coucou/src/socket.ts`
- Create: `opencode-coucou/src/mapping.ts`
- Create: `opencode-coucou/test/socket.test.ts` (or a runnable `.mjs` check)

**Interfaces:**
- Produces: `connectSocket(sockPath: string): Promise<Socket>` (resolves to an open client socket, rejects on connect failure), `sendEvent(sock, obj): void` (newline-terminated JSON), `sendPermissionRequest(sock, payload): Promise<PermissionDecision>` (opens a held connection, resolves with the decision or rejects/returns `"ask"` on timeout). `mapEvent(evt: OpenCodeEvent): CanonicalEvent | null` (returns `null` for unmapped events).

**Approach:** Prefer a plain `export default { id: "coucou", setup(ctx) {...} }` plugin object (matching the bundled `ponytail` plugin) over importing `@opencode/plugin`, to avoid module resolution. The `setup(ctx)` connects the socket; if connect fails, log and return a no-op cleanup (never throw).

- [ ] **Step 1: Write the failing socket test**

```ts
// test/socket.test.mjs — run with node (no test framework)
import { connectSocket, sendEvent } from "../src/socket.ts";
// ... or use a stub server on a temp socket path
assert(await connectSocket(validSockPath) !== null);
await assert.rejects(() => connectSocket("/nonexistent/coucou.sock"));
```

- [ ] **Step 2: Run to verify it fails**

Run: `node --experimental-strip-types test/socket.test.mjs`
Expected: FAIL (`connectSocket` not defined).

- [ ] **Step 3: Implement `connectSocket`, `sendEvent`, `sendPermissionRequest` in `src/socket.ts`**

Use `node:net` `createConnection` on the Unix socket path. `sendEvent` writes `JSON.stringify(obj) + "\n"`. `sendPermissionRequest` keeps the connection open, resolves on a newline-terminated `permissionDecision` JSON line, and rejects/resolves `"ask"` on a timeout (Coucou's ~115 s safety window).

- [ ] **Step 4: Run test to verify it passes**

Run: `node --experimental-strip-types test/socket.test.mjs`
Expected: PASS.

- [ ] **Step 5: Write the failing plugin-export test**

```ts
import plugin from "../index.ts";
assert(plugin.id === "coucou");
assert(typeof plugin.setup === "function");
```

- [ ] **Step 6: Run to verify it fails**, then implement `index.ts` with `export default { id: "coucou", async setup(ctx) {...} }`. `setup` resolves the GitHub socket path, calls `connectSocket`, and returns a cleanup that disconnects. If connect fails, return a no-op cleanup.

- [ ] **Step 7: Commit**

```bash
git add opencode-coucou
git commit -m "feat(opencode): add OpenCode plugin socket bridge"
```

---

### Task 2: Event stream mapping + forwarding

**Files:**
- Modify: `opencode-coucou/src/mapping.ts`
- Modify: `opencode-coucou/index.ts`
- Create: `opencode-coucou/test/mapping.test.mjs`

**Interfaces:**
- Consumes: `mapEvent` (Task 1 signature) and the `ctx.event.subscribe({ signal })` AsyncIterable of `OpenCodeEvent`.
- Produces: a canonical Coucou payload `{ hook_event_name, session_id, coucou_agent: "opencode", prompt?, tool_name?, tool_input?, message?, cwd? }` per event.

**Approach:** In `setup(ctx)`, iterate `ctx.event.subscribe({ signal })`. For each event, `mapEvent(event)` and, if non-null, `sendEvent(sock, payload)`. Isolate the OpenCode-event-name → canonical-event mapping table in `mapping.ts`. Unknown events return `null` (log + drop).

- [ ] **Step 1: Write the failing mapping test** (in `test/mapping.test.mjs`) asserting the **confirmed V2 event table** (see `.superpowers/sdd/.../opencode-event-shapes.md`; these are the real `event.type` discriminants from the `@opencode-ai/sdk` v2 types):

| OpenCode `event.type` | `properties` fields to extract | → Coucou `hook_event_name` |
|---|---|---|
| `session.created` | `sessionID` | `SessionStart` |
| `session.next.prompted` | `sessionID`, `prompt.text` | `UserPromptSubmit` |
| `session.next.tool.called` | `sessionID`, `tool`, `input` | `PreToolUse` |
| `session.next.tool.success` | `sessionID`, `callID` | `PostToolUse` |
| `session.next.tool.failed` | `sessionID`, `callID` | `PostToolUseFailure` |
| `session.idle` | `sessionID` | `Stop` |
| `session.deleted` | `sessionID` | `SessionEnd` |
| `session.error` | `sessionID`, `error` | `StopFailure` |

`prompt.text`→`prompt`, `tool`→`tool_name`, `input`→`tool_input`. Every other `event.type` → `null` (noise: text/reasoning deltas, part updates, `permission.*`, `tui.*`, `mcp.*`, etc.). `cwd` is not in the event — `index.ts` fills it from `ctx.location.directory`.

- [ ] **Step 2: Run to verify it fails**, then implement `mapEvent` in `mapping.ts` with the table and an `unknown → null` default.

- [ ] **Step 3: Wire forwarding in `index.ts` `setup(ctx)`** — subscribe, map, forward. Extract `session_id`, `cwd` (from `ctx.location`), prompt, tool name/input, message from the OpenCode event shape. Wrap the mapping in try/catch so a mapping miss is logged and dropped, never thrown.

- [ ] **Step 4: Run mapping test to verify it passes.**

Run: `node --experimental-strip-types test/mapping.test.mjs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add opencode-coucou
git commit -m "feat(opencode): forward session/tool events to Coucou"
```

---

### Task 3: Permission request relay

**Files:**
- Modify: `opencode-coucou/src/socket.ts` (if `sendPermissionRequest` needs refinement)
- Modify: `opencode-coucou/index.ts`
- Create: `opencode-coucou/test/permission.test.mjs`

**Interfaces:**
- Consumes: `sendPermissionRequest` (Task 1), `ctx.permission.list/get/reply`.
- Produces: on a permission request, forward `PermissionRequest` to Coucou; when Coucou writes a decision, call `ctx.permission.reply({ sessionID, requestID, reply })` with `once`/`always`/`reject`.

**Approach:** Permission requests **surface on the event stream** as `permission.asked` (confirmed from the V2 SDK: `properties` = `PermissionRequest` with `id`/`requestID`, `sessionID`, `permission`, `patterns`). The plugin observes `permission.asked` events in the same `ctx.event.subscribe` loop as Task 2 (not via `mapEvent`, which stays event-lifecycle-only). For each `permission.asked`: forward a `PermissionRequest` payload to Coucou on a held connection (`sendPermissionRequest`), map the Coucou decision, and call `ctx.permission.reply({ sessionID, requestID, reply })` with `once`/`always`/`reject`. Ignore the `permission.replied` event (avoids a loop). If the held connection is lost/times out, do not reply — Coucou's ~115 s timeout and OpenCode's own terminal re-ask handle it.

- [ ] **Step 1: Write the failing test** asserting the decision mapping: Coucou `"allow"`→`reply:"once"`, `"always"`→`reply:"always"`, `"deny"`→`reply:"reject"`.

- [ ] **Step 2: Run to verify it fails**, then implement the mapping helper and the permission-observation/reply wiring in `index.ts`.

- [ ] **Step 3: Run to verify it passes.**

- [ ] **Step 4: Commit**

```bash
git add opencode-coucou
git commit -m "feat(opencode): relay permission decisions to the plugin"
```

---

### Task 4: Add `agent_opencode` pill (PillCatalog)

**Files:**
- Modify: `NotchBuddy/Sources/App/PillCatalog.swift`

**Interfaces:**
- Produces: pill id `agent_opencode`, name `"OpenCode"`, `source: .agent`, `githubOnly: true`; `sessionSubtitle` returns `"OpenCode"` for `agent_opencode`.

**Approach:** Add a `.init(...)` to `PillCatalog.all` in the workspace section (near `agent_codex`), and a `case "agent_opencode"` in `sessionSubtitle`. `githubOnly: true` hides it from the App Store target.

- [ ] **Step 1: Edit `PillCatalog.swift`** — add the pill entry and the `sessionSubtitle` case. Colour: `#10B981` (user-ruled; distinct from Codex `#2DD4BF`).

- [ ] **Step 2: Verify** — `PillCatalog.definition(for: "agent_opencode")` returns the entry and `sessionSubtitle` is `"OpenCode"`. Confirm `available` excludes it under `#if APPSTORE`.

- [ ] **Step 3: Commit**

```bash
git add NotchBuddy/Sources/App/PillCatalog.swift
git commit -m "feat(opencode): declare agent_opencode pill"
```

---

### Task 5: Route OpenCode as a first-class agent (HookServer)

**Files:**
- Modify: `NotchBuddy/Sources/App/HookServer.swift`

**Interfaces:**
- Consumes: `agent_opencode` (Task 4), `Self.validateAgent`, `upsertWorkspaceTask`, `frenchStep`, `sendApprovalDecision`.
- Produces: `coucou_agent == "opencode"` routes to `agent_opencode` with `isExternalAgent = false`; approval card branch; `frenchStep` OpenCode tool labels.

**Approach:** Mirror the Codex touchpoints exactly. Add `isOpenCodeEvent = rawAgent == "opencode"` (gated `#if !APPSTORE`) in `processEvent` before the `validAgent` branch, setting `agentId = "agent_opencode"`, `isExternalAgent = false`. In `processPermissionRequest`, add `isOpenCodeRequest = rawAgent == "opencode"` that bypasses the "answer immediately with ask" path and routes `pillId = "agent_opencode"`. Add `case "agent_opencode"` to the "Handled in OpenCode." / "Still waiting in OpenCode." note switches. Add OpenCode tool names to `frenchStep`'s label map.

- [ ] **Step 1: Edit `processEvent`** — add the `isOpenCodeEvent` branch (gated `#if !APPSTORE`) before `validAgent`.

- [ ] **Step 2: Edit `processPermissionRequest`** — add `isOpenCodeRequest`, bypass the `ask` path, route `pillId = "agent_opencode"`.

- [ ] **Step 3: Edit `processQuestionRequest`** — mirror the same OpenCode branch (the design lists it; confirm it is needed, else skip with a ledger note).

- [ ] **Step 4: Edit the handled-note switches** — add `case "agent_opencode"`.

- [ ] **Step 5: Edit `frenchStep`** — add the confirmed OpenCode **lowercase** tool names as new keys (OpenCode does NOT use Claude's CamelCase, so they do not map automatically; `labels[tool] ?? tool` is the fail-soft default). Add, reusing the existing French verbs:
  ```swift
  // OpenCode tools (lowercase — opencode.ai/docs/tools)
  "bash":        "Exécute",
  "read":        "Lit",
  "write":       "Écrit",
  "edit":        "Modifie",
  "grep":        "Recherche",
  "glob":        "Cherche",
  "webfetch":    "Récupère",
  "websearch":   "Recherche web",
  "todowrite":   "Tâches",
  "skill":       "Chargement",
  "question":    "Question",
  ```
  `apply_patch` already exists (line 927) and OpenCode uses the same `*** Add/Update File:` markers, so it is covered. The `mcp__` fallback (line 934) already handles MCP tools. Keep the change purely additive — do not alter the existing `Bash`/`Read`/... CamelCase keys or the `if tool == "Bash"` special-case.

- [ ] **Step 6: Commit**

```bash
git add NotchBuddy/Sources/App/HookServer.swift
git commit -m "feat(opencode): route opencode as first-class agent"
```

---

### Task 6: OpenCode installer (config + plugin files) in HookServer

**Files:**
- Modify: `NotchBuddy/Sources/App/HookServer.swift`

**Interfaces:**
- Consumes: `writeJSONFile`, `strictReadJSONObject`, `sha256Hex` (all existing helpers; OpenCode does NOT use `removeNbHookEntries`/`hookBase` — those are Codex hooks-format specific).
- Produces: `opencodeConfigURL`/`opencodePluginFileURL`/`opencodePluginDirURL`, `opencodeHooksInstalled()`, `opencodePluginSource` (embedded `#"""` string), `buildOpenCodeHooksData()`, `withoutOpenCodeHooks()`, `previewOpenCodeHooks(install:)`, `writeOpenCodeHooks()`, `_pendingOpenCodeData`/`_pendingOpenCodeFingerprint`.

**Approach:** Mirror the Codex installer's 5-part cycle (Codex writes a JSON hooks config; OpenCode writes a plugin FILE + a `plugins` config entry). Targets:
- **Plugin file:** `~/.config/opencode/plugins/coucou/index.mjs` — the single bundled plugin (embedded as `opencodePluginSource`). This is the auto-discovered global-plugins location → the actual load mechanism.
- **Config:** `~/.config/opencode/opencode.json` — merge a `plugins` (plural, V2) array entry = the absolute path to the plugin file. Preserve all other keys (the config has `$schema`, `mcp`, `plugin`, `lsp`, `agent`, `providers`, `websearch` — none may be touched).

Install = write the plugin file + merge the `plugins` entry (config backed up via `writeJSONFile`, fingerprint guard). Uninstall = remove the `plugins` entry (backup + fingerprint) + remove the `~/.config/opencode/plugins/coucou/` dir. Detect = plugin file exists (primary, since that's what actually loads it) OR the `plugins` entry is present.

- [ ] **Step 1: Add `opencodeConfigURL` / `opencodePluginFileURL` / `opencodePluginDirURL`** — `~/.config/opencode/opencode.json`, `~/.config/opencode/plugins/coucou/index.mjs`, and its parent dir. (Use `FileManager.homeDirectoryForCurrentUser` — it resolves the `~/.config/opencode` symlink.)

- [ ] **Step 2: Add `opencodeHooksInstalled()`** — returns true if the plugin file exists (primary) or the config `plugins` array contains the Coucou path.

- [ ] **Step 3: Add the embedded plugin source** — `private let opencodePluginSource = #""" ... """#` containing the verbatim content of `opencode-coucou/dist/index.mjs` (a Swift raw string; the bundle has no `#`, so it embeds cleanly).

- [ ] **Step 4: Add `buildOpenCodeHooksData()`** — reads the config via `strictReadJSONObject`; if `plugins` exists it must be `[String]` (else throw "has an unexpected type — Coucou has not touched it"); remove any existing Coucou entry, append the plugin file's absolute path; return the pretty-printed JSON (`.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`), preserving all other keys.

- [ ] **Step 5: Add `withoutOpenCodeHooks()`** — same read, remove the Coucou entry from `plugins` (drop the key if the array becomes empty), preserve everything else.

- [ ] **Step 6: Add `previewOpenCodeHooks(install:)` / `writeOpenCodeHooks()`** — the `_pendingOpenCodeData`/`_pendingOpenCodeFingerprint` cycle (Codex pattern: preview computes + fingerprints; write re-checks the fingerprint then applies). On write(install): `writeJSONFile` the config AND write `opencodePluginSource` to the plugin file (create dir). On write(uninstall): `writeJSONFile` the config AND `removeItem` the plugin dir.

- [ ] **Step 7: Commit**

```bash
git add NotchBuddy/Sources/App/HookServer.swift
git commit -m "feat(opencode): add OpenCode plugin installer"
```

---

### Task 7: OpenCode Settings row (SettingsView)

**Files:**
- Modify: `NotchBuddy/Sources/App/SettingsView.swift`

**Interfaces:**
- Consumes: `HookServer.opencodeHooksInstalled()`, `previewOpenCodeHooks`, `writeOpenCodeHooks` (Task 6).
- Produces: a `GroupBox("OpenCode Hooks")` row in `agentsSection` with Install/Uninstall buttons and a diff preview.

**Approach:** Mirror the Codex/Gemini row exactly: `@State opencodeHooksInstalled`, `showOpenCodeDiff`, `pendingOpenCodeJSON`, `opencodePendingInstall`; a `GroupBox` with the status-line ternary, Install/Uninstall buttons, and a diff preview with Confirm & write / Cancel; `triggerOpenCodePreview`/`confirmOpenCodeOp` handlers.

- [ ] **Step 1: Add the `@State` vars** near the Gemini/Agy/Codex ones (inside `#if !APPSTORE`).

- [ ] **Step 2: Add the `GroupBox("OpenCode Hooks")`** row in `agentsSection` (inside `#if !APPSTORE`).

- [ ] **Step 3: Add `triggerOpenCodePreview`/`confirmOpenCodeOp`** handlers.

- [ ] **Step 4: Commit**

```bash
git add NotchBuddy/Sources/App/SettingsView.swift
git commit -m "feat(opencode): add OpenCode installer settings row"
```

---

### Task 8: Docs + verification checklist

**Files:**
- Modify: `docs/AGENTS.md`
- Create: `docs/superpowers/plans/opencode-manual-test-checklist.md`

**Approach:** Document OpenCode as a supported first-class agent (mirroring the Gemini/Codex sections), the plugin install path, and the socket event mapping. Write the manual test checklist (Coucou routing socket quick-test + plugin lifecycle + approval round-trip) referenced by the design's verification section, since the app cannot be built/run in this session.

- [ ] **Step 1: Update `docs/AGENTS.md`** with the OpenCode section.

- [ ] **Step 2: Write the manual test checklist.**

- [ ] **Step 3: Commit**

```bash
git add docs/AGENTS.md docs/superpowers/plans/opencode-manual-test-checklist.md
git commit -m "docs(opencode): document OpenCode integration and test checklist"
```
