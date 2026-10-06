// Quick Robot window (global hotkey). The same panel as the island's Robot
// tab; the robot's status, approvals and result still come up on the island.

import { Bridge, onEvent } from "../core/bridge";
import type { RobotStatus } from "../core/robot";
import { State } from "../core/state";
import { buildRobot } from "../views/robot";
import { quickFrame, renderLoop } from "./frame";

async function main() {
  const frame = await quickFrame("quick-robot", "Robot");
  const view = buildRobot(() => frame.hide());
  view.el.classList.add("on");
  frame.body.append(view.el);
  renderLoop(() => view.sync());

  const now = await Bridge.robotStatus();
  if (now) State.robot = now;
  await onEvent<RobotStatus>("robot-status", (s) => {
    State.robot = s;
    State.notify();
  });
  await onEvent<string>("quick-shown", () => {
    view.sync();
    window.setTimeout(() => view.focus?.(), 60);
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) view.cancelVoice();
    view.sync();
  });
  State.notify();
  view.focus?.();
}

void main();
