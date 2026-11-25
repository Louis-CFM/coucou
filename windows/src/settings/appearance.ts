// Settings → Appearance: Visibility mode, resting notch mode, display position,
// Mochi's wardrobe, and visual styling of the Dynamic Island.

import { Bridge } from "../core/bridge";
import { resolveCompanionName } from "../core/companion-identity";
import { Sound } from "../core/sound";
import { closedIsland } from "../core/closed";
import {
  resolveVisibility,
  resolveNotchScale,
  resolveNotchStyle,
  resolveShowBattery,
  resolveShowBatteryPercentage,
  resolveShowTabChat,
  resolveShowTabShelf,
  resolveShowTabDrop,
  resolveShowTabCoudrop,
  resolveShowTabLaunch,
  type NotchVisibility,
  type NotchStyle,
  type Settings,
} from "../core/state";
import { dropdownSelect } from "../views/dropdown";
import { h, svg } from "../views/dom";
import { t, tl } from "../i18n/i18n";
import { drawWardrobeIcon } from "../mochi/outfits";
import {
  OUTFIT_KEYS,
  OUTFIT_SELECTIONS,
  WARDROBE_STRINGS,
  parseOutfit,
  seasonalOutfit,
  wardrobeHeader,
  type Outfit,
  type OutfitSelection,
} from "../mochi/wardrobe";

const ICON_SIZE = 28;

export function appearanceSection(
  settings: Settings,
  save: () => Promise<void>,
  toggle: (on: boolean, onChange: (v: boolean) => void) => HTMLElement,
  setSwitch: (el: HTMLElement, on: boolean) => void,
  _buildSmartNotchCard: (
    settings: Settings,
    save: () => Promise<void>,
    onRegisterSync: (sync: () => void) => void,
  ) => HTMLElement,
  onRegisterSync: (sync: () => void) => void,
): HTMLElement {
  // ── Visibility Category ───────────────────────────────────────────────────
  const cardMap = new Map<NotchVisibility, HTMLElement>();

  const syncVisibilityCards = () => {
    const current = resolveVisibility(settings);
    for (const [mode, cardEl] of cardMap) {
      cardEl.classList.toggle("selected", mode === current);
    }
  };

  const selectVisibility = (mode: NotchVisibility) => {
    settings.visibility = mode;
    if (mode === "smart") {
      settings.smartNotch = true;
      if (settings.closedIsland === "hidden") settings.closedIsland = "mochi";
    } else if (mode === "always") {
      settings.smartNotch = false;
      if (settings.closedIsland === "hidden") settings.closedIsland = "mochi";
    } else if (mode === "minimal") {
      settings.smartNotch = false;
      if (settings.closedIsland === "hidden") settings.closedIsland = "mochi";
    } else if (mode === "hidden") {
      settings.closedIsland = "hidden";
    }

    Sound.resume();
    Sound.play("tick");
    syncVisibilityCards();
    syncRestingControls();
    void save();
  };

  const createVisibilityCard = (
    mode: NotchVisibility,
    titleText: string,
    descText: string,
    previewContent: HTMLElement,
  ): HTMLElement => {
    const isSelected = resolveVisibility(settings) === mode;
    const card = h(
      "div",
      {
        class: `visibility-card${isSelected ? " selected" : ""}`,
        onclick: () => selectVisibility(mode),
      },
      h("div", { class: "visibility-preview" }, previewContent),
      h(
        "div",
        { class: "visibility-info" },
        h("div", { class: "visibility-title", text: titleText }),
        h("div", { class: "visibility-desc", text: descText }),
      ),
    );
    cardMap.set(mode, card);
    return card;
  };

  // Preview Always
  const previewAlways = h(
    "div",
    { class: "preview-always" },
    h("div", { class: "screen-edge" }),
    h("div", { class: "notch-full" }),
  );

  // Preview Smart
  const previewSmart = h(
    "div",
    { class: "preview-smart" },
    h(
      "div",
      { class: "pane-desktop" },
      h("div", { class: "screen-edge" }),
      h("div", { class: "notch-full" }),
    ),
    h(
      "div",
      { class: "pane-maximized" },
      h(
        "div",
        { class: "max-app-window" },
        h(
          "div",
          { class: "notch-tucked" },
          svg("M6 9l6 6 6-6", 9, { stroke: 2.2 }),
        ),
      ),
    ),
  );

  // Preview Minimal
  const previewMinimal = h(
    "div",
    { class: "preview-minimal" },
    h("div", { class: "screen-edge" }),
    h(
      "div",
      { class: "notch-tucked" },
      svg("M6 9l6 6 6-6", 9, { stroke: 2.2 }),
    ),
  );

  // Preview Hidden
  const previewHidden = h(
    "div",
    { class: "preview-hidden" },
    h("div", { class: "screen-edge" }),
    h("div", { class: "notch-dashed" }),
  );

  const visibilityGrid = h(
    "div",
    { class: "visibility-grid" },
    createVisibilityCard(
      "always",
      t("Always"),
      "Always on screen. Fullscreen rules below still apply.",
      previewAlways,
    ),
    createVisibilityCard(
      "smart",
      t("Smart"),
      t("Full on the desktop; tucked away over maximized apps."),
      previewSmart,
    ),
    createVisibilityCard(
      "minimal",
      t("Minimal"),
      "Just a small arrow at the top. Hover to peek, open on hover or click.",
      previewMinimal,
    ),
    createVisibilityCard(
      "hidden",
      "Hidden",
      "Nothing on screen. Open it from the tray icon (or set a shortcut in General).",
      previewHidden,
    ),
  );

  // ── Style Category ─────────────────────────────────────────────────────────
  const styleCardMap = new Map<NotchStyle, HTMLElement>();

  const syncStyleCards = () => {
    const current = resolveNotchStyle(settings);
    for (const [st, cardEl] of styleCardMap) {
      cardEl.classList.toggle("selected", st === current);
    }
  };

  const selectStyle = (mode: NotchStyle) => {
    settings.notchStyle = mode;
    Sound.resume();
    Sound.play("tick");
    syncStyleCards();
    void save();
  };

  const createStyleCard = (
    mode: NotchStyle,
    titleText: string,
    descText: string,
    previewContent: HTMLElement,
  ): HTMLElement => {
    const isSelected = resolveNotchStyle(settings) === mode;
    const card = h(
      "div",
      {
        class: `style-card${isSelected ? " selected" : ""}`,
        onclick: () => selectStyle(mode),
      },
      h("div", { class: "style-preview" }, previewContent),
      h(
        "div",
        { class: "style-info" },
        h("div", { class: "style-title", text: titleText }),
        h("div", { class: "style-desc", text: descText }),
      ),
    );
    styleCardMap.set(mode, card);
    return card;
  };

  const previewNotch = h(
    "div",
    { class: "preview-style-notch" },
    h("div", { class: "screen-edge" }),
    h("div", { class: "notch-full" }),
  );

  const previewIsland = h(
    "div",
    { class: "preview-style-island" },
    h("div", { class: "screen-edge" }),
    h("div", { class: "island-pill" }),
  );

  const styleGrid = h(
    "div",
    { class: "style-grid" },
    createStyleCard(
      "notch",
      t("Notch"),
      "Grows out of the screen edge",
      previewNotch,
    ),
    createStyleCard(
      "island",
      t("Island"),
      "A pill floating just below the edge",
      previewIsland,
    ),
  );

  // ── Size Slider (exact native Coucou slider as for sounds) ─────────────────
  const currentScale = resolveNotchScale(settings);
  const sizeValueEl = h("span", {
    class: "size-value",
    text: `${Math.round(currentScale * 100)}%`,
  });

  const sizeInput = h("input", {
    type: "range",
    min: "70",
    max: "130",
    step: "1",
    value: String(Math.round(currentScale * 100)),
  }) as HTMLInputElement;

  const updateSizeFill = () => {
    const min = Number(sizeInput.min) || 70;
    const max = Number(sizeInput.max) || 130;
    const val = Number(sizeInput.value) || 100;
    const pct = Math.max(0, Math.min(100, ((val - min) / (max - min)) * 100));
    sizeInput.style.setProperty("--pct", `${pct}%`);
  };
  updateSizeFill();

  sizeInput.addEventListener("input", () => {
    updateSizeFill();
    const val = parseInt(sizeInput.value, 10);
    sizeValueEl.textContent = `${val}%`;
    settings.notchScale = val / 100;
    Sound.resume();
    Sound.play("tick");
    void save();
  });

  const sizeRow = h(
    "div",
    { class: "size-row" },
    h(
      "div",
      { class: "size-info" },
      h("div", { class: "size-title", text: "Size" }),
      h("div", { class: "size-desc", text: "Scales the resting notch" }),
    ),
    h("div", { class: "size-control" }, sizeValueEl, sizeInput),
  );

  // ── Mochi's Wardrobe ────────────────────────────────────────────────────────
  const wardrobeNote = h("span", { class: "wardrobe-note" });
  const wardrobeGrid = h("div", { class: "wardrobe-grid" });

  let hovered: OutfitSelection | null = null;
  let drawnSeason: Outfit | null = null;
  let drawnDpr = 0;
  const items = new Map<OutfitSelection, { button: HTMLButtonElement; canvas: HTMLCanvasElement }>();

  const updateWardrobeNote = () => {
    wardrobeNote.textContent = wardrobeHeader(hovered, parseOutfit(settings.mochiOutfit), new Date());
  };

  const drawWardrobeIcons = () => {
    const season = seasonalOutfit(new Date());
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    if (season === drawnSeason && drawnDpr === dpr) return;
    const first = drawnSeason == null || drawnDpr !== dpr;
    drawnSeason = season;
    drawnDpr = dpr;
    for (const [sel, { canvas }] of items) {
      if (!first && sel !== "auto") continue;
      canvas.width = Math.round(ICON_SIZE * dpr);
      canvas.height = Math.round(ICON_SIZE * dpr);
      const ctx = typeof canvas.getContext === "function" ? canvas.getContext("2d") : null;
      if (!ctx) continue;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      drawWardrobeIcon(ctx, ICON_SIZE, sel, season, WARDROBE_STRINGS.autoBadge);
    }
  };

  for (const sel of OUTFIT_SELECTIONS) {
    const canvas = h("canvas") as HTMLCanvasElement;
    const btn = h(
      "button",
      {
        class: `wardrobe-item${sel === parseOutfit(settings.mochiOutfit) ? " on" : ""}`,
        title: tl(OUTFIT_KEYS[sel]),
        "aria-label": tl(OUTFIT_KEYS[sel]),
        type: "button",
      },
      canvas,
    ) as HTMLButtonElement;

    btn.addEventListener("mouseenter", () => {
      hovered = sel;
      updateWardrobeNote();
    });

    btn.addEventListener("mouseleave", () => {
      if (hovered !== sel) return;
      hovered = null;
      updateWardrobeNote();
    });

    btn.addEventListener("click", () => {
      settings.mochiOutfit = sel;
      Sound.resume();
      Sound.play("tick");
      for (const [s, item] of items) {
        item.button.classList.toggle("on", s === sel);
      }
      updateWardrobeNote();
      void save();
    });

    items.set(sel, { button: btn, canvas });
    wardrobeGrid.append(btn);
  }

  setTimeout(drawWardrobeIcons, 0);
  updateWardrobeNote();

  // ── Resting Notch Options ───────────────────────────────────────────────────
  const companion = resolveCompanionName(settings);
  const closedOptions: [string, string][] = [
    ["mochi", t("{name}, as on a Mac without a notch", { name: companion })],
    ["time", t("The time")],
    ["datetime", t("The date and the time")],
    ["claude", t("Claude usage")],
    ["music", t("What's playing")],
    ["coucoudoro", t("Coucoudoro timer")],
    ["empty", t("Nothing, just the island")],
  ];
  const closed = dropdownSelect(closedOptions, closedIsland(settings.closedIsland), (v) => {
    settings.closedIsland = v;
    if (settings.visibility === "hidden" && v !== "hidden") {
      settings.visibility = settings.smartNotch ? "smart" : "always";
      syncVisibilityCards();
    }
    void save();
  });

  // ── Monitor Selection ───────────────────────────────────────────────────────
  const screenOptions: [string, string][] = [
    ["primary", t("Main display")],
    ["cursor", t("Display under the cursor")],
  ];
  const screen = dropdownSelect(screenOptions, settings.screen, (v) => {
    settings.screen = v;
    void save();
  });
  void Bridge.listMonitors().then((list) => {
    const extra: [string, string][] = (list ?? []).map((m) => [m.key, m.label]);
    screen.setOptions([...screenOptions, ...extra]);
    const saved = settings.screen;
    const [place, name] = saved.split("|");
    const keys = (list ?? []).map((m) => m.key);
    screen.value =
      keys.find((k) => k === saved) ??
      (saved.startsWith("at:") ? keys.find((k) => k.split("|")[0] === place) : undefined) ??
      (name ? keys.find((k) => k.split("|")[1] === name) : undefined) ??
      saved;
    if (!screen.value) screen.value = "primary";
  });

  // ── Toggles ─────────────────────────────────────────────────────────────────
  const openOnHover = toggle(settings.openOnHover, (v) => {
    settings.openOnHover = v;
    void save();
  });

  const showClock = toggle(settings.showClock, (v) => {
    settings.showClock = v;
    void save();
  });

  const showBattery = toggle(resolveShowBattery(settings), (v) => {
    settings.showBattery = v;
    void save();
  });

  const showBatteryPct = toggle(resolveShowBatteryPercentage(settings), (v) => {
    settings.showBatteryPercentage = v;
    void save();
  });

  const showTabChat = toggle(resolveShowTabChat(settings), (v) => {
    settings.showTabChat = v;
    void save();
  });

  const showTabShelf = toggle(resolveShowTabShelf(settings), (v) => {
    settings.showTabShelf = v;
    void save();
  });

  const showTabDrop = toggle(resolveShowTabDrop(settings), (v) => {
    settings.showTabDrop = v;
    void save();
  });

  const showTabCoudrop = toggle(resolveShowTabCoudrop(settings), (v) => {
    settings.showTabCoudrop = v;
    void save();
  });

  const showTabLaunch = toggle(resolveShowTabLaunch(settings), (v) => {
    settings.showTabLaunch = v;
    void save();
  });

  const syncRestingControls = () => {
    closed.value = closedIsland(settings.closedIsland);
    setSwitch(openOnHover, settings.openOnHover);
    setSwitch(showClock, settings.showClock);
    setSwitch(showBattery, resolveShowBattery(settings));
    setSwitch(showBatteryPct, resolveShowBatteryPercentage(settings));
    setSwitch(showTabChat, resolveShowTabChat(settings));
    setSwitch(showTabShelf, resolveShowTabShelf(settings));
    setSwitch(showTabDrop, resolveShowTabDrop(settings));
    setSwitch(showTabCoudrop, resolveShowTabCoudrop(settings));
    setSwitch(showTabLaunch, resolveShowTabLaunch(settings));
  };

  // ── External Sync ───────────────────────────────────────────────────────────
  const syncAppearance = () => {
    syncVisibilityCards();
    syncStyleCards();
    const sc = resolveNotchScale(settings);
    sizeInput.value = String(Math.round(sc * 100));
    sizeValueEl.textContent = `${Math.round(sc * 100)}%`;
    updateSizeFill();
    syncRestingControls();
    const current = parseOutfit(settings.mochiOutfit);
    for (const [sel, { button }] of items) {
      button.classList.toggle("on", sel === current);
    }
    updateWardrobeNote();
  };

  onRegisterSync(syncAppearance);

  // ── Assemble Appearance Page ────────────────────────────────────────────────
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("Appearance") })),

    // Category: VISIBILITY
    h(
      "div",
      {
        class: "hub-label",
        style:
          "font-size:11px;font-weight:700;letter-spacing:0.06em;color:var(--dim);margin:10px 0 2px;text-transform:uppercase;",
        text: t("Visibility"),
      },
    ),
    visibilityGrid,

    // Category: STYLE
    h(
      "div",
      {
        class: "hub-label",
        style:
          "font-size:11px;font-weight:700;letter-spacing:0.06em;color:var(--dim);margin:16px 0 2px;text-transform:uppercase;",
        text: t("Style"),
      },
    ),
    styleGrid,
    sizeRow,

    // Category: RESTING NOTCH
    h(
      "div",
      {
        class: "hub-label",
        style:
          "font-size:11px;font-weight:700;letter-spacing:0.06em;color:var(--dim);margin:16px 0 4px;text-transform:uppercase;",
        text: t("Resting Notch"),
      },
    ),
    h("div", { class: "row" }, h("label", { text: t("Closed island shows") }), closed),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "What appears in the compact notch when resting at the top of the screen.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: "Battery indicator" }), showBattery),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show dynamic battery level and charging status on the right side of the resting notch.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: "Battery percentage" }), showBatteryPct),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show exact numeric percentage next to the battery icon.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: t("Show clock in the island") }), showClock),
    h("div", { class: "hint", text: t("The date and the time in the middle of the island when it is compact.") }),
    h("div", { class: "row" }, h("label", { text: t("Open on hover") }), openOnHover),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: t("Hovering the island opens it; it folds again shortly after the pointer leaves. Click inside to keep it open."),
      }),
    ),

    // Category: NAVIGATION & FEATURES
    h(
      "div",
      {
        class: "hub-label",
        style:
          "font-size:11px;font-weight:700;letter-spacing:0.06em;color:var(--dim);margin:16px 0 4px;text-transform:uppercase;",
        text: "Navigation & Features",
      },
    ),
    h("div", { class: "row" }, h("label", { text: "Ask (AI Chat)" }), showTabChat),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show the chat bubble tab in the header to ask Claude or local models.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: "File Shelf" }), showTabShelf),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show the folder tab for parking files and documents in the notch.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: "Drop & Upload" }), showTabDrop),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show the plus tab to drop and ingest files into active sessions.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: "Coudrop (Quick Share)" }), showTabCoudrop),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show the phone transfer tab to beam files between your PC and phone.",
      }),
    ),
    h("div", { class: "row" }, h("label", { text: "Terminal (Claude Code)" }), showTabLaunch),
    h(
      "div",
      { class: "hint" },
      h("span", {
        text: "Show the terminal tab to start new Claude Code sessions from the island.",
      }),
    ),

    // Category: DISPLAY POSITION
    h(
      "div",
      {
        class: "hub-label",
        style:
          "font-size:11px;font-weight:700;letter-spacing:0.06em;color:var(--dim);margin:16px 0 4px;text-transform:uppercase;",
        text: t("Display"),
      },
    ),
    h("div", { class: "row" }, h("label", { text: t("Island lives on") }), screen),

    // Category: COMPANION WARDROBE
    h(
      "div",
      {
        class: "hub-label",
        style:
          "font-size:11px;font-weight:700;letter-spacing:0.06em;color:var(--dim);margin:16px 0 4px;text-transform:uppercase;",
        text: t("{name}'s Wardrobe", { name: companion }),
      },
    ),
    h(
      "div",
      {
        style:
          "background:rgba(255,255,255,0.03);border:1px solid rgba(255,255,255,0.07);border-radius:12px;padding:14px;margin:4px 0 10px;",
      },
      h(
        "div",
        { class: "wardrobe-head", style: "margin-bottom:10px" },
        h("span", { class: "wardrobe-title", style: "font-size:13px;font-weight:600", text: t("Wardrobe") }),
        wardrobeNote,
      ),
      wardrobeGrid,
      h("div", {
        class: "hint",
        style: "margin-top:8px",
        text: t("Select an outfit for {name}, or choose Auto to dress for holidays and seasons.", { name: companion }),
      }),
    ),

    // Theme info (clean project UI theme, no neon glow)
    h(
      "div",
      {
        style:
          "display:flex;align-items:center;justify-content:space-between;background:rgba(255,255,255,0.025);border:1px solid rgba(255,255,255,0.06);border-radius:10px;padding:10px 14px;margin-top:8px;",
      },
      h(
        "div",
        {},
        h("div", { style: "font-weight:600;font-size:12.5px;color:var(--ink)", text: "macOS Dynamic Island" }),
        h("div", { style: "font-size:11.5px;color:var(--dim)", text: "Adaptive dark glass, fluid spring morphing, and tactile feedback." }),
      ),
      h("span", {
        class: "tag",
        style: "background:rgba(59,130,246,0.12);color:#93c5fd;border:1px solid rgba(59,130,246,0.22);font-size:10.5px",
        text: "Liquid Glass",
      }),
    ),
  );
}
