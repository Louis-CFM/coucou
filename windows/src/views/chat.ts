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
  /** Which picker row is highlighted. Separate from `menuActive` so the two lists
   *  cannot move each other. */
  let pickerActive = -1;
  // Whether the session picker has already asked for a second look. Reset once a
  // real list arrives, so a later empty answer gets its one retry too.
  let retriedForSessions = false;
  // When the last fetch started, so an empty answer cannot trigger another one on
  // every keystroke.
  let lastFetchAt = 0;
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
    pickerActive = -1;
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
    //
    // Both lists have to be part of that test. The commands and the sessions come
    // from the same server, but they are populated at different moments, so a
    // server that answered the command list early still reports no sessions.
    // Caching on `commands` alone left `/sessions` permanently empty after that.
    //
    // But forgetting it on *every* call turns this into a refetch per keystroke
    // whenever the user simply has no sessions, which is its own kind of broken.
    // The cooldown is the backstop: one retry, then the answer stands.
    const now = performance.now();
    if (
      (commands.length === 0 || sessions.length === 0)
      && now - lastFetchAt > FETCH_RETRY_MS
    ) {
      lastFetchAt = now;
      fetching = null;
    }
  }

  /** How long before an empty answer is worth asking again. */
  const FETCH_RETRY_MS = 1500;

  /** Swaps the chat window onto a different conversation.
   *
   *  Picking a session shows what was already said in it, so the window opens on
   *  that conversation rather than blank. Going back to "New chat" clears it, and
   *  either way the log is rebuilt from scratch by flagging it dirty. */
  async function showConversation(messages: { role: string; text: string }[]) {
    State.chatHistory = messages.map((m) => ({
      id: nextId++,
      role: m.role === "user" ? "user" : "assistant",
      content: m.text,
    }));
    historyDirty = true;
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

  async function openModelPicker() {
    closePopups();
    const found = (await Bridge.opencodeModels()) ?? [];
    if (!found.length) {
      State.noteMessage = "No models reported by the server.";
      State.view = "note";
      return;
    }
    for (const [i, model] of found.entries()) {
      // Split so the provider reads as secondary, which is what it is.
      const slash = model.indexOf("/");
      const row = h(
        "div",
        // Not `first` on every row: that class is what paints the selection, so a
        // hardcoded one lit the whole list up.
        { class: i === 0 ? "chat-menu-row pick-row first" : "chat-menu-row pick-row" },
        h("span", { class: "chat-menu-name", text: slash >= 0 ? model.slice(slash + 1) : model }),
        h("span", { class: "chat-menu-desc", text: slash >= 0 ? model.slice(0, slash) : "" }),
      );
      row.addEventListener("click", () => {
        closePopups();
        State.modelOverride = model;
        State.noteMessage = `Model set to ${model}.`;
        State.view = "note";
        State.notify();
      });
      pickerRows.push(row);
      picker.append(row);
    }
    // First row pre-highlighted so it reads as selectable, but `pickerActive` stays
    // -1 until an arrow key is pressed: Enter should not silently pick the first
    // session or model over the one you were aiming at.
    pickerRows[0]?.classList.add("first");
    el.querySelector(".chat-body")?.append(picker);
  }

  async function openPicker() {
    await fetchOnce();
    if (pickerRows.length) {
      closePopups();
      return;
    }
    closePopups();
    if (sessions.length === 0) {
      // A server that is still starting reports no sessions, and returning here
      // without drawing anything is what made the command look dead on first use.
      // So draw the popup with a line saying so — and ask again exactly once. An
      // unbounded retry loops as fast as the server can answer, which backs every
      // later request up behind it; that is what stopped the command list loading
      // at all while this was in.
      const retried = retriedForSessions;
      const waiting = h(
        "div",
        { class: "chat-menu-row pick-row" },
        h(
          "span",
          { class: "chat-menu-name", text: retried ? "No sessions found." : "Loading sessions…" },
        ),
      );
      picker.append(waiting);
      pickerRows.push(waiting);
      el.querySelector(".chat-body")?.append(picker);
      if (!retried) {
        retriedForSessions = true;
        void fetchOnce().then(() => {
          closePopups();
          void openPicker();
        });
      }
      return;
    }
    retriedForSessions = false;
    for (const [i, s] of sessions.entries()) {
      const label = h("span", { class: "chat-menu-name", text: s.title || "Untitled session" });
      const dir = h("span", {
        class: "chat-menu-desc",
        text: s.directory.split(/[\\/]/).filter(Boolean).slice(-1)[0] ?? "",
      });
      const row = h(
        "div",
        { class: i === 0 ? "chat-menu-row pick-row first" : "chat-menu-row pick-row" },
        label,
        dir,
      );

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
    pickerRows[0]?.classList.add("first");
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
      // A div, not a button. A button takes focus when it is clicked, and the input
      // then stops receiving arrow keys -- so the first click on a command left the
      // dropdown open with the keyboard dead. A plain row cannot steal focus, and
      // the click still works.
      const row = h(
        "div",
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

  /** Same movement for the session and model pickers, which are a separate list.
   *  They had no keyboard handling at all, so the command menu was navigable and
   *  the two drop-downs a command opens were not. */
  function movePicker(delta: number) {
    if (pickerRows.length === 0) return;
    pickerActive = (pickerActive + delta + pickerRows.length) % pickerRows.length;
    pickerRows.forEach((r, i) => r.classList.toggle("first", i === pickerActive));
    pickerRows[pickerActive]?.scrollIntoView({ block: "nearest" });
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
const NAV_KEYS = new Set(["ArrowDown", "ArrowUp", "Tab", "Enter", "Escape"]);
    input.addEventListener("input", onTyped);
    // Arrow keys move the selection on `keydown`, so letting the matching `keyup`
    // through here re-rendered the menu and reset the highlight to the first row —
    // the list visibly bounced back on every press. Only keys that can change the
    // text are allowed to re-render.
    input.addEventListener("keyup", (e) => {
      if (!NAV_KEYS.has((e as KeyboardEvent).key)) onTyped();
    });

  let sending = false;
  // When Escape will cancel, rather than already having cancelled. Cleared once it
  // lapses so a stray second press much later does not cancel out of nowhere.
  let armedUntil = 0;
  // Which view this pane lives in, captured while it is mounted. The Escape prompt
  // swaps to the note view, so returning needs to know where it came from.
  // Which view the chat belongs to. Recorded while the pane is on screen rather
  // than when it is built: building happens once at startup, long before the user
  // is anywhere near the chat, so the value captured then was some other view
  // entirely and returning to it landed on a broken screen.
  let chatView = State.view;
  // Whether this pane is the one on screen. Set by `sync`, and deliberately left
  // true across the prompt's unmount so the cancel survives it.
  let chatMounted = false;
  // Only the tail of the conversation is in the DOM. The island rewrites its width
  // every frame while it retracts, and that re-wraps the text of every bubble inside
  // it, so the cost of the animation is proportional to the whole conversation. With
  // a few hundred messages the retraction crawled. Older messages come back as the
  // log is scrolled up; `State.chatHistory` always holds all of them either way.
  const RENDER_WINDOW = 20;
  // How many messages, counted back from the newest, are loaded.
  let expandedTo = RENDER_WINDOW;
  // The slice of history currently in the log: [renderedFrom, renderedTo).
  let renderedFrom = 0;
  let renderedTo = 0;
  // Set when the log holds a different conversation, so the next sync starts over.
  let historyDirty = true;
  // Writing scrollTop fires a scroll event afterwards, asynchronously, so a flag
  // cleared synchronously would not be set by the time it arrives. The time is what
  // separates a load the renderer just did from the reader reaching the top again.
  let loadedAt = 0;
  // The typing dots are tracked apart from the message count. They used to be
  // folded into it as a half, which meant showing or hiding them re-rendered the
  // whole conversation.
  let typingEl: HTMLElement | null = null;

  /** The first row with any part of itself above the top of the log, if any. */
  function firstVisibleRow(): HTMLElement | null {
    for (const child of Array.from(log.children)) {
      if (child instanceof HTMLElement && child.offsetTop + child.offsetHeight > log.scrollTop) {
        return child;
      }
    }
    return null;
  }

  /** Widens the window by another screenful, leaving the reader's place untouched. */
  function loadEarlier() {
    const total = State.chatHistory.length;
    if (expandedTo >= total) return;
    expandedTo = Math.min(total, expandedTo + RENDER_WINDOW);
    loadedAt = performance.now();
    State.notify();
  }
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
      // `/models` opens a picker for the same reason: the reply is a wall of text
      // that cannot be chosen from, which is a dead end in a 640pt island.
      if (/^\/models(\s|$)/i.test(query)) {
        void openModelPicker();
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
      const reply = await Bridge.chatSend(
      query,
      context,
      targetSession?.id ?? null,
      State.modelOverride,
    );
      // A cancelled turn still resolves with whatever had arrived, which would
      // leave a half-reply on screen as if it had been answered.
      if (armedUntil) {
        State.chatHistory.push({
          id: nextId++,
          role: "assistant",
          content: "Cancelled.",
        });
      } else {
        State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
        Sound.play("finish");
      }
      armedUntil = 0;
      State.chatHint = null;
      State.stateOverride = null;
    } catch (err) {
      State.stateOverride = null;
      // A cancelled turn surfaces as an error from the server call. That is the
      // user pressing Escape, not a failure, so it belongs in the log as a
      // cancelled reply rather than on the error view.
      if (armedUntil || /cancelled/i.test(String(err))) {
        State.chatHistory.push({ id: nextId++, role: "assistant", content: "Cancelled." });
        armedUntil = 0;
        State.escapeArmed = false;
        State.view = chatView;
        State.notify();
      } else {
        State.noteMessage = String(err).replace(/^Error:\s*/, "");
        State.view = "note";
        Sound.play("error");
      }
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

  // Reaching the top of the log pulls in the messages above it, the way a feed does.
// There is no button: the window is only ever short by what the reader has not
// scrolled back to yet. The 250ms guard is what stops the correction the renderer
// makes just after loading from counting as the reader hitting the top again.
  log.addEventListener("scroll", () => {
    if (log.scrollTop > 8) return;
    if (performance.now() - loadedAt < 250) return;
    loadEarlier();
  });

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
      const highlighted = menuRows[menuActive]?.querySelector(".chat-menu-name")?.textContent ?? "";
      const chosen = highlighted.replace(/^\//, "");
if (key === "Tab") {
        e.preventDefault();
        complete(chosen);
        return;
      }
      if (key === "Enter") {
        e.preventDefault();
        // Enter runs what was typed when it already spells the command out, and
        // only fills it in when it does not. The menu opens on the first
        // character, so it was always open here, and Enter always completed rather
        // than submitted — which is why every command took two presses.
        if (typedCommand() === chosen.toLowerCase()) void submit();
        else complete(chosen);
        return;
      }
      if (key === "Escape") {
        e.preventDefault();
        closePopups();
        return;
      }
    }
    // The session and model pickers, which are a separate list. This has to sit
    // beside the command menu rather than inside it: nested there, the arrows only
    // worked while the command menu happened to be open, and a picker opened by a
    // command is never open at the same time.
    if (pickerRows.length > 0) {
      if (key === "ArrowDown") {
        e.preventDefault();
        movePicker(1);
        return;
      }
      if (key === "ArrowUp") {
        e.preventDefault();
        movePicker(-1);
        return;
      }
      if (key === "Enter" && pickerActive >= 0) {
        // Enter takes the highlighted row, so a session or model can be chosen
        // without reaching for the mouse.
        e.preventDefault();
        pickerRows[pickerActive].click();
        return;
      }
    }
    if (key === "Enter") {
      e.preventDefault();
      void submit();
    }
    if (key === "Escape" && sending) {
      // The island's own Escape handler is on `window` and was registered first, so
      // it runs before any handler here and collapses the panel. Stopping the event
      // at the input is the only way to keep it from reaching the window at all —
      // `stopPropagation` in a sibling window listener would be too late.
      e.stopPropagation();
      e.preventDefault();
      State.escapeArmed = true;
      onEscape();
      return;
    }
  });

  // Arms or fires the cancel. Shared by the input handler and the window handler:
// the input catches the press while the chat is on screen, and the window catches
// the second one after the prompt has swapped the view and unmounted the input.
function onEscape() {
  if (!armedUntil) {
    armedUntil = performance.now() + 3000;
    State.noteMessage = "Press Escape again to cancel this reply.";
    State.view = "note";
    Sound.play("rate");
    // Lapses on its own, so a prompt outliving its turn cannot sit there.
    window.setTimeout(() => {
      if (armedUntil && performance.now() >= armedUntil) {
        armedUntil = 0;
        State.escapeArmed = false;
        State.view = chatView;
        State.notify();
      }
    }, 3100);
  } else {
    armedUntil = 0;
    State.escapeArmed = false;
    State.view = chatView;
    void Bridge.chatCancel(targetSession?.id ?? null);
  }
  State.notify();
}

  // The second press arrives here, on the window, because the prompt unmounted the
  // input. The island's Escape handler shares this target and runs first, so
  // `escapeArmed` is what tells it to stand down.
  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    // A dropdown owns Escape first — closing it is more immediate than arming a
    // cancel, and leaving it open while the panel collapses looked broken.
    if (menuRows.length || pickerRows.length) {
      e.preventDefault();
      e.stopPropagation();
      closePopups();
      return;
    }
    // Only in the chat pane: let the island collapse as it always did otherwise.
    // Deliberately not `el.isConnected` — the prompt swaps to the note view, which
    // unmounts this pane, so that test made the second Escape fall through to the
    // island and collapse the whole panel. `sync` running is the better signal:
    // it stays true after the unmount, which is exactly what the cancel needs.
    if (!chatMounted || !sending) return;
    e.preventDefault();
    e.stopPropagation();
    onEscape();
  });

  // A click anywhere in the chat that is not on a dropdown row dismisses it. The
  // popups are children of the chat body, so without this they survived the click
  // that was meant to dismiss them.
  el.addEventListener("pointerdown", (e) => {
    if (!menuRows.length && !pickerRows.length) return;
    const target = e.target as Node;
    if (menu.contains(target) || picker.contains(target)) return;
    closePopups();
  });

  return {
    el,
    sync() {
      chatMounted = true;
      // Remembered here so the cancel prompt has somewhere correct to return to.
      chatView = State.view;
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        chipRow.append(sessionChip);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const history = State.chatHistory;
      if (historyDirty || history.length < renderedTo) {
        // A different conversation, or one that shrank, cannot be patched.
        clear(log);
        typingEl = null;
        historyDirty = false;
        expandedTo = RENDER_WINDOW;
        renderedFrom = Math.max(0, history.length - expandedTo);
        renderedTo = history.length;
        for (let i = renderedFrom; i < history.length; i++) log.append(bubble(history[i]));
        log.scrollTop = log.scrollHeight;
      } else if (history.length > renderedTo) {
        // Only what arrived since last time.
        for (let i = renderedTo; i < history.length; i++) log.append(bubble(history[i]));
        renderedTo = history.length;
        log.scrollTop = log.scrollHeight;
      } else if (expandedTo > history.length - renderedFrom) {
        // The reader scrolled up, and older messages go in above them. Adding content
        // above pushes everything down, so the message being read has to be put back
        // where it was. The anchor is the first row with any part of itself visible,
        // tracked by how far it sat below the top of the viewport: `scrollHeight` on
        // its own only says how much taller the log got, not where in it the reader
        // was, which is what put them back at the start.
        const anchor = firstVisibleRow();
        const gap = anchor ? anchor.offsetTop - log.scrollTop : 0;
        const from = Math.max(0, history.length - expandedTo);
        const older = document.createDocumentFragment();
        for (let i = from; i < renderedFrom; i++) older.append(bubble(history[i]));
        log.prepend(older);
        renderedFrom = from;
        log.scrollTop = (anchor ? anchor.offsetTop : 0) - gap;
      }

      // The typing dots go in last, so a rebuild above cannot wipe them. They are an
      // element of their own, which is what keeps them appearing and disappearing
      // without touching a single message.
      const thinking = State.stateOverride === "thinking";
      if (thinking) {
        if (!typingEl) {
          typingEl = typingDots();
          log.append(typingEl);
          log.scrollTop = log.scrollHeight;
        }
      } else if (typingEl) {
        typingEl.remove();
        typingEl = null;
      }

      input.placeholder = sending
        ? "Type your next message…"
        : State.chatHistory.length === 0
          ? "Ask me anything… / for commands"
          : "Continue…";
      State.chatHint = null;
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
