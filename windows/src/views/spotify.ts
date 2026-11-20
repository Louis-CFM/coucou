// The Spotify pill and card — DOM ports of SpotifyPill / SpotifyCardView
// (SpotifyViews.swift) and the shared now-playing pieces (NowPlayingViews.swift
// and MusicControlButton). Sizes, colours and wording are the Mac's.
//
// What they show comes from src-tauri/src/spotify.rs (MPRIS on Linux, the
// system media controls on Windows) through
// island/spotify.ts. A click changes the page's copy at once and Spotify
// confirms it, as the Mac's controller does.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { Bridge } from "../core/bridge";
import { State, type AgentTask } from "../core/state";
import {
  SPOTIFY_GREEN, SPOTIFY_ID, Spotify, currentArtwork, formatTime, isAd, spotifyPosition, volumeLevel, withPlaying,
  type SpotifyTrack,
} from "../core/spotify";
import { createMiniBot } from "../mochi/minibots";
import { pillDefinition } from "../core/pills";
import { N_, t } from "../i18n/i18n";


function lighter(hex: string, amount: number): string {
  const v = parseInt(hex.replace("#", ""), 16);
  const c = [(v >> 16) & 255, (v >> 8) & 255, v & 255].map((x) => Math.min(255, Math.round(x + amount * 255)));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

// ── Controls (shared by the pill and the card) ───────────────────────────────

/** Play/pause, at once on the page, then in Spotify (SpotifyController.playPause). */
export function togglePlay() {
  const s = Spotify.state;
  if (!s.running) return;
  Spotify.state = withPlaying(s, !s.playing, Date.now());
  State.notify();
  void Bridge.spotifyControl("playPause");
}

function seek(seconds: number) {
  const s = Spotify.state;
  const track = s.track;
  if (!s.running || !track || isAd(track)) return;
  const target = Math.min(Math.max(0, seconds), Math.max(0, track.duration - 1));
  Spotify.state = { ...s, position: target, positionAt: Date.now() };
  State.notify();
  void Bridge.spotifyControl("seek", target);
}

function setFlag(which: "shuffle" | "repeat", on: boolean) {
  if (!Spotify.state.running) return;
  Spotify.state = { ...Spotify.state, [which]: on };
  State.notify();
  void Bridge.spotifyControl(which, on ? 1 : 0);
}

// A slider drag sends at most one volume every 120 ms (SpotifyController.setVolume).
let pendingVolume: number | null = null;
let volumeTimer: number | null = null;

function setVolume(value: number) {
  if (!Spotify.state.running) return;
  const v = Math.min(100, Math.max(0, Math.round(value)));
  Spotify.state = { ...Spotify.state, volume: v };
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
    void Bridge.spotifyControl("volume", next);
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
export function buildSpotifyPill(task: AgentTask, onTap: () => void): SpotifyPillHost {
  const color = task.color;
  const mini = createMiniBot(task, 24, () => State.spotifyPlaying);
  const label = h("span", { class: "lbl", text: task.name });
  const playBtn = pillButton(color, ICONS.play, togglePlay);
  const nextBtn = pillButton(color, ICONS.forward, () => void Bridge.spotifyControl("next"));
  const controls = h("div", { class: "np-pill-controls" }, playBtn, nextBtn);
  const pill = h("div", { class: "pill np-pill", onclick: onTap }, mini, label, controls);
  pill.style.borderColor = `${color}24`;
  let hovered = false;
  let playing: boolean | null = null;

  const sync = () => {
    const s = Spotify.state;
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

  constructor(onChange: (f: number) => void, onCommit: (f: number) => void) {
    this.onChange = onChange;
    this.onCommit = onCommit;
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
    this.fill.style.background = active ? SPOTIFY_GREEN : "#C5C8CD";
    this.knob.style.left = `clamp(0px, calc(${pct} - 4.5px), calc(100% - 9px))`;
  }
}

/** NowPlayingIconButton: equal-dimension 26x26px transport button with refined macOS feedback. */
function iconButton(icon: string, size: number, stroke: number, onClick: () => void): HTMLElement {
  const b = h("button", { class: "np-ctrl-btn" }, svg(icon, size, stroke ? { stroke } : {}));
  b.addEventListener("click", onClick);
  return b;
}

export interface SpotifyCardHost {
  el: HTMLElement;
  sync(): void;
}

/** SpotifyCardView: now playing, or the idle card (not playing / not installed). */
export function buildSpotifyCard(): SpotifyCardHost {
  const green = SPOTIFY_GREEN;

  // Now playing: 2-column macOS hero layout (Art + 4-row Console)
  const art = h("div", { class: "np-art" });
  const artImg = h("img", { alt: "", draggable: "false" }) as HTMLImageElement;
  const artNote = svg(ICONS.musicNote, 28);
  artNote.style.color = `${green}b3`;
  art.append(artNote, artImg);
  art.addEventListener("click", () => void Bridge.spotifyOpen());
  const title = h("span", { class: "np-title" });

  // 6-bar audio pulse wave (islandcn LevelMeter / PlayerMeter)
  const pulseBars: HTMLElement[] = [];
  const envelope = [0.5, 1, 0.7, 0.4, 0.6, 0.35];
  for (let i = 0; i < 6; i++) {
    const bar = h("span", { class: "np-pulse-bar" });
    const hi = envelope[i];
    const lo = Math.max(0.12, hi * 0.35);
    const dur = (0.42 + (((i + 5) * 17) % 10) * 0.05).toFixed(2);
    const delay = (-(((i + 9) * 23) % 10) * 0.08).toFixed(2);
    bar.style.setProperty("--np-lo", String(lo));
    bar.style.setProperty("--np-hi", String(hi));
    bar.style.setProperty("--np-dur", `${dur}s`);
    bar.style.setProperty("--np-delay", `${delay}s`);
    pulseBars.push(bar);
  }
  const pulseWave = h("div", { class: "np-pulse-wave", title: t("Playing") }, ...pulseBars);

  // Refined macOS Open Spotify Action Pill
  const openPill = h(
    "button",
    {
      class: "np-open-pill",
      title: t("Open Spotify"),
      onclick: () => void Bridge.spotifyOpen(),
    },
    svg(ICONS.spotify, 11),
    h("span", { class: "np-open-label", text: "Spotify" }),
    svg(ICONS.arrowUpRight, 8),
  );
  const activityBay = h("div", { class: "np-activity-bay" }, pulseWave, openPill);

  const titleRow = h("div", { class: "np-row-title" }, title, activityBay);
  const subtitle = h("div", { class: "np-sub" });

  let dragFraction: number | null = null;
  const elapsed = h("span", { class: "np-time elapsed" });
  const remaining = h("span", { class: "np-time remaining" });
  const progress = new NowPlayingBar(
    (f) => {
      dragFraction = f;
      paintProgress();
    },
    (f) => {
      const d = Spotify.state.track?.duration ?? 0;
      dragFraction = null;
      seek(f * d);
    },
  );
  const progressRow = h("div", { class: "np-progress" }, elapsed, progress.el, remaining);

  // Symmetrical, equal-dimension 26x26px playback controls
  const shuffle = iconButton(ICONS.shuffle, 12, 2.2, () => setFlag("shuffle", !Spotify.state.shuffle));
  const prev = iconButton(ICONS.backward, 12, 0, () => void Bridge.spotifyControl("previous"));
  const play = h("button", { class: "np-ctrl-btn np-play-btn", onclick: togglePlay });
  const next = iconButton(ICONS.forward, 12, 0, () => void Bridge.spotifyControl("next"));
  const repeat = iconButton(ICONS.repeat, 12, 2.2, () => setFlag("repeat", !Spotify.state.repeat));
  prev.style.color = "#C5C8CD";
  next.style.color = "#C5C8CD";
  const volIcon = h("span", { class: "np-vol-icon" });
  const volume = new NowPlayingBar(
    (f) => setVolume(f * 100),
    (f) => setVolume(f * 100),
  );
  const volumeBox = h("div", { class: "np-volume" }, volIcon, volume.el);
  const spacer = h("div", { class: "np-controls-spacer" });
  const buttons = h("div", { class: "np-buttons" }, shuffle, prev, play, next, repeat);
  const controlsRow = h("div", { class: "np-controls" }, spacer, buttons, volumeBox);
  const consoleEl = h("div", { class: "np-console" }, titleRow, subtitle, controlsRow, progressRow);
  const playingEl = h("div", { class: "np-card" }, art, consoleEl);

  // Idle: premium macOS-style horizontal layout.
  // Left: Avatar zone reserving space for Mochi (#bot-canvas) with ambient glow
  const idleGlow = h("div", { class: "sp-avatar-glow" });
  const idleAvatarZone = h("div", { class: "sp-idle-avatar-zone" }, idleGlow);

  // Identity row: green dot + "Spotify" bold + "Integration" muted
  const idleSub = h("span", { class: "sp-identity-badge" });
  const idleIdentity = h("div", { class: "sp-identity" },
    dot(green, 6),
    h("span", { class: "sp-identity-name", text: "Spotify" }),
    idleSub,
  );

  // Status row: connection dot + status text
  const idleDot = dot("#22C55E", 5);
  const idleText = h("span", { class: "sp-status-text" });
  const idleStatusRow = h("div", { class: "sp-status-row" }, idleDot, idleText);

  // Header bar: unified single line containing Identity and Status with subtle bullet divider
  const idleHeaderSep = h("span", { class: "sp-header-sep", text: "·" });
  const idleHeader = h("div", { class: "sp-idle-header" }, idleIdentity, idleHeaderSep, idleStatusRow);

  // Primary and secondary copy
  const idleHeadline = h("div", { class: "sp-headline", text: "Your music, your space." });
  const idleSubtitle = h("div", { class: "sp-subtitle" });
  const idleTextGroup = h("div", { class: "sp-idle-text-group" }, idleHeadline, idleSubtitle);

  // Open Spotify CTA button
  const idleAction = h("button", { class: "sp-open-btn" });
  idleAction.addEventListener("click", () => void Bridge.spotifyOpen());
  const idleActionWrap = h("div", { class: "sp-idle-actions" }, idleAction);

  // Right-hand content panel
  const idleContent = h("div", { class: "sp-idle-content" },
    idleHeader,
    idleTextGroup,
    idleActionWrap,
  );

  // Main horizontal flex composition: Left (Avatar Zone) + Right (Content Panel)
  const idleEl = h("div", { class: "sp-idle-card" },
    idleAvatarZone,
    idleContent,
  );

  const el = h("div", { class: "np-root" });
  let showing: "playing" | "idle" | null = null;
  let shownTrack: SpotifyTrack | null = null;
  let playIcon: boolean | null = null;
  let volIconLevel = -1;
  let timer: number | null = null;

  function paintProgress() {
    const s = Spotify.state;
    const d = s.track?.duration ?? 0;
    const pos = dragFraction != null ? dragFraction * d : spotifyPosition(s, Date.now());
    const f = dragFraction ?? (d > 0 ? Math.min(1, Math.max(0, pos / d)) : 0);
    progress.set(f);
    elapsed.textContent = formatTime(f * d);
    remaining.textContent = d > 0 ? `-${formatTime(Math.max(0, d - f * d))}` : "";
  }

  /** The position runs on its own clock, twice a second, only while it plays on screen. */
  function syncTimer() {
    const run = Spotify.state.playing && showing === "playing" && el.isConnected &&
      State.mode === "expanded" && State.view === "overview";
    if (run && timer == null) {
      timer = window.setInterval(() => {
        if (!(Spotify.state.playing && el.isConnected && State.mode === "expanded" && State.view === "overview")) {
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
    const s = Spotify.state;
    if (shownTrack !== track) {
      shownTrack = track;
      title.textContent = isAd(track) ? t("Advertisement") : track.title;
      const sub = [track.artist, track.album].filter((x) => x).join(" · ");
      subtitle.textContent = sub;
      subtitle.style.display = sub ? "" : "none";
    } else if (isAd(track)) {
      title.textContent = t("Advertisement");
    }
    art.title = track.album ? t("{0} — open Spotify", { 0: track.album }) : t("Open Spotify");
    const cover = currentArtwork(s);
    if (cover) {
      if (artImg.getAttribute("src") !== cover) artImg.setAttribute("src", cover);
      art.classList.add("has-art");
    } else {
      art.classList.remove("has-art");
      artImg.removeAttribute("src");
    }

    progress.enabled = !isAd(track) && track.duration > 0;
    paintProgress();

    pulseWave.dataset.active = s.playing ? "true" : "false";
    pulseWave.title = s.playing ? t("Playing") : t("Paused");
    pulseWave.style.display = isAd(track) ? "none" : "";

    shuffle.style.color = s.shuffle ? green : "#6B7079";
    shuffle.title = s.shuffle ? t("Shuffle on") : t("Shuffle off");
    repeat.style.color = s.repeat ? green : "#6B7079";
    repeat.title = s.repeat ? t("Repeat on") : t("Repeat off");
    prev.title = t("Previous");
    next.title = t("Next");
    if (playIcon !== s.playing) {
      playIcon = s.playing;
      clear(play);
      const icon = svg(s.playing ? ICONS.pause : ICONS.play, 13);
      if (!s.playing) icon.style.transform = "translateX(0.5px)";
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
    const installed = Spotify.state.installed || Spotify.state.running;
    // Status dot: green = running/installed, red = not installed
    idleDot.style.background = installed ? "#22C55E" : "#F4505E";
    // Status text: preserved exactly for test assertions and i18n
    idleText.textContent = installed ? t("Not playing") : t("Spotify not installed");
    // Action button: preserved for test assertions
    idleAction.textContent = installed ? t("Open Spotify") : t("Get Spotify");
    // Identity badge: "Integration" or pill subtitle
    idleSub.textContent = t(pillDefinition(SPOTIFY_ID)?.subtitle ?? N_("Integration"));
    // Subtitle below the headline
    idleSubtitle.textContent = installed
      ? t("Nothing playing right now.")
      : t("Install Spotify to listen here.");
  }

  return {
    el,
    sync() {
      const track = Spotify.state.track;
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
