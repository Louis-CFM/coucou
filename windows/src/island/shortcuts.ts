// Keyboard shortcuts → island. Port of IslandWindowController.handleHotKey and
// handleIslandKey from the macOS app.
//
// Global shortcuts are caught by Rust and arrive as a `shortcut` event with
// the action id (the wardrobe goes out as `open-wardrobe` instead, for the
// wardrobe view to pick up). The in-island keys are read here, while the
// island has the keyboard: it takes it for the chat, and when a global
// shortcut opens it.

import { Bridge, onEvent } from "../core/bridge";
import type { BotEmoteName, IslandViewName } from "../core/layout";
import { cyclePill, islandKeyAction, navigate, pillByNumber, type IslandKeyAction } from "../core/shortcuts";
import { Sound } from "../core/sound";
import { State } from "../core/state";

const CLAUDE_DESKTOP_ID = "agent_claude-desktop";

/** What the shortcuts need from the island. */
export interface ShortcutHost {
  alert(view: IslandViewName): void;
  setView(view: IslandViewName): void;
  collapse(): void;
  emote(name: BotEmoteName): void;
  setPinned(on: boolean): void;
  /** Gives the island the keyboard, so the in-island keys work (Mac: makeKey). */
  takeKeyboard(): void;
  /** The wardrobe from any state, or back if it is open (Island.wardrobeAnywhere). */
  wardrobeAnywhere(): void;
  /** False where Nova can't leave the island (GNOME on Wayland). */
  canLeaveIsland(): boolean;
  /** Nova out to the desktop, or home (DesktopNovaController.flyOutOrHome). */
  flyOutOrHome(): void;
  /** Hands Ctrl+O / Ctrl+E to the view on screen (the Mac posts notifications). */
  viewCommand(command: ViewCommand): void;
}

/** What the open view is asked to do: open the highlighted item, toggle the diff. */
export type ViewCommand = "openSelection" | "toggleDiff";

function focusPill(host: ShortcutHost, id: string | null, open: boolean) {
  if (!id) return;
  State.setFocus(id);
  State.cardSelection = null;
  Sound.play("blip");
  if (open) host.alert("overview");
  else host.setView("overview");
}

/** A global shortcut was pressed. `resume` lifts Pause, as the tray's Open does. */
export function runGlobalShortcut(host: ShortcutHost, action: string, resume: () => void) {
  switch (action) {
    case "toggleIsland":
      if (State.mode === "expanded") {
        host.collapse();
      } else {
        resume();
        // A waiting card is what the island opens on (State.defaultView).
        host.alert(State.defaultView());
        host.takeKeyboard();
      }
      break;

    case "openChat":
      resume();
      host.alert("prompt");
      break;

    case "goToAlert": {
      const asking = State.tasks.find((t) => t.state === "question");
      const pending = State.pendingApproval;
      if (pending) {
        // The one card every agent's request uses: its own pill to the front,
        // its card (permission or question) up. Nothing is answered from here.
        resume();
        State.setFocus(pending.pillId);
        host.alert(pending.questions ? "question" : "approval");
        host.takeKeyboard();
      } else if (asking) {
        resume();
        State.setFocus(asking.id);
        host.alert("question");
        host.takeKeyboard();
      } else {
        // Nothing is waiting: Nova says so.
        host.emote("annoyed");
        Sound.play("error");
      }
      break;
    }

    // The Mac brings the terminal app forward; here it is the existing "Open
    // terminal": the session's own window when it was found, else its folder
    // in VS Code; the Claude app for a Claude Desktop session.
    case "jumpToTerminal": {
      const task = State.focusTask;
      if (task?.id === CLAUDE_DESKTOP_ID) void Bridge.openClaudeDesktop();
      else void Bridge.openSession(task?.sessionId ?? null, task?.sessionCwd ?? null);
      if (State.mode === "expanded") host.collapse();
      break;
    }

    case "nextPill":
    case "prevPill":
      resume();
      focusPill(
        host,
        cyclePill(State.tasks.map((t) => t.id), State.focusTask?.id ?? null, action === "nextPill" ? 1 : -1),
        true,
      );
      break;

    case "muteToggle": {
      const on = !State.settings.soundEnabled;
      State.settings.soundEnabled = on;
      Sound.setEnabled(on);
      void Bridge.saveSettings(State.settings);
      if (on) Sound.play("tick");
      host.emote(on ? "happy" : "annoyed");
      State.notify();
      break;
    }

    // The Mac's ⌃⌥D. Sending him out lifts Pause, as the other shortcuts do;
    // where he can't leave the island, Nova says so.
    case "desktopToggle":
      if (!host.canLeaveIsland()) {
        host.emote("annoyed");
        Sound.play("error");
        break;
      }
      if (!State.novaOnDesktop) resume();
      host.flyOutOrHome();
      break;

    // wardrobeToggle never comes this way (Rust sends `open-wardrobe`), and
    // attachFrontWindow isn't in this version.
    default:
      break;
  }
}

/** A key the island acts on while it has the keyboard. */
export function runIslandKey(host: ShortcutHost, action: IslandKeyAction) {
  const ids = State.tasks.map((t) => t.id);
  switch (action.kind) {
    case "cycle":
      focusPill(host, cyclePill(ids, State.focusTask?.id ?? null, action.delta), false);
      break;
    case "pill":
      focusPill(host, pillByNumber(ids, action.number), false);
      break;
    case "list":
      // Only a card with a list counts its items: the GitHub lists, as on the Mac.
      if (State.view !== "overview" || State.cardItemCount <= 0) return;
      State.cardSelection = navigate(State.cardSelection, action.delta, State.cardItemCount);
      State.notify();
      break;
    case "openSelection":
      if (State.cardSelection == null) return;
      host.viewCommand("openSelection");
      break;
    case "diff":
      host.viewCommand("toggleDiff");
      break;
    case "newChat":
      // Not while an answer is on its way: it would land in the new chat.
      if (State.stateOverride === "thinking") return;
      State.chatHistory = [];
      State.droppedFile = null;
      State.promptContext = null;
      void Bridge.chatReset();
      Sound.play("blip");
      host.setView("prompt");
      break;
    case "settings":
      void Bridge.openSettingsWindow();
      break;
    case "pin":
      // A permission card keeps the island pinned until it is answered.
      if (State.pendingApproval) return;
      host.setPinned(!State.isPinned);
      break;
  }
}

function inTextField(target: EventTarget | null): boolean {
  const el = target as { tagName?: string; isContentEditable?: boolean } | null;
  return el?.tagName === "INPUT" || el?.tagName === "TEXTAREA" || el?.isContentEditable === true;
}

export function registerShortcutHandlers(host: ShortcutHost, resume: () => void) {
  void onEvent<string>("shortcut", (action) => runGlobalShortcut(host, action, resume));
  // The wardrobe shortcut comes as its own event (shortcuts.rs): it opens the
  // wardrobe (nova/wardrobe.ts, views/wardrobe.ts), or closes it again.
  void onEvent<null>("open-wardrobe", () => {
    resume();
    host.wardrobeAnywhere();
  });

  // Capture phase: the chat field stops its own key events from bubbling.
  window.addEventListener(
    "keydown",
    (e: KeyboardEvent) => {
      if (State.mode !== "expanded") return;
      const action = islandKeyAction(e, { view: State.view, inTextField: inTextField(e.target) });
      if (!action) return;
      e.preventDefault();
      e.stopPropagation();
      runIslandKey(host, action);
    },
    true,
  );
}
