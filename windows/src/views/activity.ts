// The compact island while agents work: what each one is doing, one line, next
// to Mochi. With several sessions at work the line takes each in turn, and a
// count says how many there are. Hidden, it does nothing at all.

import { h, clear, dot } from "./dom";
import type { AgentTask } from "../core/state";
import { lastTextStep } from "../core/diff";
import { t, tn } from "../i18n/i18n";

/** How long each working session stays on the line when there are several. */
const ROTATE_MS = 3500;

export class ActivityStrip {
  readonly el = h("div", { id: "activity" });
  private readonly line = h("div", { class: "activity-line" });
  private readonly count = h("span", { class: "activity-count" });
  private tasks: AgentTask[] = [];
  private index = 0;
  private timer: number | null = null;
  private key = "";

  constructor() {
    this.el.append(this.line, this.count);
  }

  /** `tasks`: the sessions at work, shown while `visible`. */
  sync(visible: boolean, tasks: AgentTask[]) {
    this.el.classList.toggle("on", visible);
    this.tasks = visible ? tasks : [];
    const rotate = visible && tasks.length > 1;
    if (rotate && this.timer == null) {
      this.timer = window.setInterval(() => {
        this.index++;
        this.render();
      }, ROTATE_MS);
    } else if (!rotate && this.timer != null) {
      window.clearInterval(this.timer);
      this.timer = null;
    }
    if (visible) this.render();
  }

  private render() {
    const list = this.tasks;
    if (list.length === 0) return;
    const task = list[this.index % list.length];
    const step = lastTextStep(task.steps) ?? (task.state === "thinking" ? t("Thinking…") : t("Working…"));
    const subagents = task.subagents?.length ?? 0;
    const key = [task.id, task.name, task.color, step, subagents, list.length].join("~");
    if (key === this.key) return;
    const switched = !this.key.startsWith(`${task.id}~`);
    this.key = key;

    clear(this.line);
    this.line.append(
      dot(task.color, 6),
      h("span", { class: "activity-name", text: task.name }),
      h("span", { class: "activity-step", text: step }),
    );
    if (subagents > 0) {
      this.line.append(h("span", {
        class: "activity-sub",
        text: tn("{count} subagent", "{count} subagents", subagents),
      }));
    }
    // A new session on the line slides in; a new step of the same one does not.
    if (switched) {
      this.line.classList.remove("in");
      void this.line.offsetWidth;
      this.line.classList.add("in");
    }
    this.count.textContent = list.length > 1 ? t("{count} active", { count: list.length }) : "";
    this.count.style.display = list.length > 1 ? "" : "none";
  }
}
