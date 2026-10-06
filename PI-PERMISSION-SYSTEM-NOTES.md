# Pi permission system — what Coucou changed, and why

Reference for the `pi-permission-system` edits. **Nothing in this document is
implemented by Coucou's installer.** The patch is applied by hand, deliberately, and
this file exists so that if you ever do want install/uninstall to manage it, you know
exactly what has to happen first.

If you only want to keep using Coucou, you never need to act on any of this.

---

## What the patch touches

| | |
|---|---|
| **Package** | `pi-permission-system` 0.8.0 |
| **File** | `~/.pi/agent/npm/node_modules/pi-permission-system/src/index.ts` |
| **Script** | `~/.pi/agent/scripts/patch-coucou-permissions.mjs` |
| **Marker** | `COUCOU_PERMISSION_PATCH_REV = 2` |
| **Durability** | Survives `npm update`, because the patch is re-applied, not stored |

Backups kept on this machine:

```
src/index.ts.20260410-before-coucou-permission-fix.bak
```

---

## The bug it fixes

`pi-permission-system` is the extension that decides what needs approving before a
tool runs. Out of the box it asked through **Pi's own dialog**, which means a
permission request is answered wherever Pi happens to be — often invisible when Pi is
running somewhere else, and never in the island.

Coucou already listens on a pipe for approval requests from every other agent. Pi was
the odd one out. The patch makes `pi-permission-system` ask **Coucou** instead, and
fall back to Pi's dialog when Coucow cannot answer.

---

## Before and after

### Before

```
pi-permission-system
        │
        └── asks Pi's dialog directly        ← invisible when Pi is in another window
```

### After

```
pi-permission-system
        │
        └── asks Coucou (coucou-hook relay)
                    │
                    ├── Coucou answers          → back down the relay
                    ├── Coucow not running      → fall through to Pi's dialog
                    ├── no answer in time       → fall through to Pi's dialog
                    └── relay output unreadable → fall through to Pi's dialog
```

Everything below the first arrow is the whole point: **fail open, always**. An
infrastructure failure must never turn into a denial.

---

## The changes, one by one

### 1. Ask Coucow first

A new `tryCoucouPermissionRequest()` is inserted ahead of Pi's existing prompt. It
spawns `coucou-hook` and relays the request to the island.

### 2. Every failure returns `handled: false`

This is the most important property of the patch. All of these fall through to Pi's
own dialog rather than blocking or denying:

| Failure | Behaviour |
|---|---|
| Relay missing | `handled: false` |
| Pipe absent (Coucou closed) | `handled: false`, **immediately** |
| Timeout | `handled: false` |
| Unreadable / invalid output | `handled: false` |
| Spawn error | `handled: false` |

The immediate exit on "no pipe" is load-bearing and was verified by hand. Coucow's
relay binary stays on disk after Coucou exits, so `existsSync(COUCOU_HOOK_EXE)` is
still true. Only the relay's own early exit keeps a closed Coucou from stalling the
request for the full timeout.

### 3. The timeout is 120 seconds

```ts
const COUCOU_PERMISSION_TIMEOUT_MS = 120_000;
```

This matches the relay's decision budget. The previous value was 800 ms, which is
not enough time for a human to read a permission request and answer it — it was
effectively an automatic fallback.

### 4. YOLO short-circuits Coucou entirely

`isYoloModeEnabled(extensionConfig)` returns `{ approved: true, handled: true }`
without spawning `coucou-hook` at all. No pipe, no island card, no process. In YOLO
mode there is nothing to ask.

### 5. Four real outcomes, not two

The wire protocol was widened from bare `allow` / `deny` words:

```json
{"behavior":"deny","message":"..."}
{"behavior":"allow","always":true}
```

The island now offers:

| Button | Result |
|---|---|
| **Allow** | Approve once |
| **Always** | Approve this permission pattern for the session |
| **Deny** | Refuse |
| **Why not?** *(note field)* | Attach a reason; Enter submits, Escape clears |

The reason is human-authored. The relay used to hardcode `Denied from Coucou.`, which
told the model nothing useful.

`pipe::answer()` and `approval_decision` carry `note: Option<String>` while keeping
`always` distinct from a one-off allow.

**Compatibility is preserved in both directions.** The new island still accepts a
legacy bare `allow` / `deny`, so an older relay paired with a new island — or the
reverse — degrades to the previous behaviour instead of failing.

### 6. `always` reaches the session

Both Pi approval branches now use:

```ts
state: coucouResult.always ? "always" : "once"
```

`Always` is session-scoped and persists through
`sessionApprovals.approveAlways(...)`.

### 7. Stale upstream comment removed

Coucou's old stub comment inside the patched file was deleted, so the file does not
claim to do something it no longer does.

---

## Known limitations

These are deliberate and documented rather than fixed:

- **Claude Code ignores the `always` scope** and degrades it to a normal allow.
- **Pi's skill branch has no persistence plumbing**, so `Always` acts as `Allow`
  there.

Both are honest gaps in the hosts, not in the patch.

---

## Why the patch script exists

Pi updates overwrite `node_modules`. A patch applied by hand is lost on the next
`npm install`, silently returning permission requests to a dialog nobody is looking
at.

`patch-coucou-permissions.mjs` re-applies the patch idempotently. Revision 2 fixed
several things the first version got wrong:

- Correctly upgrades an older patch instead of assuming a clean file
- Adds the missing `isYoloModeEnabled` import
- Wires **both** `state: "once"` approval branches, not just one
- Locates the function end correctly when the return type is
  `Promise<{...}>` rather than a plain object
- Accepts `--target <path>` so it can be tested against a copy

Re-running it on an already-patched file is a no-op. Against a pristine backup it
reproduces the live file.

---

## The second half of the Pi integration, and why it is separate

Coucou's Pi integration has **two independent parts**:

| Part | What it is | Who manages it |
|---|---|---|
| `~/.pi/agent/extensions/coucou.ts` | Observes sessions, tool calls, completion | Coucou — whole-file, backed up, install/uninstall works |
| `pi-permission-system` patch | Makes Pi ask Coucou for decisions | **By hand only** |

They are separate on purpose. The extension only ever *reports*; the patch is what
asks. Coucou can be installed and uninstalled freely without touching the second
one, which is exactly the current arrangement.

---

## If you ever want Coucou to manage the patch

Not recommended without reading this first. What a correct implementation needs:

1. **Locate the live file** at
   `~/.pi/agent/npm/node_modules/pi-permission-system/src/index.ts`.
2. **Verify it is the package we patched** before touching it. A version bump may
   have changed the code being spliced.
3. **Back up to Coucou's own directory**, not next to the file, so the backup cannot
   be mistaken for Pi's state.
4. **Apply the splice in Rust**, mirroring `patch-coucou-permissions.mjs`. Coucou is
   currently not self-contained here; the script is the recovery path.
5. **On uninstall, restore from backup** to return the file to un-patched.
6. **Fail closed.** If the backup is missing or the live file does not look like the
   package we patched, refuse rather than write something uncertain.

**Step 6 is the important one.** Writing the wrong thing into
`pi-permission-system` breaks Pi's permissions, and that is a far worse outcome than
leaving a hook installed — a stuck hook is recoverable, broken permissions might not
be.

### Recovering by hand

```bash
# see what is patched now
node ~/.pi/agent/scripts/patch-coucou-permissions.mjs

# back the patch out
cp ~/.pi/agent/npm/node_modules/pi-permission-system/src/index.ts.20260410-before-coucou-permission-fix.bak \
   ~/.pi/agent/npm/node_modules/pi-permission-system/src/index.ts
```

Restart Pi afterwards so it reloads the extension.
