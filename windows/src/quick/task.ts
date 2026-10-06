// Quick "+ Task" window (global hotkey). The same card as the island's; after
// a launch that went through, the result stays up briefly and the window hides.

import { onEvent } from "../core/bridge";
import { buildTask } from "../views/task";
import { quickFrame, renderLoop } from "./frame";

/** How long the "Started …" note stays before the window hides. */
export const HIDE_AFTER_MS = 1500;
/** "Prompt copied, paste it" needs reading time before the window goes. */
export const HIDE_AFTER_PASTE_MS = 4000;

async function main() {
  const frame = await quickFrame("quick-task", "New task");
  let hideTimer: number | null = null;
  const view = buildTask(
    () => frame.hide(),
    () => {},
    (outcome) => {
      if (hideTimer != null) window.clearTimeout(hideTimer);
      hideTimer = window.setTimeout(() => {
        hideTimer = null;
        frame.hide();
      }, outcome.status === "started" ? HIDE_AFTER_MS : HIDE_AFTER_PASTE_MS);
    },
  );
  view.el.classList.add("on");
  frame.body.append(view.el);
  renderLoop(() => view.sync());

  await onEvent<string>("quick-shown", () => {
    if (hideTimer != null) {
      window.clearTimeout(hideTimer);
      hideTimer = null;
    }
    view.sync();
    window.setTimeout(() => view.focus?.(), 60);
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) view.cancelVoice();
  });
  view.focus?.();
}

void main();
