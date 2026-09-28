import { BotEngine } from "../bot/engine.js";
import { appState } from "../core/state.js";
import { IslandStateMachine } from "../core/fsm.js";
import {
  IslandConst,
  islandSize,
  type AgentLayoutMode,
  type IslandMode,
  type IslandView,
} from "../core/types.js";
import { audio } from "../services/audio.js";
import { permissionDecision } from "../bridge/tauri.js";
import { bindViewControls, syncViews } from "./views.js";

const STAGE_W = 720;
const STAGE_H = 320;

function modeLevel(m: IslandMode): number {
  switch (m) {
    case "hidden":
      return 0;
    case "compact":
      return 1;
    case "expanded":
      return 2;
  }
}

function defaultView(): IslandView {
  return appState.tasks.length > 0 ? "overview" : "empty";
}

function hexRgb(hex: string): [number, number, number] {
  const h = hex.replace("#", "");
  const n = parseInt(h.length === 3 ? h.replace(/./g, (c) => c + c) : h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function rgba(c: [number, number, number], a: number): string {
  return `rgba(${c[0]},${c[1]},${c[2]},${a})`;
}

function mixRgb(
  a: [number, number, number],
  b: [number, number, number],
  t: number,
): [number, number, number] {
  return [
    Math.round(a[0] + (b[0] - a[0]) * t),
    Math.round(a[1] + (b[1] - a[1]) * t),
    Math.round(a[2] + (b[2] - a[2]) * t),
  ];
}

export interface IslandController {
  fsm: IslandStateMachine;
  expandTo: (view: IslandView) => void;
  collapse: () => void;
  reveal: () => void;
}

export function startIsland(root: HTMLElement): IslandController {
  const island = root.querySelector("#island") as HTMLElement;
  const botwrap = root.querySelector("#botwrap") as HTMLElement;
  const botCanvas = root.querySelector("#botc") as HTMLCanvasElement;
  const agentsRoot = root.querySelector("#agents") as HTMLElement;
  const cdBar = root.querySelector("#cd") as HTMLElement;

  const fsm = new IslandStateMachine();
  let prevMode: IslandMode = "hidden";
  let wasInIsland = false;
  let lastActivity = Date.now();
  let lastFrame = 0;
  let botHoverTimer: number | null = null;
  let botHovering = false;
  const slaps: number[] = [];
  let dizzyTimer: number | null = null;
  let greetingDone = false;

  const agentEls = new Map<string, HTMLElement>();
  const agentBots = new Map<string, BotEngine>();

  const bot = new BotEngine(botCanvas, {
    playSound: (n) => void audio.play(n),
  });

  audio.setVolume(appState.soundVolume);
  audio.setEnabled(appState.soundEnabled);

  function touchActivity(): void {
    lastActivity = Date.now();
  }

  function setMode(mode: IslandMode, view?: IslandView): void {
    const shrinking = modeLevel(mode) < modeLevel(prevMode);
    island.classList.toggle("closing", shrinking);
    const was = prevMode;
    prevMode = mode;
    appState.setMode(mode);
    if (view !== undefined) appState.setView(view);
    applyLayout();

    if (mode === "expanded" && was !== "expanded") {
      void audio.play("open");
      bot.blink();
    }
    if (was === "expanded" && mode !== "expanded") {
      void audio.play("close");
      appState.isPinned = false;
    }
  }

  function expandTo(view: IslandView): void {
    touchActivity();
    if (appState.mode === "expanded") {
      appState.setView(view);
      island.classList.remove("closing");
      applyLayout();
    } else {
      setMode("expanded", view);
    }
  }

  function collapse(): void {
    appState.isPinned = false;
    if (fsm.state === "home") {
      fsm.mouseLeft();
    }
    appState.syncView();
    const next = appState.tasks.length > 0 ? "compact" : "hidden";
    setMode(next, defaultView());
  }

  function applyLayout(): void {
    const mode = appState.mode;
    const view = appState.view;
    const chatCount = appState.chatHistory.length;
    const { width, height } = islandSize(mode, view, undefined, undefined, chatCount);

    island.style.width = `${width}px`;
    island.style.height = `${height}px`;
    island.dataset.mode = mode;
    island.dataset.view = view;

    let botCx: number;
    let botCy: number;
    let botD: number;
    let botOpacity: number;

    if (mode === "hidden") {
      botCx = 46;
      botCy = 16;
      botD = 6;
      botOpacity = 0;
    } else if (mode === "compact") {
      botCx = 27;
      botCy = 16;
      botD = 20;
      botOpacity = 1;
    } else {
      const layout = IslandConst.viewLayouts[view];
      botCx = layout.botX;
      // Match macOS: center in the fixed ~84pt content card under the header.
      botCy =
        layout.botY ?? 42 + (height - 42 - 84) / 2 + 84 / 2;
      botD = layout.botDiameter;
      if (view === "uploading") {
        botCx =
          46 +
          appState.uploadProgress * (width - 10 - 42 - 78 - 46);
        botCy = 36 + 77;
      }
      botOpacity = botD > 0 ? 1 : 0;
    }

    const cs = Math.max(botD / 0.6, 1);
    Object.assign(botwrap.style, {
      left: `${botCx - cs / 2}px`,
      top: `${botCy - cs / 2}px`,
      width: `${cs}px`,
      height: `${cs}px`,
      opacity: String(botOpacity),
    });

    layoutAgents(
      mode === "expanded" ? IslandConst.viewLayouts[view].agentMode : "none",
      width,
      height,
    );

    syncViews(island, appState);
    updateCountdown();
    void positionWindow();
  }

  function ensureAgentEl(id: string, color: string, label: string): void {
    if (agentEls.has(id)) return;
    const el = document.createElement("div");
    el.className = "agent";
    el.dataset.id = id;
    const c = hexRgb(color);
    const lbl = mixRgb(c, [255, 255, 255], 0.55);
    el.style.setProperty("--bg", rgba(c, 0.16));
    el.style.setProperty("--lbl", rgba(lbl, 1));
    el.innerHTML = `<canvas></canvas><span class="lbl">${label}</span>`;
    agentsRoot.appendChild(el);
    agentEls.set(id, el);
    const miniCanvas = el.querySelector("canvas") as HTMLCanvasElement;
    agentBots.set(
      id,
      new BotEngine(miniCanvas, { mini: true, bodyColor: color }),
    );
    el.addEventListener("click", (e) => {
      e.stopPropagation();
      appState.setFocus(id);
      expandTo("overview");
      void audio.play("blip");
    });
  }

  function layoutAgents(mode: AgentLayoutMode, w: number, h: number): void {
    const focusId = appState.focusId;
    const others = appState.tasks.filter((t) => t.id !== focusId);

    for (const task of appState.tasks) {
      ensureAgentEl(task.id, task.color, task.name.slice(0, 14));
    }

    const gridList =
      mode === "grid"
        ? appState.tasks.filter((t) => t.id !== focusId)
        : others;

    for (const [id, el] of agentEls) {
      const canvas = el.querySelector("canvas") as HTMLElement;
      const i = gridList.findIndex((t) => t.id === id);
      const mini = agentBots.get(id);

      if (mode === "none" || i < 0 || i > 3) {
        el.style.opacity = "0";
        el.style.pointerEvents = "none";
        el.classList.remove("pill");
        continue;
      }

      el.style.opacity = "1";
      el.style.pointerEvents = "auto";
      el.style.setProperty("--d", `${i * 0.035}s`);

      let L: number;
      let T: number;
      let W: number;
      let H: number;
      let cs: number;
      let cl: number;
      let ct: number;
      let pill = false;
      const n = Math.min(gridList.length, 4);

      if (mode === "grid") {
        const d = 9.5;
        const sp = 6;
        const pos =
          n === 1
            ? [[0, 0]]
            : n === 2
              ? [
                  [-sp, 0],
                  [sp, 0],
                ]
              : n === 3
                ? [
                    [-sp, -sp],
                    [sp, -sp],
                    [0, sp],
                  ]
                : [
                    [-sp, -sp],
                    [sp, -sp],
                    [-sp, sp],
                    [sp, sp],
                  ];
        const cx = w - 27 + pos[i][0];
        const cy = 16 + pos[i][1];
        W = H = d;
        L = cx - d / 2;
        T = cy - d / 2;
        cs = d / 0.6;
        cl = (W - cs) / 2;
        ct = (H - cs) / 2;
      } else if (mode === "column") {
        const d = 16;
        const cx = w - 10 - 21;
        const cy = 36 + 14 + i * 24;
        W = H = d;
        L = cx - d / 2;
        T = cy - d / 2;
        cs = d / 0.6;
        cl = (W - cs) / 2;
        ct = (H - cs) / 2;
      } else {
        pill = true;
        W = 132;
        H = 34;
        const col = i % 2;
        const row = Math.floor(i / 2);
        const rows = Math.ceil(n / 2);
        const cardX = 10 + 332;
        const cardY = 36;
        const cardH = h - 46;
        const gap = 8;
        const blockH = rows * H + (rows - 1) * gap;
        L = cardX + 8 + col * (W + gap);
        // Center the pill block in the right card (same as macOS Spacers).
        T = cardY + Math.max(0, (cardH - blockH) / 2) + row * (H + gap);
        cs = 24 / 0.6;
        cl = 17 - cs / 2;
        ct = H / 2 - cs / 2;
      }

      Object.assign(el.style, {
        left: `${L}px`,
        top: `${T}px`,
        width: `${W}px`,
        height: `${H}px`,
      });
      Object.assign(canvas.style, {
        left: `${cl}px`,
        top: `${ct}px`,
        width: `${cs}px`,
        height: `${cs}px`,
      });
      el.classList.toggle("pill", pill);
      mini?.setState(appState.tasks.find((t) => t.id === id)?.state ?? "idle");
    }
  }

  function updateCountdown(): void {
    if (!cdBar) return;
    if (appState.mode !== "expanded" || appState.isPinned) {
      cdBar.style.width = "0";
      return;
    }
    const intervalMs = appState.autoCloseInterval * 1000;
    const elapsed = Date.now() - lastActivity;
    const remaining = Math.max(0, 1 - elapsed / intervalMs);
    cdBar.style.width = `${remaining * (islandSize("expanded", appState.view).width - 40)}px`;
  }

  async function positionWindow(): Promise<void> {
    const { positionIsland } = await import("../bridge/tauri.js");
    await positionIsland(STAGE_W, STAGE_H);
  }

  fsm.onTransition = (from, to) => {
    switch (to) {
      case "hidden":
        setMode("hidden");
        break;
      case "petit": {
        if (from === "coucou") {
          greetingDone = false;
        } else if (from === "hidden") {
          void audio.play("peek");
        }
        setMode("compact");
        if (from === "coucou") {
          appState.setView(defaultView());
        }
        if (!wasInIsland) {
          fsm.mouseLeft();
        }
        break;
      }
      case "home":
        expandTo(defaultView());
        if (!wasInIsland) {
          fsm.mouseLeft();
        }
        break;
      case "coucou":
        expandTo("greeting");
        bot.greet();
        void audio.play("greet");
        window.setTimeout(() => {
          if (!greetingDone) {
            greetingDone = true;
            fsm.greetComplete();
          }
        }, 1600);
        break;
    }
  };

  const decidePermission = async (
    decision: "allow" | "always" | "deny",
  ): Promise<void> => {
    const session = appState.pendingApproval?.sessionId;
    if (session) {
      await permissionDecision(session, decision);
    }
    appState.pendingApproval = null;
    appState.isPinned = false;
    void audio.play(decision === "deny" ? "blip" : "approve");
    window.setTimeout(collapse, 650);
  };

  window.__coucou = {
    ...window.__coucou,
    permissionDecision: decidePermission,
  };

  bindViewControls(island, appState, {
    goView: (v) => {
      touchActivity();
      if (v === "settings") {
        expandTo("settings");
        return;
      }
      expandTo(v === "overview" && !appState.tasks.length ? "empty" : v);
    },
    collapse,
    permissionDecision: decidePermission,
    appendPrompt: (text, role = "user") => {
      appState.appendChat(role, text);
      touchActivity();
    },
    playSound: (n) => void audio.play(n),
  });

  island.addEventListener("pointerenter", () => {
    wasInIsland = true;
    touchActivity();
    fsm.mouseEntered();
  });

  island.addEventListener("pointerleave", () => {
    wasInIsland = false;
    fsm.mouseLeft();
  });

  island.addEventListener("pointermove", () => touchActivity());

  island.addEventListener("click", (e) => {
    if ((e.target as HTMLElement).closest("[data-act],[data-go],button,input,label")) {
      return;
    }
    if (fsm.state === "petit") {
      fsm.click();
    }
  });

  botwrap.addEventListener("pointerenter", () => {
    if (appState.mode !== "expanded") return;
    botHovering = true;
    bot.blink();
    void audio.play("hover");
    if (botHoverTimer !== null) window.clearTimeout(botHoverTimer);
    botHoverTimer = window.setTimeout(() => {
      if (botHovering && !appState.stateOverride) {
        bot.emote("love", 2000);
      }
    }, 1900);
  });

  botwrap.addEventListener("pointerleave", () => {
    botHovering = false;
    if (botHoverTimer !== null) {
      window.clearTimeout(botHoverTimer);
      botHoverTimer = null;
    }
  });

  botwrap.addEventListener("click", (e) => {
    e.stopPropagation();
    if (appState.mode !== "expanded") {
      expandTo(defaultView());
      return;
    }
    slapBot();
  });

  function slapBot(): void {
    const now = Date.now();
    while (slaps.length && now - slaps[0] > 1700) slaps.shift();
    slaps.push(now);
    void audio.play("slap");
    bot.squash();
    if (botHoverTimer !== null) window.clearTimeout(botHoverTimer);
    if (slaps.length >= 3) {
      slaps.length = 0;
      triggerDizzy();
    } else {
      bot.emote("annoyed", 800, true);
      void audio.play("annoyed");
    }
  }

  function triggerDizzy(): void {
    appState.stateOverride = "dizzy";
    const prev = appState.view;
    void audio.play("dizzy");
    if (appState.mode === "expanded") {
      appState.setView("confused");
    }
    applyLayout();
    if (dizzyTimer !== null) window.clearTimeout(dizzyTimer);
    dizzyTimer = window.setTimeout(() => {
      appState.stateOverride = null;
      bot.blink();
      if (appState.mode === "expanded" && appState.view === "confused") {
        appState.setView(prev === "confused" ? defaultView() : prev);
      }
      applyLayout();
    }, 3300);
  }

  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && appState.mode === "expanded" && !appState.isPinned) {
      collapse();
    }
  });

  appState.subscribe((s) => {
    audio.setEnabled(s.soundEnabled);
    audio.setVolume(s.soundVolume);
    const st = s.stateOverride ?? s.effectiveState;
    bot.setState(st);
    applyLayout();
  });

  function pointerLook(e: PointerEvent): void {
    if (appState.mode === "hidden") return;
    const r = botwrap.getBoundingClientRect();
    const cx = r.left + r.width / 2;
    const cy = r.top + r.height / 2;
    const dx = (e.clientX - cx) / (r.width * 0.9);
    const dy = (e.clientY - cy) / (r.height * 0.9);
    bot.lookAt(dx, dy);
  }

  root.addEventListener("pointermove", pointerLook);

  function pollClickThrough(): void {
    void (async () => {
      const { setClickThrough, isTauri } = await import("../bridge/tauri.js");
      if (!isTauri()) return;
      const rect = island.getBoundingClientRect();
      const pad = 6;
      const mx = lastMouse.x;
      const my = lastMouse.y;
      const inside =
        mx >= rect.left - pad &&
        mx <= rect.right + pad &&
        my >= rect.top - pad &&
        my <= rect.bottom + pad;
      await setClickThrough(!inside);
    })();
  }

  const lastMouse = { x: 0, y: 0 };
  window.addEventListener("pointermove", (e) => {
    lastMouse.x = e.clientX;
    lastMouse.y = e.clientY;
  });

  function frame(now: number): void {
    requestAnimationFrame(frame);
    const dt = lastFrame ? (now - lastFrame) / 1000 : 0;
    lastFrame = now;

    if (appState.mode !== "hidden") {
      bot.update(dt);
      bot.draw();
      for (const [id, mini] of agentBots) {
        const task = appState.tasks.find((t) => t.id === id);
        if (task) {
          mini.setState(task.state);
          mini.update(dt);
          mini.draw();
        }
      }
    }

    updateCountdown();
    pollClickThrough();
  }

  requestAnimationFrame(frame);

  bot.setState(appState.effectiveState);
  applyLayout();

  return {
    fsm,
    expandTo,
    collapse,
    reveal: () => fsm.reveal(),
  };
}
