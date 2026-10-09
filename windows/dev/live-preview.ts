// The island's live activities (volume, brightness, battery) in a real island.
// `npm run dev`, then open /dev/live-preview.html. Not shipped in the app.

import "../src/style.css";
import { Island } from "../src/island/island";
import { showLive, type LiveEvent } from "../src/island/live";

const island = new Island(document.getElementById("root")!);
const host = { peek: (ms: number) => island.peekLive(ms), resize: () => island.liveResized() };
let volume = 0.5;

const samples: [string, () => LiveEvent][] = [
  ["Volume +", () => ({ kind: "volume", level: (volume = Math.min(1, volume + 0.02)), muted: false, charging: false, text: "" })],
  ["Volume −", () => ({ kind: "volume", level: (volume = Math.max(0, volume - 0.02)), muted: false, charging: false, text: "" })],
  ["Mute", () => ({ kind: "volume", level: volume, muted: true, charging: false, text: "" })],
  ["Brightness 70", () => ({ kind: "brightness", level: 0.7, muted: false, charging: false, text: "" })],
  ["Charging 54", () => ({ kind: "battery", level: 0.54, muted: false, charging: true, text: "Charging" })],
  ["Low battery", () => ({ kind: "battery", level: 0.1, muted: false, charging: false, text: "Low battery" })],
];
const buttons = document.getElementById("buttons")!;
for (const [label, make] of samples) {
  const b = document.createElement("button");
  b.textContent = label;
  b.onclick = () => showLive(host, make());
  buttons.append(b);
}
const open = document.createElement("button");
open.textContent = "Open island";
open.onclick = () => island.alert("overview");
buttons.append(open);
