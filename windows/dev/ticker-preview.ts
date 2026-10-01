// Dev harness: the overview ticker on its own, fed with fake Claude Code steps,
// so the scroll can be watched without a live session. Not part of the bundle.

import "../src/style.css";
import { Ticker } from "../src/views/ticker";
import { h } from "../src/views/dom";
import type { AgentTask } from "../src/core/state";

const SAMPLES = [
  "Exécute · git status --short && git log --oneline -5 && git diff --stat HEAD~3",
  "Exécute · (Get-Command gh -ErrorAction SilentlyContinue).Source",
  "Lit · ticker.ts",
  "Modifie · style.css",
  "Recherche · ensureRunning",
  "Cherche · **/*.ts",
  "Exécute · npm run build",
];

const task = {
  id: "integration_claude",
  name: "coucou",
  source: "claudeCode",
  state: "working",
  color: "#f5f6f8",
  steps: [] as string[],
  stepIndex: 0,
} as unknown as AgentTask;

const ticker = new Ticker();
const who = h(
  "div",
  { class: "who" },
  h("span", { class: "name", text: "coucou" }),
  h("span", { class: "tool", text: "Claude Code" }),
);
const card = h("div", { class: "card" }, h("div", { class: "card-body" }, who, ticker.el));
document.getElementById("stage")!.append(card, h("div", { id: "bot" }));

let n = 0;
function push(count: number) {
  for (let i = 0; i < count; i++) task.steps.push(SAMPLES[n++ % SAMPLES.length]);
  task.stepIndex = task.steps.length - 1;
  ticker.sync(task);
  kick();
}


// Mirrors the island: the loop only runs while something says it is busy.
let running = false;
let stall = false;
function kick() {
  if (running) return;
  running = true;
  requestAnimationFrame(frame);
}
function frame(now: number) {
  ticker.tick(now);
  if (!stall && ticker.animating) requestAnimationFrame(frame);
  else running = false;
}

push(1);

// Manual clock for a hidden tab, where requestAnimationFrame never fires.
Object.assign(window, { ticker, push });

document.getElementById("one")!.onclick = () => push(1);
document.getElementById("burst")!.onclick = () => push(5);
document.getElementById("reset")!.onclick = () => {
  task.steps = [];
  task.stepIndex = 0;
  n = 0;
  ticker.sync(task);
  push(1);
};
document.getElementById("stall")!.onclick = () => {
  stall = true;
  push(1);
  setTimeout(() => (stall = false), 50);
};
