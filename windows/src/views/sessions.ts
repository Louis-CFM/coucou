// Mochi's session menu — the left column of the Ask view when Mochi runs on
// the user's own Claude Code (Settings → "Use for Mochi").
//
// It lists every Claude Code session of that Claude Code, terminal ones too.
// Picking one makes it the active session: the conversation on the right shows
// it, and Mochi carries it on (`claude -p --resume`, in the session's folder).
// New sessions start from a dropped file, as before, or in a folder picked
// here. Deleting erases the transcript, so it takes a second click.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { timeAgo } from "./integrations";
import { Bridge, type SessionInfo } from "../core/bridge";
import { State } from "../core/state";

/** The menu exists only with a local Claude Code; the API key has no sessions. */
export const usesSessions = (): boolean => State.settings.chatBackend !== "api";

let messageId = 1_000_000;

function folderName(path: string | null | undefined): string {
  const clean = (path ?? "").replace(/[\\/]+$/, "");
  const i = Math.max(clean.lastIndexOf("/"), clean.lastIndexOf("\\"));
  return i >= 0 ? clean.slice(i + 1) : clean;
}

const message = (err: unknown) => String(err).replace(/^Error:\s*/, "");

/** What the active session is called in the trigger. */
function activeLabel(): { title: string; folder: string } {
  const a = State.activeSession;
  if (a?.id) {
    const s = State.sessions.find((x) => x.id === a.id);
    return { title: s?.title ?? "Session", folder: folderName(a.cwd ?? s?.cwd) };
  }
  if (a?.cwd) return { title: "New session", folder: folderName(a.cwd) };
  if (State.droppedFile) return { title: State.droppedFile.name, folder: "dropped file" };
  return { title: "New session", folder: "inbox" };
}

export interface SessionsPanel {
  el: HTMLElement;
  /** Redraws the trigger; the open menu redraws on its own actions. */
  sync(): void;
  /** Re-reads the session list and the active session from Rust. */
  refresh(): Promise<void>;
  /** Loads the active session's conversation if the chat is still empty. */
  showActive(): Promise<void>;
}

export function buildSessionsPanel(onChange: () => void): SessionsPanel {
  let open = false;
  /** The session waiting for its second click on Delete. */
  let armed: string | null = null;
  let error = "";

  const chevron = svg(ICONS.chevronRight, 9, { stroke: 2.4 });
  const title = h("span", { class: "sess-title" });
  const folder = h("span", { class: "sess-folder" });
  const trigger = h("button", { class: "sess-trigger", title: "Sessions" }, title, folder, chevron);
  const menu = h("div", { class: "sess-menu" });
  const el = h("div", { class: "sessions" }, trigger, menu);

  trigger.addEventListener("click", () => {
    setOpen(!open);
    armed = null;
    drawMenu();
    if (open) void refresh();
  });

  function drawTrigger() {
    const label = activeLabel();
    title.textContent = label.title;
    folder.textContent = label.folder;
    el.classList.toggle("open", open);
  }

  /** Opens or closes the menu; the island grows to make room for the list. */
  function setOpen(next: boolean) {
    if (open === next) return;
    open = next;
    State.sessionsMenuOpen = next;
    onChange();
  }

  function drawMenu() {
    drawTrigger();
    clear(menu);
    menu.style.display = open ? "" : "none";
    if (!open) return;
    menu.append(
      h("button", {
        class: "sess-row sess-new",
        title: "Pick a folder for a new session — or drop a file on Mochi to start one about it",
        onclick: () => void newInFolder(),
      }, h("span", { class: "sess-title", text: "+ New in a folder…" })),
    );
    if (error) menu.append(h("div", { class: "sess-error", text: error }));
    for (const s of State.sessions) menu.append(row(s));
    if (State.sessions.length === 0 && !error) {
      menu.append(h("div", { class: "sess-empty", text: "No sessions yet" }));
    }
  }

  function row(s: SessionInfo): HTMLElement {
    const isArmed = armed === s.id;
    const pick = h("button", { class: "sess-pick", title: s.cwd, onclick: () => void select(s) },
      h("span", { class: "sess-title", text: s.title }),
      h("span", { class: "sess-folder", text: `${folderName(s.cwd)} · ${timeAgo(s.updated)}` }),
    );
    const del = h("button", {
      class: isArmed ? "sess-del armed" : "sess-del",
      title: isArmed ? "Click again to erase this session's transcript" : "Delete this session",
      text: isArmed ? "Delete?" : "",
    });
    if (!isArmed) del.append(svg(ICONS.xmark, 8));
    del.addEventListener("click", (e) => {
      e.stopPropagation();
      void remove(s);
    });
    const on = State.activeSession?.id === s.id;
    return h("div", { class: on ? "sess-row on" : "sess-row" }, pick, del);
  }

  async function refresh() {
    try {
      State.sessions = await Bridge.sessionsList();
      error = "";
    } catch (err) {
      error = message(err);
    }
    State.activeSession = (await Bridge.sessionActive()) ?? null;
    if (open) drawMenu();
    else drawTrigger();
  }

  async function loadHistory(id: string) {
    const items = await Bridge.sessionHistory(id);
    State.chatHistory = items.map((i) => ({ id: messageId++, role: i.role, content: i.text }));
  }

  async function select(s: SessionInfo) {
    try {
      await Bridge.sessionSelect(s.id, s.cwd);
      State.activeSession = { backend: State.settings.chatBackend, id: s.id, cwd: s.cwd };
      // A session brings its own context; a dropped file belongs to a new one.
      State.droppedFile = null;
      State.promptContext = null;
      await loadHistory(s.id);
      error = "";
      setOpen(false);
    } catch (err) {
      error = message(err);
    }
    drawMenu();
    onChange();
  }

  async function newInFolder() {
    try {
      const cwd = await Bridge.sessionNewInFolder();
      if (cwd) {
        State.activeSession = { backend: State.settings.chatBackend, id: null, cwd };
        State.droppedFile = null;
        State.promptContext = null;
        State.chatHistory = [];
        setOpen(false);
      }
      error = "";
    } catch (err) {
      error = message(err);
    }
    drawMenu();
    onChange();
  }

  async function remove(s: SessionInfo) {
    if (armed !== s.id) {
      armed = s.id;
      drawMenu();
      return;
    }
    armed = null;
    try {
      await Bridge.sessionDelete(s.id);
      if (State.activeSession?.id === s.id) {
        State.activeSession = null;
        State.chatHistory = [];
        onChange();
      }
    } catch (err) {
      error = message(err);
    }
    await refresh();
  }

  async function showActive() {
    await refresh();
    const id = State.activeSession?.id;
    if (id && State.chatHistory.length === 0) {
      try {
        await loadHistory(id);
      } catch (err) {
        error = message(err);
      }
      onChange();
    }
  }

  drawMenu();
  return { el, sync: drawTrigger, refresh, showActive };
}
