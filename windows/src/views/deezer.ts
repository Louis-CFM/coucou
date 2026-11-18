// The Deezer pill and card: the layout, sizes and colours of the Spotify ones
// (views/spotify.ts), in Deezer's purple. What they show comes from
// src-tauri/src/deezer.rs through island/deezer.ts. A click changes the page's
// copy at once and Deezer confirms it.
//
// Not shown, because the Deezer session doesn't report them: shuffle, repeat,
// the album (an empty one is left out) and ads.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { DeezerBridge } from "../core/deezer-bridge";
import { State, type AgentTask } from "../core/state";
import {
  DEEZER_ID, DEEZER_PURPLE, Deezer, currentArtwork, deezerPosition, formatTime, volumeLevel, withPlaying,
  type DeezerTrack,
} from "../core/deezer";
import { deezerPlaying } from "../island/deezer";
import { createMiniBot } from "../mochi/minibots";
import { pillDefinition } from "../core/pills";
import { N_, t } from "../i18n/i18n";

const GREY = "#C5C8CD";

function lighter(hex: string, amount: number): string {
  const v = parseInt(hex.replace("#", ""), 16);
  const c = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((x) => Math.min(255, Math.round(x + amount * 255)));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// ── Controls (shared by the pill and the card) ───────────────────────────────

/** Play/pause, at once on the page, then in Deezer. */
export function togglePlay() {
  const s = Deezer.state;
  if (!s.running) return;
  Deezer.state = withPlaying(s, !s.playing, Date.now());
  State.notify();
  void DeezerBridge.control("playPause");
}

export function seek(seconds: number) {
  const s = Deezer.state;
  const track = s.track;
  if (!s.running || !track) return;
  const target = Math.min(Math.max(0, seconds), Math.max(0, track.duration - 1));
  Deezer.state = { ...s, position: target, positionAt: Date.now() };
  State.notify();
  void DeezerBridge.control("seek", target);
}

// A slider drag sends at most one volume every 120 ms.
let pendingVolume: number | null = null;
let volumeTimer: number | null = null;

export function setVolume(value: number) {
  if (!Deezer.state.running) return;
  const v = Math.min(100, Math.max(0, Math.round(value)));
  Deezer.state = { ...Deezer.state, volume: v };
  State.notify();
  pendingVolume = v;
  if (volumeTimer != null) return;
  const send = () => {
    const next = pendingVolume;
    pendingVolume = null;
    if (next == null) {
      volumeTimer = null;
      return;
    }
    void DeezerBridge.control("volume", next);
    volumeTimer = window.setTimeout(send, 120);
  };
  send();
}

// ── Pill (overview right column) ──────────────────────────────────────────────

export interface DeezerPillHost {
  el: HTMLElement;
  sync(): void;
}

/** A 20 px round button in the pill's colour. */
function pillButton(color: string, icon: string, onClick: () => void): HTMLElement {
  const b = h("button", { class: "np-pill-btn" }, svg(icon, 8));
  b.style.borderColor = `${color}24`;
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    onClick();
  });
  b.addEventListener("mouseenter", () => {
    b.style.background = `${color}2e`;
    b.style.borderColor = `${color}8c`;
    b.style.color = lighter(color, 0.3);
    b.style.boxShadow = `0 0 6px ${color}59`;
  });
  b.addEventListener("mouseleave", () => {
    b.style.background = "";
    b.style.borderColor = `${color}24`;
    b.style.color = "";
    b.style.boxShadow = "";
  });
  return b;
}

/**
 * The agent pill's look, with a mini Mochi that dances while Deezer plays, and
 * play/pause + next on hover when a track is loaded.
 */
export function buildDeezerPill(task: AgentTask, onTap: () => void): DeezerPillHost {
  const color = task.color;
  const mini = createMiniBot(task, 24, deezerPlaying);
  const label = h("span", { class: "lbl", text: task.name });
  const playBtn = pillButton(color, ICONS.play, togglePlay);
  const nextBtn = pillButton(color, ICONS.forward, () => void DeezerBridge.control("next"));
  const controls = h("div", { class: "np-pill-controls" }, playBtn, nextBtn);
  const pill = h("div", { class: "pill np-pill", onclick: onTap }, mini, label, controls);
  pill.style.borderColor = `${color}24`;
  let hovered = false;
  let playing: boolean | null = null;

  const sync = () => {
    const s = Deezer.state;
    const name = State.tasks.find((x) => x.id === task.id)?.name ?? task.name;
    if (label.textContent !== name) label.textContent = name;
    pill.classList.toggle("controls", hovered && s.track != null);
    if (playing !== s.playing) {
      playing = s.playing;
      clear(playBtn);
      playBtn.append(svg(s.playing ? ICONS.pause : ICONS.play, 8));
    }
    playBtn.title = s.playing ? t("Pause") : t("Play");
    nextBtn.title = t("Next");
  };

  pill.addEventListener("mouseenter", () => {
    hovered = true;
    pill.style.background = `${color}2e`;
    pill.style.borderColor = `${color}8c`;
    pill.style.boxShadow = `0 2px 10px ${color}59`;
    label.style.color = lighter(color, 0.3);
    sync();
  });
  pill.addEventListener("mouseleave", () => {
    hovered = false;
    pill.style.background = "";
    pill.style.borderColor = `${color}24`;
    pill.style.boxShadow = "";
    label.style.color = "";
    sync();
  });
  sync();
  return { el: pill, sync };
}

// ── Card (overview left card) ─────────────────────────────────────────────────

/** A grey track whose filled part turns purple and grows a knob under the pointer. */
class NowPlayingBar {
  readonly el: HTMLElement;
  private fill: HTMLElement;
  private knob: HTMLElement;
  private hovering = false;
  private dragging = false;
  private fraction = 0;
  enabled = true;

  private onChange: (f: number) => void;
  private onCommit: (f: number) => void;

  constructor(onChange: (f: number) => void, onCommit: (f: number) => void) {
    this.onChange = onChange;
    this.onCommit = onCommit;
    this.fill = h("i", { class: "np-fill" });
    this.knob = h("i", { class: "np-knob" });
    this.fill.style.background = GREY;
    this.el = h("div", { class: "np-bar" }, h("i", { class: "np-track" }), this.fill, this.knob);
    this.el.addEventListener("mouseenter", () => {
      this.hovering = true;
      this.paint();
    });
    this.el.addEventListener("mouseleave", () => {
      this.hovering = false;
      this.paint();
    });
    this.el.addEventListener("pointerdown", (e) => {
      if (!this.enabled || e.button !== 0) return;
      e.stopPropagation();
      this.dragging = true;
      try {
        this.el.setPointerCapture(e.pointerId);
      } catch {
        /* capture is a nicety */
      }
      this.onChange(this.at(e.clientX));
      this.paint();
    });
    this.el.addEventListener("pointermove", (e) => {
      if (this.dragging) this.onChange(this.at(e.clientX));
    });
    const end = (e: PointerEvent) => {
      if (!this.dragging) return;
      this.dragging = false;
      this.onCommit(this.at(e.clientX));
      this.paint();
    };
    this.el.addEventListener("pointerup", end);
    this.el.addEventListener("pointercancel", end);
  }

  private at(clientX: number): number {
    const r = this.el.getBoundingClientRect();
    return Math.min(1, Math.max(0, (clientX - r.left) / Math.max(1, r.width)));
  }

  set(fraction: number) {
    this.fraction = Math.min(1, Math.max(0, fraction));
    this.paint();
  }

  private paint() {
    const active = this.enabled && (this.hovering || this.dragging);
    this.el.classList.toggle("active", active);
    const pct = `${this.fraction * 100}%`;
    this.fill.style.width = pct;
    this.fill.style.background = active ? DEEZER_PURPLE : GREY;
    this.knob.style.left = `clamp(0px, calc(${pct} - 4.5px), calc(100% - 9px))`;
  }
}

/** An icon that brightens under the pointer. */
function iconButton(icon: string, size: number, onClick: () => void): HTMLElement {
  const b = h("button", { class: "np-icon" }, svg(icon, size));
  b.addEventListener("click", onClick);
  return b;
}

export interface DeezerCardHost {
  el: HTMLElement;
  sync(): void;
}

/** Now playing, or the idle card (not playing / not installed). */
export function buildDeezerCard(): DeezerCardHost {
  const purple = DEEZER_PURPLE;

  // Now playing: artwork row, progress row, controls row.
  const art = h("div", { class: "np-art" });
  const artImg = h("img", { alt: "", draggable: "false" }) as HTMLImageElement;
  const artNote = svg(ICONS.musicNote, 16);
  artNote.style.color = `${purple}b3`;
  art.append(artNote, artImg);
  art.addEventListener("click", () => void DeezerBridge.open());
  const title = h("span", { class: "np-title" });
  const subtitle = h("div", { class: "np-sub" });
  const head = h("div", { class: "np-head" },
    art,
    h("div", { class: "np-text" }, h("div", { class: "np-title-row" }, dot(purple, 6), title), subtitle),
  );

  let dragFraction: number | null = null;
  const elapsed = h("span", { class: "np-time elapsed" });
  const remaining = h("span", { class: "np-time remaining" });
  const progress = new NowPlayingBar(
    (f) => {
      dragFraction = f;
      paintProgress();
    },
    (f) => {
      const d = Deezer.state.track?.duration ?? 0;
      dragFraction = null;
      seek(f * d);
    },
  );
  const progressRow = h("div", { class: "np-progress" }, elapsed, progress.el, remaining);

  const prev = iconButton(ICONS.backward, 11, () => void DeezerBridge.control("previous"));
  const next = iconButton(ICONS.forward, 11, () => void DeezerBridge.control("next"));
  prev.style.color = GREY;
  next.style.color = GREY;
  const play = h("button", { class: "np-play", onclick: togglePlay });
  const volIcon = h("span", { class: "np-vol-icon" });
  const volume = new NowPlayingBar((f) => setVolume(f * 100), (f) => setVolume(f * 100));
  const volumeBox = h("div", { class: "np-volume" }, volIcon, volume.el);
  const controls = h("div", { class: "np-controls" },
    h("div", { class: "np-buttons" }, prev, play, next),
    h("div", { class: "grow" }),
    volumeBox,
  );
  const playingEl = h("div", { class: "np-card" }, head, progressRow, controls);

  // Idle: the same layout as the other idle cards.
  const idleDot = dot("#22C55E", 5);
  const idleText = h("span");
  const idleAction = h("button", { class: "link-btn", style: `color:${purple}d9` });
  idleAction.addEventListener("click", () => void DeezerBridge.open());
  const idleSub = h("span");
  const idleEl = h("div", { class: "int-card" },
    h("div", { class: "int-head" }, dot(purple, 7), h("b", { text: "Deezer" }), idleSub),
    h("div", { class: "int-status" }, idleDot, idleText),
    h("div", { class: "int-actions" }, idleAction),
  );

  const el = h("div", { class: "np-root" });
  let showing: "playing" | "idle" | null = null;
  let shownTrack: DeezerTrack | null = null;
  let playIcon: boolean | null = null;
  let volIconLevel = -1;
  let timer: number | null = null;

  function paintProgress() {
    const s = Deezer.state;
    const d = s.track?.duration ?? 0;
    const pos = dragFraction != null ? dragFraction * d : deezerPosition(s, Date.now());
    const f = dragFraction ?? (d > 0 ? Math.min(1, Math.max(0, pos / d)) : 0);
    progress.set(f);
    elapsed.textContent = formatTime(f * d);
    remaining.textContent = d > 0 ? `-${formatTime(Math.max(0, d - f * d))}` : "";
  }

  const onScreen = () => el.isConnected && State.mode === "expanded" && State.view === "overview";

  /** The position runs on its own clock, twice a second, only while it plays on screen. */
  function syncTimer() {
    const run = Deezer.state.playing && showing === "playing" && onScreen();
    if (run && timer == null) {
      timer = window.setInterval(() => {
        if (!(Deezer.state.playing && onScreen())) {
          if (timer != null) window.clearInterval(timer);
          timer = null;
          return;
        }
        paintProgress();
      }, 500);
    } else if (!run && timer != null) {
      window.clearInterval(timer);
      timer = null;
    }
  }

  function syncPlaying(track: DeezerTrack) {
    const s = Deezer.state;
    if (shownTrack !== track) {
      shownTrack = track;
      title.textContent = track.title;
      const sub = [track.artist, track.album].filter((x) => x).join(" · ");
      subtitle.textContent = sub;
      subtitle.style.display = sub ? "" : "none";
    }
    art.title = track.album ? t("{0} — open Deezer", { 0: track.album }) : t("Open Deezer");
    const cover = currentArtwork(s);
    if (cover) {
      if (artImg.getAttribute("src") !== cover) artImg.setAttribute("src", cover);
      art.classList.add("has-art");
    } else {
      art.classList.remove("has-art");
      artImg.removeAttribute("src");
    }

    progress.enabled = track.duration > 0;
    paintProgress();

    prev.title = t("Previous");
    next.title = t("Next");
    if (playIcon !== s.playing) {
      playIcon = s.playing;
      clear(play);
      const icon = svg(s.playing ? ICONS.pause : ICONS.play, 9);
      if (!s.playing) icon.style.transform = "translateX(1px)";
      play.append(icon);
    }
    play.title = s.playing ? t("Pause") : t("Play");

    const level = volumeLevel(s.volume);
    if (level !== volIconLevel) {
      volIconLevel = level;
      clear(volIcon);
      volIcon.append(svg([ICONS.volume0, ICONS.volume1, ICONS.volume2, ICONS.volume3][level], 10, { stroke: 2.2 }));
    }
    volume.set(s.volume / 100);
    volumeBox.title = t("Volume {0}%", { 0: s.volume });
  }

  function syncIdle() {
    const installed = Deezer.state.installed || Deezer.state.running;
    idleDot.style.background = installed ? "#22C55E" : "#F4505E";
    idleText.textContent = installed ? t("Not playing") : t("Deezer not installed");
    idleAction.textContent = installed ? t("Open Deezer") : t("Get Deezer");
    idleSub.textContent = t(pillDefinition(DEEZER_ID)?.subtitle ?? N_("Integration"));
  }

  return {
    el,
    sync() {
      const track = Deezer.state.track;
      const want = track ? "playing" : "idle";
      if (want !== showing) {
        showing = want;
        clear(el);
        el.append(want === "playing" ? playingEl : idleEl);
        shownTrack = null;
      }
      if (track) syncPlaying(track);
      else syncIdle();
      syncTimer();
    },
  };
}