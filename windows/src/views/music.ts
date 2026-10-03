// Now playing — the SMTC card.
//
// macOS shows Apple Music on hover in the header; Windows reports every player
// through SMTC instead, so this is a row inside the overview card that only
// exists while something is actually playing.

import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { clear, h, svg } from "./dom";
import { ICONS } from "./icons";

type MediaAction = "play" | "pause" | "toggle" | "next" | "prev";

function ctrl(icon: string, title: string, action: MediaAction): HTMLElement {
  const b = h("button", {
    class: "np-ctrl",
    title,
    onclick: () => void Bridge.mediaAction(action),
  });
  b.append(svg(icon, 13));
  return b;
}

export function buildMusic(): { el: HTMLElement; sync: () => void } {
  const el = h("div", { class: "music" });
  let key = "\u0000";

  return {
    el,
    sync() {
      const np = State.nowPlaying;
      const live = np && (np.title !== "" || np.artist !== "") ? np : null;
      const next = live ? [live.app, live.title, live.artist, live.playing].join("~") : "";
      if (next === key) return;
      key = next;
      clear(el);
      if (!live) {
        el.style.display = "none";
        return;
      }
      el.style.display = "";
      el.append(
        h(
          "div",
          { class: "np-meta" },
          h("span", { class: "np-title", text: live.title }),
          h("span", { class: "np-artist", text: live.artist || live.album || live.app }),
        ),
        h(
          "div",
          { class: "np-ctrls" },
          ctrl(ICONS.prev, "Previous", "prev"),
          ctrl(live.playing ? ICONS.pause : ICONS.play, live.playing ? "Pause" : "Play", "toggle"),
          ctrl(ICONS.next, "Next", "next"),
        ),
      );
    },
  };
}
