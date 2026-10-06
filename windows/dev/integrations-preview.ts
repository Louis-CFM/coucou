// Dev harness: the overview with fake GitHub and Google Calendar data, so the
// cards can be checked (and screenshotted) without tokens or a live session.
// Not part of the app bundle.

import "../src/style.css";
import { State } from "../src/core/state";
import { h } from "../src/views/dom";
import { buildViews, type ViewActions } from "../src/views/views";
import { tickMiniBots } from "../src/mochi/minibots";

const noop = () => {};
const actions: ViewActions = {
  setView: noop, collapse: noop, setFocus: (id) => State.setFocus(id), openTerminal: noop,
  openTarget: noop, openUrl: noop, decide: noop, toggleSound: noop, setVolume: noop,
  setAutoClose: noop, openSettingsWindow: noop, blip: noop,
};

State.settings.activeIntegrations = ["integration_github", "integration_gcal", "integration_vercel"];
State.loadIntegrationTasks();

const views = buildViews(actions, noop);
const overview = views.get("overview")!;
const reminderView = views.get("reminder")!;
overview.el.classList.add("on");
const viewsEl = h("div", { id: "views" }, overview.el, reminderView.el);
document.getElementById("stage")!.append(viewsEl);

/** Which of the two views the stage shows. */
function show(which: "overview" | "reminder") {
  overview.el.classList.toggle("on", which === "overview");
  reminderView.el.classList.toggle("on", which === "reminder");
}

const min = 60_000;
const now = Date.now();
const at = (offsetMin: number, lengthMin = 30) => ({
  startMs: now + offsetMin * min,
  endMs: now + (offsetMin + lengthMin) * min,
  start: new Date(now + offsetMin * min).toISOString(),
});

const loaded = (data: Record<string, unknown>, error: string | null = null) => ({
  data, error, loaded: true, configured: true,
});

const GITHUB_BASE = { login: "jhoan", totalRepos: 14, totalStars: 37 };

const scenarios: Record<string, () => void> = {
  "GitHub · CI failing": () => {
    State.integrations.integration_github = loaded({
      ...GITHUB_BASE,
      branch: { repo: "Louis-CFM/coucou", branch: "feat/windows-github-ci-calendar", pushed: true, state: "FAILURE", failing: ["build-windows"], url: "", pr: 8 },
      requests: [{ repo: "Louis-CFM/coucou", number: 9, title: "Mac: approval view polish", url: "", author: "louis" }],
      pulls: [
        { repo: "Louis-CFM/coucou", number: 8, title: "Windows: GitHub CI and Calendar", url: "", draft: false, decision: null },
        { repo: "Louis-CFM/coucou", number: 7, title: "Windows: fix wake strip", url: "", draft: false, decision: "APPROVED" },
      ],
    });
    State.setFocus("integration_github");
  },
  "GitHub · running": () => {
    State.integrations.integration_github = loaded({
      ...GITHUB_BASE,
      branch: { repo: "Louis-CFM/coucou", branch: "fix/windows-wake-strip", pushed: true, state: "PENDING", failing: [], url: "", pr: 7 },
      requests: [],
      pulls: [
        { repo: "Louis-CFM/coucou", number: 7, title: "Windows: fix wake strip", url: "", draft: false, decision: "CHANGES_REQUESTED" },
        { repo: "jhoan/dotfiles", number: 3, title: "Add PowerShell profile", url: "", draft: true, decision: null },
      ],
    });
    State.setFocus("integration_github");
  },
  "GitHub · passing, no PR": () => {
    State.integrations.integration_github = loaded({
      ...GITHUB_BASE,
      branch: { repo: "Louis-CFM/coucou", branch: "main", pushed: true, state: "SUCCESS", failing: [], url: "", pr: null },
      requests: [], pulls: [],
    });
    State.setFocus("integration_github");
  },
  "GitHub · nothing on": () => {
    State.integrations.integration_github = loaded({ ...GITHUB_BASE, branch: null, requests: [], pulls: [] });
    State.setFocus("integration_github");
  },
  "Calendar · meeting in 4 min": () => {
    State.integrations.integration_gcal = loaded({
      events: [
        { id: "a", title: "Daily standup", ...at(4, 15), allDay: false, meetUrl: "https://meet.google.com/x", url: "" },
        { id: "b", title: "1:1 with Louis", ...at(95), allDay: false, meetUrl: null, url: "" },
        { id: "c", title: "Release Coucou 0.2", ...at(60 * 24 * 2), allDay: false, meetUrl: null, url: "" },
        { id: "d", title: "Holiday", start: "2026-10-12", startMs: null, endMs: null, allDay: true, url: "" },
      ],
    });
    State.setFocus("integration_gcal");
  },
  "Calendar · in a meeting": () => {
    State.integrations.integration_gcal = loaded({
      events: [
        { id: "a", title: "Design review — notch island", ...at(-10, 45), allDay: false, meetUrl: "https://meet.google.com/x", url: "" },
        { id: "b", title: "Lunch", ...at(50, 60), allDay: false, meetUrl: null, url: "" },
      ],
    });
    State.setFocus("integration_gcal");
  },
  "Calendar · empty": () => {
    State.integrations.integration_gcal = loaded({ events: [] });
    State.setFocus("integration_gcal");
  },
  "Calendar · not connected": () => {
    State.integrations.integration_gcal = { data: {}, error: null, loaded: true, configured: false };
    State.setFocus("integration_gcal");
  },
  "Calendar · sign-in expired": () => {
    State.integrations.integration_gcal = { data: {}, error: "Google sign-in expired — reconnect in Settings", loaded: false, configured: true };
    State.setFocus("integration_gcal");
  },
  "Reminder · casino, 30 min": () => {
    State.reminder = {
      id: "poker", title: "THE ONE BOUNTY", ...at(30, 240), allDay: false, meetUrl: null, url: "https://calendar.google.com",
      color: "#9fe1e7", calendar: "casino Zaragoza",
      location: "Casino Zaragoza, C/ Marqués de Casa Jiménez, 11, Zaragoza, 50004, Spain",
    };
    show("reminder");
  },
  "Reminder · video call, 2 min": () => {
    State.reminder = {
      id: "standup", title: "Daily standup with a much longer title than fits", ...at(2, 15), allDay: false,
      meetUrl: "https://meet.google.com/x", url: "https://calendar.google.com", color: "#16a765", calendar: "jhoang956@gmail.com",
      location: null,
    };
    show("reminder");
  },
  "Badges: review asked + meeting": () => {
    State.setFocus("integration_vercel");
    State.setPillBadge("integration_github", "approval");
    State.setPillBadge("integration_gcal", "approval");
  },
};

const controls = document.getElementById("controls")!;
const caption = document.getElementById("caption")!;
for (const [name, run] of Object.entries(scenarios)) {
  controls.append(h("button", {
    text: name,
    onclick: () => {
      for (const t of State.tasks) t.pillBadge = null;
      show("overview");
      run();
      caption.textContent = name;
      State.notify();
    },
  }));
}

State.subscribe(() => {
  overview.sync();
  reminderView.sync();
});
scenarios["GitHub · CI failing"]();
caption.textContent = "GitHub · CI failing";
State.notify();

let last = performance.now();
function loop(t: number) {
  tickMiniBots((t - last) / 1000);
  last = t;
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
