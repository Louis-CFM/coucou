// Mochi's room in the real Coucou window (src/settings/main.ts), on made-up
// data: the island's snapshot, the recap's history and the keys are answered
// by the Tauri stand-in. See room-preview.html for the query. Not shipped.

import type { RoomSnapshot } from "../src/core/room";

const q = new URLSearchParams(location.search);
const mochi = q.get("mochi") ?? "idle";
const weather = q.get("weather") ?? "sun";
const night = q.get("night") === "1";

const now = new Date();
now.setHours(night ? 22 : 14, 9, 30);
const at = (daysAgo: number, hour: number) => {
  const d = new Date(now);
  d.setDate(d.getDate() - daysAgo);
  d.setHours(hour, 0, 0, 0);
  return d.getTime() / 1000;
};
// Nine days in a row (a flower), and 2 h 14 coded today.
const turns = Array.from({ length: 9 }, (_, i) => ({
  agent: "claude", project: "site", start: at(i, 9), end: at(i, 9) + (i === 0 ? 134 * 60 : 3600),
  filesChanged: 0, linesAdded: 0, linesRemoved: 0, commandsRun: 0, questions: 0,
}));
const decisions = [
  ...Array.from({ length: 12 }, () => ({ agent: "claude", date: at(0, 10), decision: "allow" })),
  { agent: "claude", date: at(0, 11), decision: "deny" },
];

localStorage.setItem("mochiRoomEnabled", "true");
(window as any).__answers = {
  hub_shown: true,
  secret_present: true,
  recap_history: { turns, decisions, prefs: { enabled: true, hideProjects: false, lastShownWeek: "" } },
};
await import("./tauri-mock.ts");
const { setRoomClock } = await import("../src/hub/pages/room");
setRoomClock(() => {
  const d = new Date();
  d.setHours(now.getHours());
  return d;
});
await import("../src/settings/main.ts");

const ms = (hour: number) => {
  const d = new Date(now);
  d.setHours(hour, 0, 0, 0);
  return d.getTime();
};
const ci = { sun: ["success"], cloudy: ["pending"], rain: ["failure"], storm: ["success"], clear: [] }[weather] ?? [];
const deploy = weather === "storm" ? "ERROR" : "READY";
const snap: RoomSnapshot = {
  busy: mochi === "working",
  focusState: mochi === "working" ? "working" : "idle",
  approval: mochi === "asking" || mochi === "question"
    ? {
      requestId: "r1", pillId: "integration_claude", asker: "my-app", tool: "Bash",
      command: mochi === "asking" ? "npm run deploy -- --prod" : "", question: mochi === "question", queued: mochi === "asking" ? 1 : 0,
    }
    : null,
  stripe: { currency: "eur", payments: [{ amount: 4900, createdAt: ms(9), succeeded: true }, { amount: 3500, createdAt: ms(11), succeeded: true }] },
  github: weather === "clear" ? null : { stars: 1234, ci },
  vercel: weather === "clear" ? null : [
    { state: deploy, createdAt: ms(12), project: "coucou-site" },
    { state: "READY", createdAt: ms(10), project: "coucou-site" },
  ],
  n8n: { workflow: "Daily digest", success: true },
  calcom: [ms(night ? 23 : 16)],
};

const w = window as any;
setTimeout(() => {
  w.__emit("hub-page", "room");
  setTimeout(() => w.__emit("room-state", snap), 400);
}, 300);
