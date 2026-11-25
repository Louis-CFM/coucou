// Notch → Mochi's room: Mochi and your agents in a little room where every
// object is live data. Mochi naps on the bed when nothing runs, works at the
// desk while an agent does, and waits at the door when one asks something;
// the window is your CI and deploys, the frames are your connected tools, the
// clock is the time coded today and the plant is your streak. Port of
// FlowHubRoom.swift; the rules are in core/room.ts.
//
// It only reads what Coucou already has: the island's sessions, cards and
// integration numbers (sent by island/room.ts while the room is on screen),
// the weekly recap's history and which keys are set. Off by default; off, it
// draws nothing and asks nothing. The picture and the logos are the Mac's.

import roomArt from "../../../../NotchBuddy/Assets.xcassets/Room/MochiRoom.imageset/MochiRoom.jpg";
import windowMask from "../../../../NotchBuddy/Assets.xcassets/Room/MochiRoomWindow.imageset/MochiRoomWindow.png";
import stripeLogo from "../../../../NotchBuddy/Assets.xcassets/Room/RoomLogoStripe.imageset/stripe.svg";
import githubLogo from "../../../../NotchBuddy/Assets.xcassets/Room/RoomLogoGitHub.imageset/github.svg";
import vercelLogo from "../../../../NotchBuddy/Assets.xcassets/Room/RoomLogoVercel.imageset/vercel.svg";
import n8nLogo from "../../../../NotchBuddy/Assets.xcassets/Room/RoomLogoN8n.imageset/n8n.svg";
import calcomLogo from "../../../../NotchBuddy/Assets.xcassets/Room/RoomLogoCalcom.imageset/caldotcom.svg";
import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { Bridge, emitToWindow, onEvent } from "../../core/bridge";
import { BotEngine, hexToRGB } from "../../mochi/engine";
import type { BotStateName } from "../../core/layout";
import {
  EMPTY_SNAPSHOT, ROOM_EVENTS, ROOM_KEYS, ROOM_TOOLS, codedLabel, deploysToday, frames, hiddenTools, hiddenToolsRaw,
  isNight, mochiState, plant, roomWeather, spot, today, type Plant, type RoomFrame, type RoomSnapshot, type RoomToday,
  type RoomTool, type RoomToolId, type Spot, type Weather,
} from "../../core/room";
import type { HubContext } from "../shell";
import { animate, windowIsShown } from "../hero";
import { button, card, divider, label, row, toggle } from "../ui";

/** The island's window (WINDOW_LABEL in src-tauri/src/island.rs). */
const ISLAND = "island";
/** As on the island's card (views/views.ts): a click meant for something else
 *  just as the card comes up must not land on Allow. */
const CLICK_GUARD_MS = 600;

// ── The picture ──────────────────────────────────────────────────────────────

/** Where things are in the picture, in its pixels (1344 × 752, drawn at 2×). */
const ART = { w: 1344, h: 752 };
const WINDOW = { x: 24, y: 80, w: 140, h: 345 };
/** The part of the picture the weather is painted in, around the glass. */
const SKY = { x: 0, y: 60, w: 200, h: 390 };
const SCREEN = { x: 968, y: 269, w: 145, h: 88 };
const CLOCK = { x: 668, y: 143 };
/** The soil in the pot on the shelf. */
const POT = { x: 295, y: 231 };
const DOOR = { x: 1176, y: 52, w: 158, h: 590 };
/** The inside of the five frames on the wall. */
const FRAMES = [433, 520, 607, 694, 780].map((x) => ({ x, y: 232, w: 59, h: 79 }));
/** Mochi's feet at each spot. */
const FEET: Record<Spot, { x: number; y: number }> = {
  bed: { x: 250, y: 452 },
  desk: { x: 962, y: 486 },
  door: { x: 1112, y: 648 },
};
const MOCHI_SIZE = 118;

/** The Mac's logos (Simple Icons, CC0), drawn in the tool's colour; width over height. */
const LOGOS: Record<RoomToolId, { src: string; ratio: number }> = {
  stripe: { src: stripeLogo, ratio: 1 },
  github: { src: githubLogo, ratio: 1 },
  vercel: { src: vercelLogo, ratio: 1 },
  n8n: { src: n8nLogo, ratio: 24.4 / 10 },
  calcom: { src: calcomLogo, ratio: 24.4 / 5.4 },
};

// ── Preferences ──────────────────────────────────────────────────────────────

interface RoomPrefs {
  enabled: boolean;
  door: boolean;
  weather: boolean;
  dayNight: boolean;
  hidden: Set<string>;
}

function readKey(key: string): string | null {
  try {
    return window.localStorage?.getItem(key) ?? null;
  } catch {
    return null;
  }
}

function writeKey(key: string, value: string) {
  try {
    window.localStorage?.setItem(key, value);
  } catch {
    // Private storage refused: the switch holds until the window closes.
  }
}

function readPrefs(): RoomPrefs {
  const flag = (key: string, fallback: boolean) => {
    const v = readKey(key);
    return v === null ? fallback : v === "true";
  };
  return {
    enabled: flag(ROOM_KEYS.enabled, false),
    door: flag(ROOM_KEYS.door, true),
    weather: flag(ROOM_KEYS.weather, true),
    dayNight: flag(ROOM_KEYS.dayNight, true),
    hidden: hiddenTools(readKey(ROOM_KEYS.hidden) ?? ""),
  };
}

/** The clock the room reads (the dev preview sets its own). */
let clock = () => new Date();
export function setRoomClock(fn: () => Date) {
  clock = fn;
}

// ── The page ─────────────────────────────────────────────────────────────────

export async function roomPage(page: HTMLElement, ctx: HubContext) {
  const prefs = readPrefs();
  let snap: RoomSnapshot = EMPTY_SNAPSHOT;
  let day: RoomToday = { minutes: 0, allowed: 0, denied: 0, streak: 0 };
  let connected = new Set<string>();
  let left = false;

  const setPref = (key: string, value: boolean) => writeKey(key, String(value));
  /** Draws the room again after a switch; nothing to draw while it is off. */
  let redraw = () => {};

  // Which tools have their keys, read on arrival and once a minute (never per frame).
  const readConnected = async () => {
    const next = new Set<string>();
    for (const tool of ROOM_TOOLS) {
      let all = true;
      for (const key of tool.keys) all = all && ((await Bridge.secretPresent(key)) ?? false);
      if (all) next.add(tool.id);
    }
    connected = next;
  };
  const readToday = async () => {
    day = today(await Bridge.recapHistory(0), clock());
  };
  await readConnected();
  if (prefs.enabled) await readToday();

  const turn = toggle(prefs.enabled, (on) => {
    setPref(ROOM_KEYS.enabled, on);
    ctx.navigate("room");
  });
  turn.setAttribute("aria-label", t("Show the room"));
  turn.title = t("Show the room");
  page.append(ctx.hero("room", t("Mochi's room"),
    t("Mochi and your agents live here. Every object is live data from Coucou and your tools."),
    prefs.enabled ? [turn] : []));

  const toolsCard = card(label(t("Tools on the walls")));
  toolsCard.dataset.anchor = "room.tools";
  const drawTools = () => {
    clear(toolsCard);
    toolsCard.append(label(t("Tools on the walls")));
    ROOM_TOOLS.forEach((tool, i) => {
      if (i > 0) toolsCard.append(divider());
      const on = connected.has(tool.id);
      const badge = h("span", { class: "room-tool-logo" }, logo(tool, 15, 24));
      const trailing = on
        ? toggle(!prefs.hidden.has(tool.id), (show) => {
          if (show) prefs.hidden.delete(tool.id);
          else prefs.hidden.add(tool.id);
          writeKey(ROOM_KEYS.hidden, hiddenToolsRaw(prefs.hidden));
          redraw();
        })
        : button(t("Connect"), () => ctx.navigate("integrations"), "", true);
      trailing.setAttribute("aria-label", tool.name);
      const r = row(tool.name, on ? t("Connected") : t("Not connected"), trailing);
      r.prepend(badge);
      toolsCard.append(r);
    });
  };

  const switchRow = (title: string, detail: string, key: string, value: boolean, onChange: (v: boolean) => void) => {
    const sw = toggle(value, (v) => {
      setPref(key, v);
      onChange(v);
    });
    sw.setAttribute("aria-label", title);
    return row(title, detail, sw);
  };
  const settingsCard = card(
    label(t("In the room")),
    switchRow(t("Show the room"), t("Off, the room draws nothing and uses no CPU."), ROOM_KEYS.enabled, prefs.enabled, () => {
      ctx.navigate("room");
    }),
    divider(),
    switchRow(t("Mochi goes to the door"), t("Permission requests show up under the room. Nothing is allowed without your click."),
      ROOM_KEYS.door, prefs.door, (v) => {
        prefs.door = v;
        redraw();
      }),
    divider(),
    switchRow(t("Weather at the window"), t("From the CI of your main branches on GitHub and your last Vercel deploy."),
      ROOM_KEYS.weather, prefs.weather, (v) => {
        prefs.weather = v;
        redraw();
      }),
    divider(),
    switchRow(t("Day and night"), t("The room gets dark from 8 pm to 7 am."), ROOM_KEYS.dayNight, prefs.dayNight, (v) => {
      prefs.dayNight = v;
      redraw();
    }),
  );
  settingsCard.dataset.anchor = "room.settings";
  drawTools();
  const settings = h("div", { class: "room-settings" }, settingsCard, toolsCard);

  if (!prefs.enabled) {
    page.append(intro(() => {
      setPref(ROOM_KEYS.enabled, true);
      ctx.navigate("room");
    }), settings);
    return;
  }

  // ── On: the room, the card at the door, today's numbers ──
  const scene = new RoomScene();
  const door = h("div", { class: "room-door" });
  const stats = h("div", { class: "hub-stat-row" });
  page.append(scene.el, door, stats, settings);

  let doorKey = "";
  const drawDoor = () => {
    const a = prefs.door ? snap.approval : null;
    const key = a ? `${a.requestId}|${a.question}` : "";
    if (key === doorKey) return;
    doorKey = key;
    clear(door);
    if (a) door.append(doorCard(a));
  };

  const stat = (name: string, value: string, sub: string | null) =>
    h("div", { class: "hub-stat" }, h("div", { class: "label", text: name }), h("b", { text: value }),
      h("div", { class: "sub", text: sub ?? " " }));

  function update() {
    const now = clock();
    const waiting = snap.approval != null;
    const where = spot(waiting, snap.busy, prefs.door);
    scene.set({
      spot: where,
      mochi: mochiState(where, snap),
      weather: prefs.weather ? roomWeather(snap) : "clear",
      night: prefs.dayNight && isNight(now.getHours()),
      plant: plant(day.streak),
      doorLit: waiting,
      frames: frames(snap, connected, prefs.hidden, now),
      coded: codedLabel(day.minutes),
      streak: t("{0}-day streak", { 0: day.streak }),
    });
    drawDoor();
    clear(stats);
    stats.append(
      stat(t("Coded with agents"), codedLabel(day.minutes), null),
      stat(t("Approvals"), String(day.allowed), t("{0} denied", { 0: day.denied })),
      stat(t("Deploys today"), deploysToday(snap, now), null),
      stat(t("Streak"), String(day.streak), t("days in a row")),
    );
  }
  redraw = update;
  update();

  // The island sends what it shows while the room is on screen, and only then.
  let watching = false;
  const watch = (on: boolean) => {
    if (on === watching) return;
    watching = on;
    void emitToWindow(ISLAND, ROOM_EVENTS.watch, on);
  };
  const minute = async () => {
    if (!windowIsShown()) return;
    await Promise.all([readConnected(), readToday()]);
    if (left) return;
    drawTools();
    update();
  };
  const unlisten = await Promise.all([
    onEvent<RoomSnapshot>(ROOM_EVENTS.state, (s) => {
      snap = { ...EMPTY_SNAPSHOT, ...s };
      update();
    }),
    onEvent<boolean>("hub-visible", (shown) => {
      watch(shown);
      if (shown) void minute();
    }),
  ]);
  const timer = window.setInterval(() => void minute(), 60_000);
  watch(windowIsShown());
  ctx.onLeave = () => {
    left = true;
    watch(false);
    window.clearInterval(timer);
    for (const off of unlisten) off();
  };

  /** A permission request, answered in the room: the island's card's choices, each one a click. */
  function doorCard(a: NonNullable<RoomSnapshot["approval"]>): HTMLElement {
    const shownAt = performance.now();
    if (a.question) {
      // A question's options live in the island.
      return h("div", { class: "hub-card room-card" },
        h("div", { class: "room-card-head" },
          h("i", { class: "room-dot", style: "background:#3B9EFF" }),
          h("span", { class: "room-card-title", text: t("{0} has a question", { 0: a.asker }) }),
          h("span", { class: "spacer" }),
          button(t("Open the island"), () => void emitToWindow(ISLAND, ROOM_EVENTS.open), "primary")));
    }
    const buttons: HTMLButtonElement[] = [];
    const answer = (decision: "allow" | "deny" | "terminal") => () => {
      if (performance.now() - shownAt < CLICK_GUARD_MS) return;
      for (const b of buttons) b.disabled = true;
      void emitToWindow(ISLAND, ROOM_EVENTS.decide, { requestId: a.requestId, decision });
    };
    buttons.push(button(t("Deny"), answer("deny")));
    // Antigravity also hands the command back to its own prompt, as the island does.
    if (a.pillId === "agent_antigravity") buttons.push(button(t("Reply in terminal"), answer("terminal")));
    const allow = button(t("Allow"), answer("allow"), "primary");
    buttons.push(allow);
    const head = h("div", { class: "room-card-head" },
      h("i", { class: "room-dot", style: "background:#FFB340" }),
      h("span", { class: "room-card-title", text: t("{0} needs permission", { 0: a.asker }) }));
    if (a.queued > 0) head.append(h("span", { class: "room-card-count", text: `1/${a.queued + 1}` }));
    return h("div", { class: "hub-card room-card" },
      head,
      h("pre", { class: "room-command", text: a.command || a.tool }),
      h("div", { class: "room-card-actions" }, ...buttons.slice(0, -1), h("span", { class: "spacer" }), allow));
  }
}

/** Off: what the room is, and a button to turn it on. */
function intro(turnOn: () => void): HTMLElement {
  const line = (text: string) => h("li", { text });
  return h("div", { class: "hub-card room-intro" },
    h("div", { class: "room-intro-title", text: t("A room that shows your day") }),
    h("ul", {},
      line(t("The desk: Mochi works there while an agent runs.")),
      line(t("The door: Mochi waits there when an agent asks something, and you answer right here.")),
      line(t("The window: sun when your CI and deploys are green, rain when a build fails, a storm when a deploy fails.")),
      line(t("The frames: your connected tools (Stripe, GitHub, Vercel, n8n, Cal.com). Click one to open it.")),
      line(t("The plant grows with your streak. When nothing runs, Mochi naps on the bed.")),
    ),
    h("div", {}, button(t("Turn on the room"), turnOn, "primary")));
}

/** A tool's real logo in its colour, `height` tall (a wordmark as wide as `maxWidth` allows). */
function logo(tool: RoomTool, height: number, maxWidth: number, scaled = false): HTMLElement {
  const { src, ratio } = LOGOS[tool.id];
  const w = Math.min(maxWidth, height * ratio);
  const px = (n: number) => (scaled ? `calc(${n}px * var(--s, 1))` : `${n}px`);
  const el = h("span", { class: "room-logo", "aria-hidden": "true" });
  el.style.width = px(w);
  el.style.height = px(w / ratio);
  el.style.background = tool.color;
  for (const p of ["mask-image", "-webkit-mask-image"]) el.style.setProperty(p, `url("${src}")`);
  return el;
}

function weatherText(w: Weather): string {
  switch (w) {
    case "sun": return t("All green: CI and deploys");
    case "cloudy": return t("Something is building");
    case "rain": return t("A build failed");
    case "storm": return t("The last deploy failed");
    case "clear": return t("Connect GitHub or Vercel for the weather");
  }
}

// ── The scene ────────────────────────────────────────────────────────────────

interface SceneModel {
  spot: Spot;
  mochi: BotStateName;
  weather: Weather;
  night: boolean;
  plant: Plant;
  doorLit: boolean;
  frames: (RoomFrame | null)[];
  coded: string;
  streak: string;
}

/**
 * The painted room and, over it, one canvas with everything that moves, in
 * the picture's pixels scaled to the page: the weather in the window, the
 * code on the screen, the clock, the plant, the light at the door, Mochi. The
 * frames on the wall are buttons. Drawn by the window's animation loop
 * (hub/hero.ts): nothing while the window is hidden or the room scrolled away.
 */
class RoomScene {
  readonly el: HTMLElement;
  private canvas = h("canvas", { class: "room-canvas" }) as HTMLCanvasElement;
  private sky = document.createElement("canvas");
  private mask = new Image();
  private model: SceneModel | null = null;
  private slots: HTMLElement[];
  private slotKeys: string[] = [];
  private codedTag = h("span", { class: "room-tag" });
  private streakTag = h("span", { class: "room-tag" });
  private windowSpot = h("div", { class: "room-hot" });
  private scale = 0;
  // Mochi, moved frame by frame.
  private engine = new BotEngine();
  private feet: { x: number; y: number } | null = null;
  private hop = 0;

  constructor() {
    this.mask.src = windowMask;
    this.engine.setState("sleeping", true);
    const art = h("img", { class: "room-art", src: roomArt, alt: "" });
    this.slots = FRAMES.map((f) => {
      const slot = h("div", { class: "room-frame" });
      place(slot, f.x, f.y, f.w, f.h);
      return slot;
    });
    place(this.windowSpot, WINDOW.x, WINDOW.y, WINDOW.w, WINDOW.h);
    const codedAt = h("div", { class: "room-tag-at" }, this.codedTag);
    placeCenter(codedAt, CLOCK.x, CLOCK.y + 70);
    const streakAt = h("div", { class: "room-tag-at" }, this.streakTag);
    placeCenter(streakAt, POT.x, 302);
    this.codedTag.title = t("Coded with agents");
    this.streakTag.title = t("Streak");
    this.el = h("div", { class: "room-scene", role: "group", "aria-label": t("Mochi's room") },
      art, this.canvas, this.windowSpot, ...this.slots, codedAt, streakAt);
    animate(this.canvas, (dt, time) => this.draw(dt, time));
  }

  set(model: SceneModel) {
    this.model = model;
    this.codedTag.textContent = model.coded;
    this.streakTag.textContent = model.streak;
    this.windowSpot.title = weatherText(model.weather);
    model.frames.forEach((f, i) => {
      const key = f ? `${f.tool.id}|${f.value}|${f.label}|${f.dot}` : "";
      if (key === this.slotKeys[i]) return;
      this.slotKeys[i] = key;
      clear(this.slots[i]);
      if (f) this.slots[i].append(frameButton(f));
    });
  }

  private draw(dt: number, time: number) {
    const m = this.model;
    if (!m) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    const w = this.canvas.clientWidth;
    if (w === 0) return;
    const hgt = this.canvas.clientHeight;
    if (this.canvas.width !== Math.round(w * dpr) || this.canvas.height !== Math.round(hgt * dpr)) {
      this.canvas.width = Math.round(w * dpr);
      this.canvas.height = Math.round(hgt * dpr);
    }
    const s = w / ART.w;
    if (s !== this.scale) {
      this.scale = s;
      this.el.style.setProperty("--s", String(s));
    }
    const ctx = this.canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr * s, 0, 0, dpr * s, 0, 0);
    ctx.clearRect(0, 0, ART.w, ART.h);
    this.paintWindow(ctx, time, m.weather, m.night, dpr * s);
    paintScreen(ctx, time, m.spot === "desk");
    paintClock(ctx, clock());
    paintPlant(ctx, time, m.plant);
    paintDoor(ctx, time, m.doorLit);
    paintLight(ctx, m.night);
    this.stepMochi(ctx, dt, m.spot, m.mochi);
  }

  /** The weather, painted apart and cut to the glass by the window's mask. */
  private paintWindow(ctx: CanvasRenderingContext2D, time: number, weather: Weather, night: boolean, k: number) {
    if (!this.mask.complete || this.mask.naturalWidth === 0) return;
    const sky = this.sky;
    const sw = Math.ceil(SKY.w * k), sh = Math.ceil(SKY.h * k);
    if (sky.width !== sw || sky.height !== sh) {
      sky.width = sw;
      sky.height = sh;
    }
    const c = sky.getContext("2d");
    if (!c) return;
    c.setTransform(k, 0, 0, k, -SKY.x * k, -SKY.y * k);
    c.globalCompositeOperation = "source-over";
    c.clearRect(SKY.x, SKY.y, SKY.w, SKY.h);
    paintSky(c, time, weather, night);
    c.globalCompositeOperation = "destination-in";
    c.drawImage(this.mask, 0, 0, ART.w, ART.h);
    c.globalCompositeOperation = "source-over";
    ctx.drawImage(sky, SKY.x, SKY.y, SKY.w, SKY.h);
  }

  /** Mochi hops to his spot, then takes its face. */
  private stepMochi(ctx: CanvasRenderingContext2D, dt: number, where: Spot, state: BotStateName) {
    const target = FEET[where];
    const here = this.feet ?? { ...target };
    const dx = target.x - here.x, dy = target.y - here.y;
    const distance = Math.hypot(dx, dy);
    if (distance > 1) {
      const move = Math.min(distance, 320 * dt);
      here.x += (dx / distance) * move;
      here.y += (dy / distance) * move;
      this.hop += dt * 12;
      if (this.engine.state !== "idle") this.engine.setState("idle");
    } else {
      here.x = target.x;
      here.y = target.y;
      this.hop = 0;
      if (this.engine.state !== state) this.engine.setState(state);
    }
    this.feet = here;
    this.engine.update(dt);
    const size = MOCHI_SIZE;
    const lift = Math.abs(Math.sin(this.hop)) * size * 0.08;
    ctx.fillStyle = "rgba(0,0,0,0.3)";
    ctx.beginPath();
    ctx.ellipse(here.x, here.y - size * 0.005, size * 0.26, size * 0.045, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.save();
    ctx.translate(here.x - size / 2, here.y - size * 0.92 - lift);
    this.engine.draw(ctx, size, size);
    ctx.restore();
  }
}

/** A connected tool in its frame: its logo, today's number, a word. A click opens the service. */
function frameButton(f: RoomFrame): HTMLElement {
  // A long value (a time with AM / PM, a workflow's name) gets smaller rather than cut short.
  const value = h("span", { class: f.value.length > 6 ? "room-frame-value long" : "room-frame-value" });
  if (f.dot) value.append(h("i", { class: `room-dot ${f.dot}` }));
  value.append(h("span", { text: f.value }));
  return h("button", {
    class: "room-frame-btn",
    title: f.tool.name,
    "aria-label": `${f.tool.name}: ${f.value}, ${f.label}`,
    onclick: () => {
      if (f.tool.id === "n8n") void Bridge.openN8n();
      else void Bridge.openUrl(f.tool.url);
    },
  }, logo(f.tool, 17, 17 * 2.6, true), value, h("span", { class: "room-frame-label", text: f.label }));
}

/** Positions `el` over the picture, in its pixels, as percentages. */
function place(el: HTMLElement, x: number, y: number, w: number, hgt: number) {
  el.style.left = `${(x / ART.w) * 100}%`;
  el.style.top = `${(y / ART.h) * 100}%`;
  el.style.width = `${(w / ART.w) * 100}%`;
  el.style.height = `${(hgt / ART.h) * 100}%`;
}

function placeCenter(el: HTMLElement, x: number, y: number) {
  el.style.left = `${(x / ART.w) * 100}%`;
  el.style.top = `${(y / ART.h) * 100}%`;
}

// ── What moves, in the picture's pixels ──────────────────────────────────────

function rgba(hex: string, alpha: number): string {
  const [r, g, b] = hexToRGB(hex);
  return `rgba(${Math.round(r * 255)},${Math.round(g * 255)},${Math.round(b * 255)},${Math.max(0, Math.min(1, alpha))})`;
}

function paintSky(c: CanvasRenderingContext2D, time: number, weather: Weather, night: boolean) {
  const w = WINDOW;
  let sky: [string, string];
  if (weather === "storm") sky = ["#262B40", "#3D4560"];
  else if (weather === "rain") sky = night ? ["#151C33", "#2B3552"] : ["#4A5A7A", "#7D8CA8"];
  else if (night) sky = ["#0B1430", "#1C2B58"];
  else if (weather === "cloudy") sky = ["#7FA6D8", "#C9D8EC"];
  else sky = ["#5AA8FF", "#BFE2FF"];
  const grad = c.createLinearGradient(0, w.y, 0, w.y + w.h);
  grad.addColorStop(0, sky[0]);
  grad.addColorStop(1, sky[1]);
  c.fillStyle = grad;
  c.fillRect(w.x - 10, w.y - 10, w.w + 20, w.h + 20);
  const fair = weather === "sun" || weather === "clear";
  if (night) {
    for (let i = 0; i < 16; i++) {
      const x = w.x + 10 + ((i * 53) % 120), y = w.y + 14 + ((i * 97) % 250);
      c.fillStyle = `rgba(255,255,255,${0.35 + 0.65 * Math.abs(Math.sin(time * 1.3 + i))})`;
      c.beginPath();
      c.arc(x + 1.3, y + 1.3, 1.3, 0, Math.PI * 2);
      c.fill();
    }
    if (fair) {
      c.fillStyle = "#F5F1DC";
      c.beginPath();
      c.arc(115, 145, 17, 0, Math.PI * 2);
      c.fill();
    }
  } else if (fair) {
    c.fillStyle = rgba("#FFD66B", 0.25 + 0.1 * Math.sin(time * 1.2));
    c.beginPath();
    c.arc(110, 150, 38, 0, Math.PI * 2);
    c.fill();
    c.fillStyle = "#FFD66B";
    c.beginPath();
    c.arc(110, 150, 22, 0, Math.PI * 2);
    c.fill();
  }
  if (!fair) {
    const tone = weather === "storm" ? "#59617A" : night ? "#3A4566" : "#EEF2F8";
    // Three clouds at their own height, size and speed, crossing the glass.
    for (const [y, size, speed, phase] of [[150, 1, 7, 0], [236, 0.75, 4.5, 120], [310, 0.9, 5.5, 60]]) {
      const span = w.w + 160;
      cloud(c, w.x - 110 + ((time * speed + phase) % span), y, size, tone);
    }
  }
  if (weather === "rain" || weather === "storm") {
    // Drops at random places, speeds and lengths, falling with the wind.
    const count = weather === "storm" ? 46 : 32;
    c.lineWidth = 1.6;
    c.lineCap = "round";
    for (let i = 0; i < count; i++) {
      const seed = i * 12.9898;
      const r1 = Math.abs(Math.sin(seed) * 43758.5453) % 1;
      const r2 = Math.abs(Math.sin(seed * 1.7) * 24634.6345) % 1;
      const length = 9 + r1 * 9;
      const fall = (time * (360 + r2 * 220) + r2 * 900) % (w.h + 40);
      const x = w.x + r1 * (w.w + 30) - fall * 0.12;
      const y = w.y - 20 + fall;
      c.strokeStyle = rgba("#C7DBFF", 0.35 + r2 * 0.4);
      c.beginPath();
      c.moveTo(x, y);
      c.lineTo(x - length * 0.25, y + length);
      c.stroke();
    }
  }
  if (weather === "storm" && time % 5 < 0.12) {
    c.fillStyle = "rgba(255,255,255,0.55)";
    c.fillRect(w.x - 10, w.y - 10, w.w + 20, w.h + 20);
  }
}

/** A soft cloud: a flat base and three puffs, lighter on top. */
function cloud(c: CanvasRenderingContext2D, x: number, y: number, k: number, color: string) {
  const grad = c.createLinearGradient(0, y - 46 * k, 0, y + 12 * k);
  grad.addColorStop(0, rgba(color, 1));
  grad.addColorStop(1, rgba(color, 0.78));
  c.fillStyle = grad;
  c.beginPath();
  c.roundRect(x, y - 14 * k, 96 * k, 26 * k, 13 * k);
  c.moveTo(x + 48 * k, y - 15 * k);
  c.arc(x + 29 * k, y - 15 * k, 19 * k, 0, Math.PI * 2);
  c.moveTo(x + 80 * k, y - 24 * k);
  c.arc(x + 58 * k, y - 24 * k, 22 * k, 0, Math.PI * 2);
  c.moveTo(x + 92 * k, y - 16 * k);
  c.arc(x + 78 * k, y - 16 * k, 14 * k, 0, Math.PI * 2);
  c.fill("nonzero");
}

/** Code typing in while an agent works; a cursor blinking otherwise. */
function paintScreen(c: CanvasRenderingContext2D, time: number, busy: boolean) {
  const r = SCREEN;
  c.save();
  c.beginPath();
  c.rect(r.x, r.y, r.w, r.h);
  c.clip();
  c.fillStyle = "#0C1226";
  c.fillRect(r.x, r.y, r.w, r.h);
  if (busy) {
    const colors = ["#A78BFA", "#5AA8FF", "#34D399", "#FB923C"];
    const step = time / 0.22;
    const first = Math.floor(step);
    const typed = step - first;
    for (let i = 0; i < 7; i++) {
      const line = first + i;
      const width = 20 + ((line * 37) % 72);
      const indent = ((line * 13) % 3) * 10;
      c.fillStyle = rgba(colors[line % colors.length], 0.9);
      c.beginPath();
      c.roundRect(r.x + 8 + indent, r.y + 7 + i * 11, i === 6 ? width * typed : width, 4, 2);
      c.fill();
    }
    c.fillStyle = rgba("#8C73F2", 0.06);
    c.fillRect(r.x, r.y, r.w, r.h);
  } else if (Math.floor(time * 1.6) % 2 === 0) {
    c.fillStyle = rgba("#5AA8FF", 0.8);
    c.fillRect(r.x + 10, r.y + 10, 7, 10);
  }
  c.restore();
}

/** The real time, with a second hand that ticks. */
function paintClock(c: CanvasRenderingContext2D, now: Date) {
  const seconds = now.getSeconds() + now.getMilliseconds() / 1000;
  const minutes = now.getMinutes() + seconds / 60;
  const hours = (now.getHours() % 12) + minutes / 60;
  const ink = "#2B2236";
  hand(c, hours / 12, 24, 5, ink);
  hand(c, minutes / 60, 34, 4, ink);
  hand(c, Math.floor(seconds) / 60, 38, 1.6, "#FB923C");
  c.fillStyle = ink;
  c.beginPath();
  c.arc(CLOCK.x, CLOCK.y, 4, 0, Math.PI * 2);
  c.fill();
}

function hand(c: CanvasRenderingContext2D, turn: number, length: number, width: number, color: string) {
  const a = turn * 2 * Math.PI;
  c.strokeStyle = color;
  c.lineWidth = width;
  c.lineCap = "round";
  c.beginPath();
  c.moveTo(CLOCK.x, CLOCK.y);
  c.lineTo(CLOCK.x + Math.sin(a) * length, CLOCK.y - Math.cos(a) * length);
  c.stroke();
}

/** The streak plant, swaying a little in its pot. */
function paintPlant(c: CanvasRenderingContext2D, time: number, stage: Plant) {
  c.save();
  c.translate(POT.x, POT.y);
  c.rotate(Math.sin(time * 1.1) * 0.05);
  const dark = "#2FB86C", light = "#3DDC84";
  if (stage === "seed") {
    c.fillStyle = "#C9A27A";
    c.beginPath();
    c.ellipse(0, -2, 4, 3, 0, 0, Math.PI * 2);
    c.fill();
  } else if (stage === "sprout") {
    stem(c, 18, dark);
    leaf(c, 0, -16, -0.9, 0.7, light);
    leaf(c, 0, -16, 0.9, 0.7, dark);
  } else {
    stem(c, 50, dark);
    leaf(c, -1, -18, -0.95, 1, light);
    leaf(c, 1, -30, 0.85, 1, dark);
    leaf(c, 0, -42, -0.6, 0.85, light);
    if (stage === "bloom") {
      c.fillStyle = "#F472B6";
      for (let k = 0; k < 5; k++) {
        const a = (k / 5) * 2 * Math.PI;
        c.beginPath();
        c.arc(Math.cos(a) * 6, -58 + Math.sin(a) * 6, 5, 0, Math.PI * 2);
        c.fill();
      }
      c.fillStyle = "#FFD66B";
      c.beginPath();
      c.arc(0, -58, 4, 0, Math.PI * 2);
      c.fill();
    }
  }
  c.restore();
}

function stem(c: CanvasRenderingContext2D, height: number, color: string) {
  c.strokeStyle = color;
  c.lineWidth = 4;
  c.lineCap = "round";
  c.beginPath();
  c.moveTo(0, 0);
  c.quadraticCurveTo(3, -height / 2, 0, -height);
  c.stroke();
}

function leaf(c: CanvasRenderingContext2D, x: number, y: number, angle: number, size: number, color: string) {
  c.save();
  c.translate(x, y);
  c.rotate(angle);
  c.fillStyle = color;
  c.beginPath();
  c.ellipse(0, -9 * size, 6 * size, 11 * size, 0, 0, Math.PI * 2);
  c.fill();
  c.restore();
}

/** Someone is at the door: warm light around it, breathing. */
function paintDoor(c: CanvasRenderingContext2D, time: number, lit: boolean) {
  if (!lit) return;
  const d = DOOR;
  const a = 0.42 + 0.22 * Math.sin(time * 3);
  c.save();
  c.globalCompositeOperation = "lighter";
  const glow = c.createRadialGradient(d.x + d.w / 2, d.y + d.h / 2, 40, d.x + d.w / 2, d.y + d.h / 2, 300);
  glow.addColorStop(0, rgba("#FFBE5A", a));
  glow.addColorStop(1, "rgba(0,0,0,0)");
  c.fillStyle = glow;
  c.fillRect(d.x - 220, d.y - 60, d.w + 440, d.h + 120);
  // The light under the door
  c.fillStyle = rgba("#FFCF7A", a + 0.2);
  c.fillRect(d.x + 8, d.y + d.h - 6, d.w - 16, 6);
  c.restore();
}

/** Day: the window lights the room a little. Night: the room is dimmer, the lamp warmer. */
function paintLight(c: CanvasRenderingContext2D, night: boolean) {
  c.save();
  if (night) {
    c.fillStyle = "rgba(0,0,0,0.14)";
    c.fillRect(0, 0, ART.w, ART.h);
  }
  c.globalCompositeOperation = "lighter";
  const [x, y, r0, r1, color, alpha] = night ? [905, 330, 10, 260, "#FFB45A", 0.16] as const : [120, 260, 20, 520, "#9CC8FF", 0.12] as const;
  const g = c.createRadialGradient(x, y, r0, x, y, r1);
  g.addColorStop(0, rgba(color, alpha));
  g.addColorStop(1, "rgba(0,0,0,0)");
  c.fillStyle = g;
  c.fillRect(0, 0, ART.w, ART.h);
  c.restore();
}
