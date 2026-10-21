import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { createReporter } from "../shared/session.ts";

type Outcome = "Stop" | "StopFailure" | "Interrupt";
type Assistant = { role: string; timestamp: number; stopReason?: string };
type Run = {
  session: string;
  previous: Set<number>;
  observed: Set<number>;
  latest?: Assistant;
  settled?: Assistant;
  ended: boolean;
};

function outcome(message: Assistant | undefined): Outcome {
  if (message?.stopReason === "stop") return "Stop";
  if (message?.stopReason === "error" || message?.stopReason === "length") return "StopFailure";
  return "Interrupt";
}

/** OMP notification event types can overtake one another. Use awaited control
 * snapshots for outcomes; never reset a run from a late agent_start notification. */
export default function coucou(omp: ExtensionAPI): void {
  const reporter = createReporter("oh-my-pi");
  let run: Run | undefined;
  // The SDK omits run identity from agent_end. Once admissions overlap an
  // undelivered end, empty snapshots cannot safely identify any later run.
  let anonymousEndSafe = true;

  function begin(ctx: ExtensionContext): void {
    // A session branch is the admission boundary, not notification arrival time.
    // Assistant timestamps distinguish the new run from history left by its predecessor.
    if (run && !run.ended) anonymousEndSafe = false;
    const previous = new Set<number>();
    run?.observed.forEach(timestamp => previous.add(timestamp));
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "message" && entry.message.role === "assistant") previous.add(entry.message.timestamp);
    }
    run = {
      session: ctx.sessionManager.getSessionId(),
      previous,
      observed: new Set(),
      ended: false,
    };
  }

  function reset(ctx: ExtensionContext): void {
    if (run && !run.ended) anonymousEndSafe = false;
    reporter.start(ctx); run = undefined;
  }
  omp.on("session_start", (_event, ctx) => { reset(ctx); });
  omp.on("session_switch", (_event, ctx) => { reset(ctx); });
  omp.on("session_branch", (_event, ctx) => { reset(ctx); });
  omp.on("before_agent_start", (_event, ctx) => {
    begin(ctx);
    reporter.send(ctx, { hook_event_name: "UserPromptSubmit" });
  });
  omp.on("context", (_event, ctx) => {
    // Synthetic continuations can enter a model call without a user prompt.
    // This boundary is awaited; a late agent_start cannot admit a phantom run.
    if (!run || run.ended) {
      if (ctx.isIdle()) return; // Idle /btw and other ephemeral queries are not agent runs.
      begin(ctx);
      reporter.send(ctx, { hook_event_name: "UserPromptSubmit" });
    }
  });
  omp.on("tool_execution_start", (event, ctx) => {
    if (run?.ended) return;
    reporter.send(ctx, { hook_event_name: "PreToolUse", tool_name: event.toolName });
  });
  omp.on("tool_execution_end", (event, ctx) => {
    if (run?.ended) return;
    reporter.send(ctx, {
      hook_event_name: event.isError ? "PostToolUseFailure" : "PostToolUse",
      tool_name: event.toolName,
    });
  });
  omp.on("assistant_message", (event, ctx) => {
    if (!run || run.ended || run.session !== ctx.sessionManager.getSessionId()) return;
    // This control hook is awaited before finalization. Unlike message_end, a
    // preceding notification observer cannot delay it past agent_end.
    if (run.previous.has(event.message.timestamp)) return;
    run.observed.add(event.message.timestamp);
    run.latest = {
      role: "assistant", timestamp: event.message.timestamp, stopReason: event.message.stopReason,
    };
  });
  omp.on("session_stop", (event, ctx) => {
    if (!run || run.ended || event.signal.aborted || event.session_id !== run.session
        || ctx.sessionManager.getSessionId() !== run.session) return;
    // Main-session recovery may replace/prune the failed assistant. The stop
    // snapshot retains that terminal failure; it is not itself a completion signal.
    const message = event.last_assistant_message;
    if (message?.role === "assistant" && !run.previous.has(message.timestamp)) {
      run.observed.add(message.timestamp);
      run.settled = { role: "assistant", timestamp: message.timestamp, stopReason: message.stopReason };
    }
  });
  omp.on("agent_end", (event, ctx) => {
    if (event.willContinue || event.awaitingAsyncWork || !run || run.ended
        || run.session !== ctx.sessionManager.getSessionId()) return;
    const current = run;
    const last = event.messages.findLast(message => message.role === "assistant" && !current.previous.has(message.timestamp));
    if (event.messages.some(message => message.role === "assistant")) {
      // Validate the notification's owner before consulting that run's snapshots.
      // In an overlap, an unseen (e.g. aborted) message has no proven owner either.
      if (!last || (!anonymousEndSafe && !current.observed.has(last.timestamp))) return;
    } else if (!anonymousEndSafe) return;
    // Aborts (including provider streams cut before assistant_message) and child
    // sessions still have their terminal assistant in the settled message snapshot.
    // Prefer the recovery-aware stop snapshot on equal timestamps.
    const candidates = [run.latest, last, run.settled].filter((message): message is Assistant => message !== undefined);
    const final = candidates.reduce<Assistant | undefined>((latest, message) =>
      !latest || message.timestamp >= latest.timestamp ? message : latest, undefined);
    if (!final && event.messages.some(message => message.role === "assistant")) return;
    run.ended = true;
    reporter.send(ctx, { hook_event_name: outcome(final) });
  });
  omp.on("session_shutdown", () => reporter.close());
}
