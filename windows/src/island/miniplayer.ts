// The mini player in the compact island: the cover, the title and the
// artist, play/pause and next — whenever music plays and no live activity is
// up. Built once; sync() repaints it from the player's state.

import { h, svg, clear } from "../views/dom";
import { ICONS } from "../views/icons";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { Spotify, currentArtwork, musicAccent } from "../core/spotify";
import { togglePlay } from "../views/spotify";

export function buildMiniPlayer(): { el: HTMLElement; sync(show: boolean): void } {
  const art = h("div", { class: "mp-art" });
  const img = h("img", { alt: "", draggable: "false" }) as HTMLImageElement;
  art.append(img);
  const title = h("span", { class: "mp-title" });
  const play = h("button", { class: "mp-btn" });
  const next = h("button", { class: "mp-btn" }, svg(ICONS.forward, 10));
  // Clicks here are the player's, never the island's (which would open it).
  // The island opens on mousedown: the buttons keep their press to themselves.
  for (const b of [play, next]) {
    b.addEventListener("pointerdown", (e) => e.stopPropagation());
    b.addEventListener("mousedown", (e) => e.stopPropagation());
  }
  play.addEventListener("click", (e) => { e.stopPropagation(); togglePlay(); });
  next.addEventListener("click", (e) => { e.stopPropagation(); void Bridge.spotifyControl("next"); });
  const el = h("div", { id: "mini-player" }, art, title, play, next);
  let shownPlaying: boolean | null = null;
  return {
    el,
    sync(show) {
      el.classList.toggle("on", show);
      if (!show) return;
      const s = Spotify.state;
      const t = s.track;
      const text = t ? [t.title, t.artist].filter((x) => x).join(" · ") : "";
      if (title.textContent !== text) title.textContent = text;
      const cover = currentArtwork(s);
      if (cover && img.getAttribute("src") !== cover) img.setAttribute("src", cover);
      art.classList.toggle("has-art", !!cover);
      art.style.background = cover ? "" : `${musicAccent(s)}55`;
      if (shownPlaying !== s.playing) {
        shownPlaying = s.playing;
        clear(play);
        play.append(svg(s.playing ? ICONS.pause : ICONS.play, 10));
      }
    },
  };
}

/** The compact island shows the mini player: music loaded on a declared pill. */
export function miniPlayerWanted(): boolean {
  const s = Spotify.state;
  return s.track != null && (s.playing || s.running) && State.settings.activeIntegrations.includes(s.source);
}
