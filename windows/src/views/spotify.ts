// The Spotify pill and card — DOM ports of SpotifyPill / SpotifyCardView
// (SpotifyViews.swift) and the shared now-playing pieces (NowPlayingViews.swift
// and MusicControlButton). Sizes, colours and wording are the Mac's.
//
// What they show comes from src-tauri/src/spotify.rs (MPRIS on Linux, the
// system media controls on Windows) through
// island/spotify.ts. A click changes the page's copy at once and Spotify
// confirms it, as the Mac's controller does. Now Playing (any app, Windows)
// uses the same pill and card, in its own colour, with only the controls its
// app takes.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type SpotifyAction } from "../core/bridge";
import { State, type AgentTask } from "../core/state";
import {
  SPOTIFY_GREEN, Spotify, currentArtwork, formatTime, isAd, spotifyPosition, takes, volumeLevel, withPlaying,
  type Player, type SpotifyTrack,
} from "../core/spotify";
import { Lyrics, lineAt } from "../core/lyrics";
import { createMiniBot } from "../mochi/minibots";
import { pillDefinition } from "../core/pills";
import { N_, t } from "../i18n/i18n";


function lighter(hex: string, amount: number): string {
  const v = parseInt(hex.replace("#", ""), 16);
  const c = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((x) => Math.min(255, Math.round(x + amount * 255)));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// ── Controls (shared by the pill and the card) ───────────────────────────────

/** The player's own command: Spotify's, or Now Playing's. */
function command(player: Player, action: SpotifyAction, value?: number) {
  return player.kind === "spotify" ? Bridge.spotifyControl(action, value) : Bridge.nowPlayingControl(action, value);
}

function openPlayer(player: Player) {
  return player.kind === "spotify" ? Bridge.spotifyOpen() : Bridge.nowPlayingOpen();
}

/** Now Playing's name for the app that plays, or the pill's own. */
function appName(player: Player): string {
  return player.state.app || (pillDefinition(player.pillId)?.name ?? "Now Playing");
}

/** Play/pause, at once on the page, then in Spotify (SpotifyController.playPause). */
export function togglePlay(player: Player = Spotify) {
  const s = player.state;
  if (!s.running) return;
  player.state = withPlaying(s, !s.playing, Date.now());
  State.notify();
  void command(player, "playPause");
}

function seek(player: Player, seconds: number) {
  const s = player.state;
  const track = s.track;
  if (!s.running || !track || isAd(track) || !takes(s, "canSeek")) return;
  const target = Math.min(Math.max(0, seconds), Math.max(0, track.duration - 1));
  player.state = { ...s, position: target, positionAt: Date.now() };
  State.notify();
  void command(player, "seek", target);
}

function setFlag(player: Player, which: "shuffle" | "repeat", on: boolean) {
  if (!player.state.running) return;
  player.state = { ...player.state, [which]: on };
  State.notify();
  void command(player, which, on ? 1 : 0);
}

// A slider drag sends at most one volume every 120 ms (SpotifyController.setVolume).
// Only Spotify has a volume of its own.
let pendingVolume: number | null = null;
let volumeTimer: number | null = null;

function setVolume(player: Player, value: number) {
  if (!player.state.running || !takes(player.state, "hasVolume")) return;
  const v = Math.min(100, Math.max(0, Math.round(value)));
  player.state = { ...player.state, volume: v };
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
    void command(player, "volume", next);
    volumeTimer = window.setTimeout(send, 120);
  };
  send();
}

// ── Pill (overview right column) ──────────────────────────────────────────────

export interface SpotifyPillHost {
  el: HTMLElement;
  sync(): void;
}

/** MusicControlButton: a 20 px round button in the pill's colour. */
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
 * SpotifyPill: the agent pill's look, with a mini Mochi that dances while
 * Spotify plays, and play/pause + next on hover when a track is loaded.
 */
export function buildSpotifyPill(task: AgentTask, onTap: () => void, player: Player = Spotify): SpotifyPillHost {
  const color = task.color;
  const mini = player === Spotify
    ? createMiniBot(task, 24, () => State.spotifyPlaying)
    : createMiniBot(task, 24, () => player.state.playing && player.state.track != null);
  const label = h("span", { class: "lbl", text: task.name });
  const playBtn = pillButton(color, ICONS.play, () => togglePlay(player));
  const nextBtn = pillButton(color, ICONS.forward, () => void command(player, "next"));
  const controls = h("div", { class: "np-pill-controls" }, playBtn, nextBtn);
  const pill = h("div", { class: "pill np-pill", onclick: onTap }, mini, label, controls);
  pill.style.borderColor = `${color}24`;
  let hovered = false;
  let playing: boolean | null = null;

  const sync = () => {
    const s = player.state;
    const current = State.tasks.find((x) => x.id === task.id);
    const name = current?.name ?? task.name;
    if (label.textContent !== name) label.textContent = name;
    const show = hovered && s.track != null;
    pill.classList.toggle("controls", show);
    if (playing !== s.playing) {
      playing = s.playing;
      clear(playBtn);
      playBtn.append(svg(s.playing ? ICONS.pause : ICONS.play, 8));
    }
    playBtn.title = s.playing ? t("Pause") : t("Play");
    nextBtn.title = t("Next");
    nextBtn.style.display = takes(s, "canSkip") ? "" : "none";
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

/**
 * NowPlayingBar: a grey track whose filled part turns green and grows a knob
 * under the pointer; drag or click anywhere on it.
 */
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
  private accent: string;

  constructor(onChange: (f: number) => void, onCommit: (f: number) => void, accent: string = SPOTIFY_GREEN) {
    this.onChange = onChange;
    this.onCommit = onCommit;
    this.accent = accent;
    this.fill = h("i", { class: "np-fill" });
    this.knob = h("i", { class: "np-knob" });
    this.fill.style.background = "#C5C8CD";
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

  get active(): boolean {
    return this.enabled && (this.hovering || this.dragging);
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
    const active = this.active;
    this.el.classList.toggle("active", active);
    const pct = `${this.fraction * 100}%`;
    this.fill.style.width = pct;
    this.fill.style.background = active ? this.accent : "#C5C8CD";
    this.knob.style.left = `clamp(0px, calc(${pct} - 4.5px), calc(100% - 9px))`;
  }
}

/** NowPlayingIconButton: an icon that brightens under the pointer. */
function iconButton(icon: string, size: number, stroke: number, onClick: () => void): HTMLElement {
  const b = h("button", { class: "np-icon" }, svg(icon, size, stroke ? { stroke } : {}));
  b.addEventListener("click", onClick);
  return b;
}

export interface SpotifyCardHost {
  el: HTMLElement;
  sync(): void;
}

/** SpotifyCardView: now playing, or the idle card (not playing / not installed). */
export function buildSpotifyCard(player: Player = Spotify): SpotifyCardHost {
  const green = player.color;
  const spotify = player.kind === "spotify";

  // Now playing: artwork row, progress row, controls row.
  const art = h("div", { class: "np-art" });
  const artImg = h("img", { alt: "", draggable: "false" }) as HTMLImageElement;
  const artNote = svg(ICONS.musicNote, 16);
  artNote.style.color = `${green}b3`;
  art.append(artNote, artImg);
  art.addEventListener("click", () => void openPlayer(player));
  const title = h("span", { class: "np-title" });
  const subtitle = h("div", { class: "np-sub" });
  const head = h("div", { class: "np-head" },
    art,
    h("div", { class: "np-text" }, h("div", { class: "np-title-row" }, dot(green, 6), title), subtitle),
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
      const d = player.state.track?.duration ?? 0;
      dragFraction = null;
      seek(player, f * d);
    },
    green,
  );
  const progressRow = h("div", { class: "np-progress" }, elapsed, progress.el, remaining);

  const shuffle = iconButton(ICONS.shuffle, 10, 2.2, () => setFlag(player, "shuffle", !player.state.shuffle));
  const prev = iconButton(ICONS.backward, 11, 0, () => void command(player, "previous"));
  const next = iconButton(ICONS.forward, 11, 0, () => void command(player, "next"));
  const repeat = iconButton(ICONS.repeat, 10, 2.2, () => setFlag(player, "repeat", !player.state.repeat));
  prev.style.color = "#C5C8CD";
  next.style.color = "#C5C8CD";
  const play = h("button", { class: "np-play", onclick: () => togglePlay(player) });
  const volIcon = h("span", { class: "np-vol-icon" });
  const volume = new NowPlayingBar(
    (f) => setVolume(player, f * 100),
    (f) => setVolume(player, f * 100),
    green,
  );
  const volumeBox = h("div", { class: "np-volume" }, volIcon, volume.el);
  const controls = h("div", { class: "np-controls" },
    h("div", { class: "np-buttons" }, shuffle, prev, play, next, repeat),
    h("div", { class: "grow" }),
    volumeBox,
  );
  const playingEl = h("div", { class: "np-card" }, head, progressRow, controls);

  // Idle: the same layout as the other idle cards.
  const idleDot = dot("#22C55E", 5);
  const idleText = h("span");
  const idleAction = h("button", { class: "link-btn", style: `color:${green}d9` });
  idleAction.addEventListener("click", () => void openPlayer(player));
  const idleSub = h("span");
  const idleName = h("b", { text: spotify ? "Spotify" : appName(player) });
  const idleEl = h("div", { class: "int-card" },
    h("div", { class: "int-head" }, dot(green, 7), idleName, idleSub),
    h("div", { class: "int-status" }, idleDot, idleText),
    h("div", { class: "int-actions" }, idleAction),
  );

  const el = h("div", { class: "np-root" });
  let showing: "playing" | "idle" | null = null;
  let shownTrack: SpotifyTrack | null = null;
  let playIcon: boolean | null = null;
  let volIconLevel = -1;
  let timer: number | null = null;
  /** Artist · album, shown under the title whenever no lyric line is. */
  let baseSub = "";

  function paintProgress() {
    const s = player.state;
    const d = s.track?.duration ?? 0;
    const pos = dragFraction != null ? dragFraction * d : spotifyPosition(s, Date.now());
    const f = dragFraction ?? (d > 0 ? Math.min(1, Math.max(0, pos / d)) : 0);
    progress.set(f);
    elapsed.textContent = formatTime(f * d);
    remaining.textContent = d > 0 ? `-${formatTime(Math.max(0, d - f * d))}` : "";
    paintSubtitle(pos);
  }

  /** The line being sung takes artist · album's place; between lines they come back. */
  function paintSubtitle(pos: number) {
    const track = player.state.track;
    const lines = State.settings.lyricsEnabled && track ? Lyrics.byTrack.get(track.id) : null;
    const line = lines ? lineAt(lines, pos) : null;
    const text = line ?? baseSub;
    if (subtitle.textContent !== text) subtitle.textContent = text;
    subtitle.style.display = text ? "" : "none";
    subtitle.style.color = line ? "#C5C8CD" : "";
    subtitle.title = line ?? "";
  }

  /** The position runs on its own clock, twice a second, only while it plays on screen. */
  function syncTimer() {
    const run = player.state.playing && showing === "playing" && el.isConnected &&
      State.mode === "expanded" && State.view === "overview";
    if (run && timer == null) {
      timer = window.setInterval(() => {
        if (!(player.state.playing && el.isConnected && State.mode === "expanded" && State.view === "overview")) {
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

  function syncPlaying(track: SpotifyTrack) {
    const s = player.state;
    if (shownTrack !== track) {
      shownTrack = track;
      title.textContent = isAd(track) ? t("Advertisement") : track.title;
      baseSub = [track.artist, track.album].filter((x) => x).join(" · ");
    } else if (isAd(track)) {
      title.textContent = t("Advertisement");
    }
    art.title = spotify
      ? (track.album ? t("{0} — open Spotify", { 0: track.album }) : t("Open Spotify"))
      : t("Open {name}", { name: appName(player) });
    const cover = currentArtwork(s, player);
    if (cover) {
      if (artImg.getAttribute("src") !== cover) artImg.setAttribute("src", cover);
      art.classList.add("has-art");
    } else {
      art.classList.remove("has-art");
      artImg.removeAttribute("src");
    }

    progress.enabled = !isAd(track) && track.duration > 0 && takes(s, "canSeek");
    // A live stream or a page that gives no length: no bar to show.
    progressRow.style.display = spotify || track.duration > 0 ? "" : "none";
    paintProgress();

    shuffle.style.display = takes(s, "canShuffle") ? "" : "none";
    repeat.style.display = takes(s, "canRepeat") ? "" : "none";
    next.style.display = takes(s, "canSkip") ? "" : "none";
    volumeBox.style.display = takes(s, "hasVolume") ? "" : "none";
    shuffle.style.color = s.shuffle ? green : "#6B7079";
    shuffle.title = s.shuffle ? t("Shuffle on") : t("Shuffle off");
    repeat.style.color = s.repeat ? green : "#6B7079";
    repeat.title = s.repeat ? t("Repeat on") : t("Repeat off");
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
    idleSub.textContent = t(pillDefinition(player.pillId)?.subtitle ?? N_("Integration"));
    if (!spotify) {
      // Nothing to install or open: any app that plays shows here.
      idleName.textContent = appName(player);
      idleDot.style.background = "#22C55E";
      idleText.textContent = t("Not playing");
      idleAction.style.display = "none";
      return;
    }
    const installed = player.state.installed || player.state.running;
    idleDot.style.background = installed ? "#22C55E" : "#F4505E";
    idleText.textContent = installed ? t("Not playing") : t("Spotify not installed");
    idleAction.textContent = installed ? t("Open Spotify") : t("Get Spotify");
  }

  return {
    el,
    sync() {
      const track = player.state.track;
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
