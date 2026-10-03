// Dev harness: the Ask view split with Mochi's session menu, closed and open,
// on sample data with Bridge stubbed out. Not part of the app bundle.

import "../src/style.css";
import { Bridge, type SessionInfo } from "../src/core/bridge";
import { State } from "../src/core/state";
import { buildPrompt } from "../src/views/chat";
import { botPosition, chatPromptHeight } from "../src/core/layout";

const ago = (min: number) => Date.now() - min * 60_000;
const sessions: SessionInfo[] = [
  { id: "11111111-1111-1111-1111-111111111111", cwd: "/home/me/web-app", title: "Fix the login redirect loop", updated: ago(3) },
  { id: "22222222-2222-2222-2222-222222222222", cwd: "/home/me/api", title: "Add pagination to /orders", updated: ago(55) },
  { id: "33333333-3333-3333-3333-333333333333", cwd: "/mnt/c/Users/me/AppData/Local/Coucou/inbox", title: "Summarise the Q3 report", updated: ago(60 * 26) },
  { id: "44444444-4444-4444-4444-444444444444", cwd: "/home/me/docs", title: "Rewrite the install guide for Windows users", updated: ago(60 * 24 * 4) },
];
Object.assign(Bridge, {
  sessionsList: async () => sessions,
  sessionActive: async () => ({ backend: "wsl:Ubuntu", id: sessions[0].id, cwd: sessions[0].cwd }),
});
State.settings.chatBackend = "wsl:Ubuntu";
State.sessions = sessions;
State.activeSession = { backend: "wsl:Ubuntu", id: sessions[0].id, cwd: sessions[0].cwd };
State.chatHistory = [
  { id: 1, role: "user", content: "Why does the login page keep redirecting to itself?" },
  { id: 2, role: "assistant", content: "The auth guard runs before the session cookie is read, so every visit looks anonymous and gets sent back to /login. Reading the cookie in the middleware first fixes it." },
  { id: 3, role: "user", content: "Where is that middleware?" },
];

for (const step of ["closed", "open", "armed"]) {
  const view = buildPrompt(() => {});
  view.el.classList.add("on");
  // The island's own geometry: views sit under the 34 px header, inside the
  // #content padding; the disc is where botPosition() puts Mochi.
  const islandH = chatPromptHeight(step === "closed" ? State.chatHistory.length : Infinity);
  const frame = document.createElement("div");
  frame.className = "frame";
  frame.style.height = `${islandH}px`;
  const views = document.createElement("div");
  views.style.cssText = `position:absolute;left:10px;right:10px;top:42px;bottom:10px`;
  views.append(view.el);
  const p = botPosition("expanded", "prompt", islandH, 0, true);
  const mochi = document.createElement("div");
  mochi.style.cssText = `position:absolute;left:${p.cx - p.diameter / 2}px;top:${p.cy - p.diameter / 2}px;width:${p.diameter}px;height:${p.diameter}px;border-radius:50%;background:#f5f6f8;z-index:5`;
  frame.append(views, mochi);
  document.body.append(frame);
  view.sync();
  if (step !== "closed") {
    (view.el.querySelector(".sess-trigger") as HTMLElement).click();
    if (step === "armed") {
      setTimeout(() => (view.el.querySelectorAll(".sess-del")[1] as HTMLElement).click(), 50);
    }
  }
}
