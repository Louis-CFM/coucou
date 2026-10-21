import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { createReporter } from "../shared/session.ts";

/** OMP 18.12: agent_end explicitly marks automatic/background continuation. */
export default function coucou(omp: ExtensionAPI): void {
  const reporter = createReporter("oh-my-pi");
  let outcome: "Stop" | "StopFailure" | "Interrupt" = "Stop";

  omp.on("session_start", (_event, ctx) => { reporter.start(ctx); });
  omp.on("session_switch", (_event, ctx) => { reporter.start(ctx); });
  omp.on("session_branch", (_event, ctx) => { reporter.start(ctx); });
  omp.on("before_agent_start", (_event, ctx) => {
    reporter.send(ctx, { hook_event_name: "UserPromptSubmit" });
  });
  omp.on("agent_start", (_event, ctx) => {
    outcome = "Stop";
    reporter.send(ctx, { hook_event_name: "UserPromptSubmit" });
  });
  omp.on("tool_execution_start", (event, ctx) => {
    reporter.send(ctx, { hook_event_name: "PreToolUse", tool_name: event.toolName });
  });
  omp.on("tool_execution_end", (event, ctx) => {
    reporter.send(ctx, {
      hook_event_name: event.isError ? "PostToolUseFailure" : "PostToolUse",
      tool_name: event.toolName,
    });
  });
  omp.on("message_end", event => {
    if (event.message.role !== "assistant") return;
    // Recovery can prune a failed assistant from agent_end.messages.
    outcome = event.message.stopReason === "aborted" ? "Interrupt"
      : event.message.stopReason === "error" ? "StopFailure" : "Stop";
  });
  omp.on("agent_end", (event, ctx) => {
    if (event.willContinue || event.awaitingAsyncWork) return;
    reporter.send(ctx, { hook_event_name: outcome });
  });
  omp.on("session_shutdown", () => reporter.close());
}
