import type { BotState } from "../../core/types.js";
import type { NormalizedAgentState } from "./types.js";

/** Map normalized provider activity → Mochi BotState. */
export function companionStateFromAgent(state: NormalizedAgentState): BotState {
  switch (state) {
    case "idle":
      return "idle";
    case "connecting":
    case "thinking":
      return "thinking";
    case "searching":
    case "reading":
      return "searching";
    case "editing":
    case "writing":
    case "running_command":
      return "working";
    case "waiting_for_user":
      return "approval";
    case "success":
      return "finished";
    case "error":
      return "error";
  }
}
