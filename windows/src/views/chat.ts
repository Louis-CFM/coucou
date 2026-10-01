// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext, type OpencodeCommand, type OpencodeSession } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  return h("div", { class: "chat-row" }, h("div", { class: "reply", text: message.content }));
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file). */
function contextChip(label: string): HTMLElement {
  const chip = h("div", { class: "chip" }, h("i", { class: "chip-dot" }), h("span", { text: label }));
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, send);

  // Which opencode session this conversation is aimed at. Null = a fresh one,
  // which is the default so the mascot never hijacks a session by surprise.
  let targetSession: OpencodeSession | null = null;
  const sessionChip = h("button", { class: "chat-session", title: "Choose a session" });
  chipRow.append(sessionChip);

  // `/`-menu commands from the running opencode, plus the session list. Both are
  // fetched once per island open: the server only exists while opencode runs.
  let commands: OpencodeCommand[] = [];
  let sessions: OpencodeSession[] = [];
  // The in-flight fetch, so concurrent callers await the same request instead of
  // each starting their own and racing the first result.
  let fetching: Promise<void> | null = null;

  const menu = h("div", { class: "chat-menu" });
  const picker = h("div", { class: "chat-picker" });
  let menuRows: HTMLElement[] = [];
  let pickerRows: HTMLElement[] = [];
  let menuActive = -1;

  function closePopups() {
    menu.remove();
    picker.remove();
    // Emptied, not just detached. The menu element is built once and reused, so
    // removing it from the page leaves its rows as children — the next render then
    // appends to them and the previous list stays on screen underneath. That is
    // why typing after a bare "/" appeared to do nothing: the full list from the
    // first render was still sitting there.
    clear(menu);
    clear(picker);
    menuRows = [];
    pickerRows = [];
    menuActive = -1;
  }

  /** Resolves only once `commands`/`sessions` are populated, so callers can
   *  read them straight after awaiting instead of re-checking a stale length. */
  async function fetchOnce() {
    if (!fetching) {
      fetching = (async () => {
        try {
          const [cmds, sess] = await Promise.all([Bridge.opencodeCommands(), Bridge.opencodeSessions()]);
          commands = cmds ?? [];
          sessions = sess ?? [];
          renderSessionChip();
        } catch {
          commands = [];
          sessions = [];
        }
      })();
    }
    await fetching;
    // An empty result is nearly always a server that was still starting rather
    // than a real answer, so forget it: the next attempt asks again instead of
    // leaving the `/` menu empty for the rest of this island session.
    if (commands.length === 0) fetching = null;
  }

  /** Swaps the chat window onto a different conversation.
   *
   *  Picking a session shows what was already said in it, so the window opens on
   *  that conversation rather than blank. Going back to "New chat" clears it, and
   *  either way the log is re-rendered from scratch by forcing the cached render
   *  count out of date. */
  async function showConversation(messages: { role: string; text: string }[]) {
    State.chatHistory = messages.map((m) => ({
      id: nextId++,
      role: m.role === "user" ? "user" : "assistant",
      content: m.text,
    }));
    renderedCount = -1;
    State.notify();
  }

  /** Points the chat at a session and fills the window with its history. */
  async function openSession(s: OpencodeSession) {
    targetSession = s;
    renderSessionChip();
    closePopups();
    input.focus();
    try {
      await showConversation((await Bridge.opencodeSessionMessages(s.id)) ?? []);
    } catch {
      // A session whose history cannot be read is still perfectly usable for new
      // messages, so start it empty rather than refusing to open it.
      await showConversation([]);
    }
  }

  function renderSessionChip() {
    const label = targetSession
      ? targetSession.title.length > 28
        ? `${targetSession.title.slice(0, 28)}…`
        : targetSession.title
      : "New chat";
    clear(sessionChip);
    sessionChip.append(h("span", { text: label }));
    if (targetSession) {
      sessionChip.append(
        h("span", {
          class: "chat-session-x",
          text: "×",
          onclick: (e: Event) => {
            e.stopPropagation();
            targetSession = null;
            renderSessionChip();
            closePopups();
            void showConversation([]);
          },
        }),
      );
    }
    sessionChip.classList.toggle("on", targetSession !== null);
  }

  /** Deletes a session and drops it from the list and from the active target. */
async function removeSession(s: OpencodeSession, row: HTMLElement) {
    try {
      await Bridge.opencodeDeleteSession(s.id);
    } catch (err) {
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      State.notify();
      closePopups();
      return;
    }
    sessions = sessions.filter((x) => x.id !== s.id);
    if (targetSession?.id === s.id) {
      targetSession = null;
      renderSessionChip();
    }
    row.remove();
    State.notify();
  }

  async function openPicker() {
    await fetchOnce();
    if (pickerRows.length) {
      closePopups();
      return;
    }
    closePopups();
    if (sessions.length === 0) return;
    for (const s of sessions) {
      const label = h("span", { class: "chat-menu-name", text: s.title || "Untitled session" });
      const dir = h("span", {
        class: "chat-menu-desc",
        text: s.directory.split(/[\\/]/).filter(Boolean).slice(-1)[0] ?? "",
      });
      const row = h("div", { class: "chat-menu-row pick-row" }, label, dir);

      // Deleting is destructive and easy to mis-tap on a small row, so the
      // button turns into an explicit "sure?" and only then does anything.
      const trash = h(
        "button",
        {
          class: "chat-row-trash",
          title: "Delete this session",
          onclick: (e: Event) => {
            e.stopPropagation();
            if (trash.dataset.armed === "1") {
              void removeSession(s, row);
              return;
            }
            trash.dataset.armed = "1";
            trash.classList.add("armed");
            trash.textContent = "Sure?";
          },
        },
        svg(ICONS.trash, 12),
      );
      row.addEventListener("mouseleave", () => {
        trash.dataset.armed = "0";
        trash.classList.remove("armed");
        clear(trash);
        trash.append(svg(ICONS.trash, 12));
      });
      row.addEventListener("click", () => {
        void openSession(s);
      });
      row.append(trash);
      pickerRows.push(row);
      picker.append(row);
    }
    el.querySelector(".chat-body")?.append(picker);
  }

  /** What the menu filters on: the text after the leading slash, up to any space. */
function typedCommand(): string {
    return input.value.replace(/^\/+/, "").split(/\s/)[0].toLowerCase();
  }

  /** Rebuilds the `/` menu from what has been typed so far.
   *
   *  Runs on every keystroke, so it narrows the list rather than re-opening it.
   *  Treating an already-open menu as a toggle made `/ses` flicker shut and open
   *  instead of filtering down to the session commands. */
  function renderMenu() {
    const typed = typedCommand();
    const starts = commands.filter((c) => c.name.toLowerCase().startsWith(typed));
    // Nothing starts with it, so fall back to a substring match: a name typed out
    // in full, or a fragment from the middle of one, still finds its command.
    const matches = starts.length
      ? starts
      : commands.filter((c) => c.name.toLowerCase().includes(typed));
    // No match at all: show nothing rather than a list left over from the
    // previous keystroke.
    if (matches.length === 0) {
      closePopups();
      return;
    }
    closePopups();
    menuActive = 0;
    // Every match is listed — the popup scrolls rather than hiding commands the
    // user has installed. The list is small (one entry per installed command).
    for (const [i, c] of matches.entries()) {
      const row = h(
        "button",
        {
          class: i === 0 ? "chat-menu-row first" : "chat-menu-row",
          onclick: () => complete(c.name),
        },
        h("span", { class: "chat-menu-name", text: `/${c.name}` }),
        h("span", { class: "chat-menu-desc", text: c.description.slice(0, 60) }),
      );
      menuRows.push(row);
      menu.append(row);
    }
    el.querySelector(".chat-body")?.append(menu);
  }

  function complete(name: string) {
    input.value = `/${name} `;
    closePopups();
    input.focus();
  }

  function moveMenu(delta: number) {
    if (menuRows.length === 0) return;
    menuActive = (menuActive + delta + menuRows.length) % menuRows.length;
    menuRows.forEach((r, i) => r.classList.toggle("first", i === menuActive));
    menuRows[menuActive]?.scrollIntoView({ block: "nearest" });
  }

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  sessionChip.addEventListener("click", () => void openPicker());
  // Both events, not just `input`. `input` is the right signal, but it does not
  // fire for every route a character can take into a field — an IME commit or a
  // paste handled outside the normal path both leave it silent — and a popup that
  // only re-renders on `input` then sits on a stale list.
  const onTyped = () => {
    if (input.value.startsWith("/")) {
      // Filter straight away from whatever commands are already in hand, then top
      // the list up. Awaiting the fetch first meant every keystroke queued behind
      // one pending request, so the popup stayed frozen on whatever was typed when
      // that request happened to start — the full list, from the lone "/".
      renderMenu();
      void fetchOnce().then(() => renderMenu());
    } else if (menuRows.length) closePopups();
  };
  input.addEventListener("input", onTyped);
  input.addEventListener("keyup", onTyped);

  let sending = false;
  let renderedCount = -1;
  // Messages typed while a turn is still running wait here and go out as soon
  // as it finishes, so the input never locks up mid-answer.
  const queue: string[] = [];

async function submit() {
      const query = input.value.trim();
      if (!query) return;
      input.value = "";
      closePopups();
      // `/sessions` is handled here rather than sent: the backend can only reply
      // with text saying "pick a session", which is a dead end. Opening the
      // picker in the mascot is the whole point of the command.
      if (/^\/sessions(\s|$)/i.test(query)) {
        void openPicker();
        return;
      }
      if (sending) {
      queue.push(query);
      State.chatHistory.push({ id: nextId++, role: "user", content: query });
      State.notify();
      onHeightChange();
      return;
    }
    await run(query);
  }

  async function run(query: string) {
    sending = true;
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context, targetSession?.id ?? null);
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      State.notify();
      onHeightChange();
      input.focus();
      // Drain one queued message; `run` re-enters with sending already false.
      const next = queue.shift();
      if (next) void run(next);
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (menuRows.length > 0) {
      if (key === "ArrowDown") {
        e.preventDefault();
        moveMenu(1);
        return;
      }
      if (key === "ArrowUp") {
        e.preventDefault();
        moveMenu(-1);
        return;
      }
      if (key === "Tab" || (key === "Enter" && menuActive >= 0)) {
        e.preventDefault();
        const name = menuRows[menuActive]?.querySelector(".chat-menu-name")?.textContent ?? "";
        complete(name.replace(/^\//, ""));
        return;
      }
      if (key === "Escape") {
        e.preventDefault();
        closePopups();
        return;
      }
    }
    if (key === "Enter") {
      e.preventDefault();
      void submit();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        chipRow.append(sessionChip);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      input.placeholder = sending
        ? "Type your next message…"
        : State.chatHistory.length === 0
          ? "Ask me anything… / for commands"
          : "Continue…";
      // The input stays usable during a turn; `submit` queues what is typed.
    },
    focus() {
      void fetchOnce();
      renderSessionChip();
      input.focus();
      input.select();
    },
  };
}
