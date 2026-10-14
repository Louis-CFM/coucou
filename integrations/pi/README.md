# Monitor Pi sessions in Coucou

This Pi extension reports sessions launched from Gentle Shell (or any other terminal) to Coucou's existing local hook socket. No Coucou rebuild or shell wrapper is needed. Coucou dynamically shows a `pi` agent pill.

## Try it without installing

Open Coucou, then launch Pi from the repository root:

```sh
pi -e ./integrations/pi/coucou.ts
```

Submit a prompt. Coucou should show the Pi agent thinking, working during tools, and finished only when the agent settles. An interrupted run reports idle; quitting Pi removes its task. Existing external-agent behavior aggregates multiple Pi sessions into one pill, not one card per session.

## Keep it enabled

After testing, copy `coucou.ts` into Pi's auto-loaded extension directory, `~/.pi/agent/extensions/`, then restart Pi or run `/reload`. Inspect any existing file with that name first: do not overwrite another extension. This repository change does not install anything or edit your Pi configuration.

To uninstall, remove only the copied `coucou.ts` extension and restart Pi or run `/reload`.

## Requirements and behavior

- macOS Coucou with its hook socket enabled; GitHub builds use `~/Library/Application Support/NotchBuddy/nb.sock`.
- Pi must support `agent_settled`, `agent_before_settle`, `agent_start` and `ctx.sessionManager.getSessionId()` (available in the Gentle Pi runtime used for this integration). Earlier Pi versions lacking these APIs are not supported.
- Set `COUCOU_SOCKET_PATH` before launching Pi to choose another socket. For a Coucou App Store build exposing `~/nb.sock`, use `COUCOU_SOCKET_PATH="$HOME/nb.sock" pi -e ./integrations/pi/coucou.ts`.
- Events carry the stable Pi session ID, the project directory, and the tool name on tool events only. Prompts, tool arguments, results and assistant text are **not** forwarded.
- Monitoring only: no permission requests, approval clicks or tool decisions are intercepted.
- Each event has a 150 ms absolute deadline, no retries and silent socket-error handling. A closed Coucou does not cause Pi operations to fail. Start Coucou before Pi so it receives the initial session event.
- `agent_end` and `turn_end` are not completion signals; automatic recovery and queued continuations may still follow. Completion uses `agent_settled`.
- A turn that fails (for example an HTTP 400, a rate limit, or no available model) settles as **error**. `agent_settled` carries only `aborted`, so the outcome is read from the earlier `agent_before_settle` boundary and reset at each `agent_start`. Tool errors are also reported as `PostToolUseFailure`.
- Coucou aggregates all Pi sessions into one `pi` pill, so a second session does not get its own card, and one session ending can clear the shared pill.

## Known limitations

- A turn that ends without `agent_settled` (for example a hard process kill) leaves the pill until Coucou's own cleanup runs.
- If Pi never reports an `agent_before_settle` outcome, a turn falls back to `aborted` and otherwise reports as finished.

## Test

Requires Node.js 24 with native TypeScript support:

```sh
bash scripts/test-pi-extension.sh
```

Tests use real isolated Unix sockets inside this repository, a fake Pi event registrar, and the extension's public entry point. They cover lifecycle payloads, stable IDs across turns, new-session identity, tool failures, the settled outcome (error, finished, idle), the deadline, and absent or unresponsive Coucou. They do not launch the macOS UI or a real Pi session.
