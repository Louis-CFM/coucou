// Mochi's room lives in the Coucou window, the sessions and the permission
// cards live here: while the room is on screen (and only then) the island
// sends it what it shows, and the room's buttons answer through the island's
// own card, so a click there is exactly a click here.

import { emitToWindow, onEvent } from "../core/bridge";
import { State } from "../core/state";
import { ROOM_EVENTS, roomSnapshot } from "../core/room";
import type { Island } from "./island";

/** The Coucou window's label (HUB_LABEL in src-tauri/src/lib.rs). */
const HUB = "settings";
/** A burst of state changes (a session's steps) becomes one message. */
const DEBOUNCE_MS = 250;

export function registerRoomLink(island: Pick<Island, "answerFromRoom" | "alert">) {
  let unsubscribe: (() => void) | null = null;
  let timer: number | null = null;
  let last = "";

  const publish = () => {
    timer = null;
    const snap = roomSnapshot(State);
    const key = JSON.stringify(snap);
    if (key === last) return;
    last = key;
    void emitToWindow(HUB, ROOM_EVENTS.state, snap);
  };
  const schedule = () => {
    if (timer == null) timer = window.setTimeout(publish, DEBOUNCE_MS);
  };

  // Watched: the whole picture now, then each change. Not watched: nothing at all.
  void onEvent<boolean>(ROOM_EVENTS.watch, (on) => {
    unsubscribe?.();
    unsubscribe = null;
    if (timer != null) window.clearTimeout(timer);
    timer = null;
    last = "";
    if (!on) return;
    unsubscribe = State.subscribe(schedule);
    publish();
  });
  void onEvent<{ requestId: string; decision: "allow" | "deny" | "terminal" }>(ROOM_EVENTS.decide, (d) => {
    if (d && typeof d.requestId === "string" && ["allow", "deny", "terminal"].includes(d.decision)) {
      island.answerFromRoom(d.requestId, d.decision);
    }
  });
  void onEvent<null>(ROOM_EVENTS.open, () => island.alert(State.defaultView()));
}
