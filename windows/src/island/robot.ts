// Robot status → island. The robot gets its own pill ("Robot"); its
// NEEDS_APPROVAL requests use the same Allow/Deny card as agent approvals
// (State.pendingApproval with tool "Robot"), and its end shows the
// finished/error card: "Robot done: <RESULT>" plus new downloads.

import { Bridge, onEvent } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ApprovalInfo } from "../core/state";
import { robotBusy, robotDoneText, robotEnded, type RobotStatus } from "../core/robot";
import type { Island } from "./island";

export const ROBOT_TASK_ID = "robot";
export const ROBOT_TOOL = "Robot";

let announcedRun = 0;
let lastStep = "";

export function isRobotApproval(req: ApprovalInfo | null): boolean {
  return req?.tool === ROBOT_TOOL && req.taskId === ROBOT_TASK_ID;
}

function ensureRobotTask() {
  let t = State.tasks.find((x) => x.id === ROBOT_TASK_ID);
  if (!t) {
    t = {
      id: ROBOT_TASK_ID, name: "Robot", color: "#38BDF8", state: "idle", stepIndex: 0, steps: [],
      source: "agent", agent: "robot", isIntegration: false,
    };
    const afterClaude = State.tasks.findIndex((x) => x.id === "integration_claude") + 1;
    State.tasks.splice(afterClaude, 0, t);
  }
  return t;
}

/** Robot card answered on the island: tell Rust, close the card. */
export function decideRobot(req: ApprovalInfo, allow: boolean) {
  void Bridge.robotApprove(req.requestId, allow);
}

function showApproval(island: Island, s: RobotStatus) {
  const a = s.approval;
  if (!a) return;
  if (State.pendingApproval) {
    if (State.pendingApproval.requestId === a.id) return;
    // Another card holds the island: badge the pill, retry when it clears.
    State.setPillBadge(ROBOT_TASK_ID, "approval");
    island.reveal();
    return;
  }
  State.pendingApproval = {
    requestId: a.id, sessionId: "", taskId: ROBOT_TASK_ID, tool: ROBOT_TOOL, command: a.action,
  };
  State.updateTask(ROBOT_TASK_ID, "approval");
  State.isPinned = true;
  Sound.play("approval");
  State.setFocus(ROBOT_TASK_ID);
  island.alert("approval");
}

function clearApproval(island: Island) {
  if (!isRobotApproval(State.pendingApproval)) return;
  State.pendingApproval = null;
  State.isPinned = false;
  island.dropPin();
  if (State.view === "approval") island.setView(State.defaultView());
}

function step(text: string) {
  if (!text || text === lastStep) return;
  lastStep = text;
  State.appendStep(ROBOT_TASK_ID, text.slice(0, 120));
}

function announce(island: Island, s: RobotStatus) {
  if (announcedRun === s.runId) return;
  announcedRun = s.runId;
  const ok = s.phase === "done";
  const { title, detail } = robotDoneText(s);
  State.updateTask(ROBOT_TASK_ID, ok ? "finished" : s.phase === "failed" ? "error" : "idle");
  step(detail ? `${title} · ${detail}` : title);
  Sound.play(ok ? "finish" : s.phase === "failed" ? "error" : "blip");
  const view = s.phase === "failed" ? "error" : "finished";
  // The Robot panel already shows the outcome; elsewhere the card opens.
  if (State.mode === "expanded" && State.view === "robot") return;
  if (State.pendingApproval || (State.mode === "expanded" && ["prompt", "task", "settings"].includes(State.view))) {
    State.setPillBadge(ROBOT_TASK_ID, view);
    island.reveal();
    return;
  }
  State.setFocus(ROBOT_TASK_ID);
  island.alert(view);
}

function apply(island: Island, s: RobotStatus) {
  State.robot = s;
  if (s.phase === "idle") {
    State.notify();
    return;
  }
  ensureRobotTask();
  if (s.phase === "approval") {
    showApproval(island, s);
  } else {
    clearApproval(island);
    if (robotBusy(s)) {
      State.updateTask(ROBOT_TASK_ID, "working");
      if (State.tasks.find((t) => t.id === ROBOT_TASK_ID)?.pillBadge === "approval") State.setPillBadge(ROBOT_TASK_ID, null);
      step(s.message);
      if (State.mode === "hidden") island.reveal();
    } else if (robotEnded(s)) {
      announce(island, s);
    }
  }
  State.notify();
}

export async function registerRobotHandlers(island: Island) {
  await onEvent<RobotStatus>("robot-status", (s) => apply(island, s));
  const now = await Bridge.robotStatus();
  if (now) {
    // A finished run from before this page loaded is not announced again.
    if (robotEnded(now)) announcedRun = now.runId;
    apply(island, now);
  }
  // A robot approval that queued behind another card shows once it clears.
  window.setInterval(() => {
    if (State.robot.phase === "approval" && !State.pendingApproval && !State.paused) showApproval(island, State.robot);
  }, 1000);
}
