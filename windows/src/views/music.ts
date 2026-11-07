// The music page: the Spotify card on the left, the song's synced lyrics on
// the right, each line lighting up as it is sung; a click on a line jumps the
// song there. Opened from the card's lyrics button (views/spotify.ts), which
// brings the overview back from here. Lyrics: core/lyrics.ts, lyrics.rs.

import { h, clear } from "./dom";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { Spotify, isAd, spotifyPosition } from "../core/spotify";
import { fromAnswer, lineAt, type Lyrics } from "../core/lyrics";
import { buildSpotifyCard, seekTo } from "./spotify";
import { t } from "../i18n/i18n";
import type { ViewActions, ViewHost } from "./views";

type Status = "idle" | "loading" | "found" | "none" | "offline";

export function buildMusic(actions: ViewActions): ViewHost {
  const card = buildSpotifyCard(() => actions.setView("overview"), true);
  const lines = h("div", { class: "ly-lines" });
  const note = h("div", { class: "ly-note" });
  const pane = h("div", { class: "ly-pane" }, lines, note);
  const root = h("div", { class: "mu-root" }, h("div", { class: "mu-player" }, card.el), h("i", { class: "mu-sep" }), pane);
  const el = h("div", { class: "view" }, h("div", { class: "card mu-cardbox" }, root));

  let songKey = "";
  let status: Status = "idle";
  let lyrics: Lyrics | null = null;
  let rows: HTMLElement[] = [];
  let current = -2;
  let asked = 0;

  function songOf(): { key: string; title: string; artist: string; album: string; duration: number } | null {
    const tr = Spotify.state.track;
    if (!tr || isAd(tr) || !tr.title) return null;
    return { key: `${tr.title}|${tr.artist}|${Math.round(tr.duration)}`, title: tr.title, artist: tr.artist, album: tr.album, duration: tr.duration };
  }

  function load() {
    const song = songOf();
    const key = song?.key ?? "";
    if (key === songKey) return;
    songKey = key;
    lyrics = null;
    current = -2;
    if (!song) {
      status = "idle";
      draw();
      return;
    }
    status = "loading";
    draw();
    const ticket = ++asked;
    void Bridge.lyricsGet(song.title, song.artist, song.album, song.duration)
      .then((a) => {
        if (ticket !== asked) return;
        lyrics = fromAnswer(a);
        status = lyrics ? "found" : "none";
        draw();
      })
      .catch(() => {
        if (ticket !== asked) return;
        status = "offline";
        // Offline now, maybe not in a moment: the next look tries again.
        songKey = "";
        draw();
      });
  }

  function message(): string {
    switch (status) {
      case "idle": return t("Play a song on Spotify to see its lyrics.");
      case "loading": return t("Looking for the lyrics…");
      case "none": return t("No lyrics for this song yet.");
      case "offline": return t("Couldn't reach the lyrics library.");
      default:
        if (lyrics?.instrumental && !lyrics.lines.length && !lyrics.plain) return t("Instrumental");
        return "";
    }
  }

  function draw() {
    clear(lines);
    rows = [];
    const msg = message();
    note.textContent = msg;
    note.classList.toggle("on", msg !== "");
    pane.classList.toggle("plain", !!lyrics && !lyrics.lines.length && !!lyrics.plain);
    if (!lyrics) return;
    if (lyrics.lines.length) {
      rows = lyrics.lines.map((l) => {
        const row = h("div", { class: `ly-line${l.text ? "" : " gap"}`, text: l.text || "♪" });
        row.addEventListener("click", () => seekTo(l.at));
        return row;
      });
      lines.append(...rows);
    } else if (lyrics.plain) {
      lines.append(...lyrics.plain.split(/\r?\n/).map((l) => h("div", { class: "ly-line plainline", text: l || " " })));
    }
    current = -2;
    follow();
  }

  /** The line being sung lights up and slides to the pane's upper third. */
  function follow() {
    if (!lyrics?.lines.length || !rows.length) return;
    const pos = spotifyPosition(Spotify.state, Date.now());
    const i = lineAt(lyrics.lines, pos);
    if (i === current) return;
    current = i;
    rows.forEach((r, k) => {
      r.classList.toggle("sung", k === i);
      r.classList.toggle("past", k < i);
    });
    const target = rows[Math.max(0, i)];
    const y = target.offsetTop - pane.clientHeight * 0.3;
    lines.style.transform = `translateY(${-Math.max(0, y)}px)`;
  }

  window.setInterval(() => {
    if (State.view === "music" && State.mode === "expanded") follow();
  }, 200);

  return {
    el,
    sync() {
      if (State.view !== "music") return;
      card.sync();
      load();
      follow();
    },
  };
}

