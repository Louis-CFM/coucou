# Pi and Oh My Pi sessions in Coucou

These read-only extensions show terminal sessions in Coucou's automatic agent
pills: idle, thinking, working, finished, error, and interrupted. Multiple sessions
keep distinct identities. Tools contribute their names to the ticker.

Pi means [pi.dev](https://pi.dev), whose upstream is
[earendil-works/pi](https://github.com/earendil-works/pi) (formerly `badlogic/pi-mono`).
Coucou's [request #462](https://github.com/Louis-CFM/coucou/issues/462) identifies
this project. Oh My Pi is [can1357/oh-my-pi](https://github.com/can1357/oh-my-pi),
requested in [#9](https://github.com/Louis-CFM/coucou/issues/9).

## Compatibility

| Harness | Verified package | Runtime | Completion boundary |
| --- | --- | --- | --- |
| Pi | `@earendil-works/pi-coding-agent@1.3.0` | Node ≥22.19 | `agent_before_settle` outcome + `agent_settled` |
| OMP | `@oh-my-pi/pi-coding-agent@18.12.5` | Bun ≥1.3.14 (tested with 1.4.2) | `agent_end` without `willContinue` / `awaitingAsyncWork` |

These are tested versions, not a promise that older or future versions share the
API. The old `@mariozechner/pi-coding-agent` package is not covered. Each adapter
imports its own official `ExtensionAPI` for type checking; only Coucou's relay and
session bookkeeping are shared. There are no runtime npm dependencies for these
extensions or changes to the native app's dependencies.

Default relay paths follow Coucou 0.5.2 (macOS GitHub build) and its current
Windows/Linux implementation. macOS is exercised locally, including the shipping
Python relay against a temporary socket. Linux and Windows relay discovery are
implemented, but delivery through their native relays has not been verified.

## Try without changing settings

Run Coucou once so it installs its local relay. Keep this checkout, including
`integrations/shared/`, then run the appropriate command:

```sh
pi --extension /path/to/coucou/integrations/pi/coucou.ts
omp --extension /path/to/coucou/integrations/oh-my-pi/coucou.ts
```

No `npm install` is needed to use them: the harness loads TypeScript and erases the
type-only SDK import. Use only the adapter for that harness. Do not copy a lone
`coucou.ts` into an auto-discovery directory: its relative shared imports must remain
beside it. Do not enable the same adapter through both a flag and settings.

Submit a prompt. Its pill should think, show tool names while working, then finish
or show an error. Escape returns an aborted run to idle. Quit closes the session.
A successful turn is shown for Coucou's normal finished interval; automatic pills
disappear afterward. The extensions do not add declarable entries to Active pills.

## Enable persistently

Back up your settings, then merge the absolute extension path into the existing
list, keeping your other entries. These snippets are not complete replacement files.

Pi, `~/.pi/agent/settings.json` (or the selected `PI_CODING_AGENT_DIR`):

```json
{
  "extensions": ["/path/to/coucou/integrations/pi/coucou.ts"]
}
```

OMP, `~/.omp/agent/config.yml` (or the active profile's agent directory):

```yaml
extensions:
  - /path/to/coucou/integrations/oh-my-pi/coucou.ts
```

OMP's current extension system uses `extensions/` and `config.yml`; new integrations
should not target its legacy hooks API. Profiles and directory overrides are
described in its [loading guide](https://github.com/can1357/oh-my-pi/blob/v18.12.5/docs/extension-loading.md).
Restart after enabling or updating. To uninstall, remove just the path you added and
restart. No credentials, background daemon, or extra user configuration is created.

## Relay configuration

| Platform | Default installed relay |
| --- | --- |
| macOS GitHub build | `~/Library/Application Support/NotchBuddy/nb-hook` |
| Linux | `$XDG_DATA_HOME/coucou/bin/coucou-hook`, or `~/.local/share/coucou/bin/coucou-hook` |
| Windows | `%LOCALAPPDATA%\Coucou\bin\coucou-hook.exe` |

Set `COUCOU_HOOK_PATH` to an **absolute path** to select another installed relay.
On macOS it is passed as a literal argument to `/bin/sh`; elsewhere the executable
is spawned directly. A path is never evaluated as shell command text.

```sh
COUCOU_HOOK_PATH=/absolute/path/to/nb-hook pi -e /path/to/coucou/integrations/pi/coucou.ts
```

For the Mac App Store build, first install Coucou's relay through its normal
user-confirmed setup, then select that relay (normally `~/.claude/coucou/nb-hook`)
with `COUCOU_HOOK_PATH`. This variant has not been exercised with the App Store app.
If nothing appears, verify the harness version, restart after configuring, and
check that the selected relay exists and Coucou is running as the same user.
Events are not retried while Coucou is unavailable; a later event reconnects normally.

## Events and privacy

| Harness event | Coucou event |
| --- | --- |
| `session_start` | `SessionStart` |
| OMP `session_switch` / `session_branch` with a new session id | old `SessionEnd`, new `SessionStart` |
| `before_agent_start` | `UserPromptSubmit` without prompt text |
| `tool_execution_start` | `PreToolUse` with tool name |
| `tool_execution_end` | `PostToolUse` or `PostToolUseFailure` |
| Pi `agent_settled` | `Stop`, `StopFailure`, or `Interrupt` using settlement outcome |
| OMP terminal `agent_end` | `Stop`, `StopFailure`, or `Interrupt` using the last finalized assistant outcome |
| `session_shutdown` | `SessionEnd` |

Pi's low-level `agent_end` is ignored: retries, compaction, or queued continuations
may follow. OMP's `willContinue` / `awaitingAsyncWork` similarly suppress premature
finish alerts. OMP notification types can overtake one another: `agent_start` and `message_end`
are deliberately not used as state boundaries. An admitted `before_agent_start`
(or awaited `context` for a synthetic model continuation) owns a run, and awaited `assistant_message` snapshots retain finalized stop
reasons even when child-session history is pruned. The main-session `session_stop`
snapshot takes precedence when recovery replaces the outcome. Terminal
`agent_end` still decides whether work continues; a cut-off stream can report an
abort from its settled messages without an `assistant_message` callback. Historical
assistant timestamps are excluded from the new run. Only a finalized `stop` is successful. Terminal `error` or `length` is a failure;
missing, aborted or otherwise incomplete outcomes are neutral (`Interrupt`),
avoiding a false success alert. Idle side queries do not admit agent runs. These hooks return no decisions or rewritten content. A tool failure alone does not
mark the entire run failed.

The extensions send only the event, harness tag, namespaced session id, directory,
and tool name. Coucou's relay may add its normal terminal metadata and directory
label. Prompts, tool arguments/results, assistant text, images, and credentials are
not forwarded. This scope does not provide live diffs, answer summaries, approval
cards, question answers, or chat initiated from Coucou. Permissions and questions
remain under the harness's control; handlers never return decisions or modify
messages. No model API is called by the integration.

Delivery is best effort: one relay child per extension instance, a 32-record queue,
and a 500 ms child lifetime. Under overload, old metadata can be dropped and final
states replace stale queued tool updates. Normal handlers return without waiting
on I/O. Shutdown drains for at most one second, then discards the remainder and
kills its active relay (including the Mac wrapper's process group). No polling
runs while idle. State belongs to each factory, including OMP's rebound child sessions.

## Validation and upgrades

```sh
cd integrations
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
npm run test:contracts
```

Development dependencies pin both official SDKs for compile-time and real-loader /
runner contract tests. Lifecycle, privacy, session replacement, relay failure,
overload, and the shipping Python relay's socket framing are exercised without
model calls or user settings. The socket test binds only a temporary `/tmp` socket;
a restrictive sandbox may require approval for it. Runtime contracts use in-memory
sessions. These tests do not exercise the rendered notch or a live model run.
The existing native Build workflow does not run the extension tests; run these
commands manually when changing an adapter or upgrading an SDK.

When updating either SDK, review that harness's event types and runtime emission
sites, update the version and lockfile, then rerun all three commands. Official
references: Pi's [extension types](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/src/core/extensions/types.ts)
and OMP's [extensions guide](https://github.com/can1357/oh-my-pi/blob/v18.12.5/docs/extensions.md).
