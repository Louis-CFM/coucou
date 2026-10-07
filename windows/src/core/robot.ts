// Coucou Robot — a background agent doing a task in the hidden browser.
// Rust runs it (src-tauri/src/robot.rs); this is the shape of its status and
// the wording the island and the chat use for it.

export type RobotPhase = "idle" | "browser" | "running" | "approval" | "done" | "denied" | "stopped" | "failed";

export interface RobotApproval {
  id: string;
  action: string;
}

/** Rust robot::RobotStatus. */
export interface RobotStatus {
  phase: RobotPhase;
  runId: number;
  task: string;
  agent: string;
  message: string;
  result: string;
  /** New files in Downloads\Coucou-Robot, names only. */
  files: string[];
  downloads: string;
  approval: RobotApproval | null;
}

export const MAX_ROBOT_TASK = 4000;

export const IDLE_ROBOT: RobotStatus = {
  phase: "idle", runId: 0, task: "", agent: "", message: "", result: "", files: [], downloads: "", approval: null,
};

export function robotBusy(s: RobotStatus): boolean {
  return s.phase === "browser" || s.phase === "running" || s.phase === "approval";
}

export function robotEnded(s: RobotStatus): boolean {
  return s.phase === "done" || s.phase === "denied" || s.phase === "stopped" || s.phase === "failed";
}

/** One status line for the Robot panel. */
export function robotStatusLine(s: RobotStatus): { kind: "ok" | "paste" | "error" | ""; text: string } {
  switch (s.phase) {
    case "idle":
      return { kind: "", text: "Runs in the hidden browser. Your mouse and windows are never touched." };
    case "browser":
    case "running":
      return { kind: "ok", text: s.message || "Working…" };
    case "approval":
      return { kind: "paste", text: `Needs your OK: ${s.approval?.action ?? "…"}` };
    case "done":
      return { kind: "ok", text: s.message || `Robot done: ${s.result}` };
    case "denied":
      return { kind: "paste", text: s.message || "Denied." };
    case "stopped":
      return { kind: "paste", text: "Stopped." };
    case "failed":
      return { kind: "error", text: s.message || "The robot failed." };
  }
}

/** "Robot done: …" plus the new downloads, for the island card. */
export function robotDoneText(s: RobotStatus): { title: string; detail: string } {
  const title = s.phase === "done" ? `Robot done: ${s.result || "finished."}`
    : s.phase === "denied" ? "Robot: denied."
    : s.phase === "stopped" ? "Robot stopped."
    : `Robot failed: ${s.message}`;
  const detail = s.files.length
    ? `New in Downloads\\Coucou-Robot: ${s.files.slice(0, 5).join(", ")}${s.files.length > 5 ? ` +${s.files.length - 5}` : ""}`
    : s.phase === "denied" ? s.message.replace(/^Denied:\s*/, "Not done: ")
    : "";
  return { title, detail };
}
