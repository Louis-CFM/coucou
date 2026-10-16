// Settings sections for the Windows and Linux additions, drawn like the
// rest of the window: Mochi (his name, and the wardrobe with outfits and body
// shapes, for every Mochi or each its own), and the name box each coloured
// Mochi gets under Integrations.
//
// The page's `settings` object is replaced whenever another window saves, so
// every section reads it through `ctx.settings()`.

import { Bridge } from "../core/bridge";
import type { ModelEntry, ModelOutput, Settings } from "../core/state";
import { MAIN_MOCHI, lookOf, parseWardrobeMode, setLook } from "../mochi/wardrobe";
import { pillDefinition, sanitizeDeclared } from "../core/pills";
import { pillColor } from "../core/pill-colors";
import { wardrobePicker } from "../views/wardrobe";
import { h, clear } from "../views/dom";
import { statusDot } from "./parts";
import { N_, t } from "../i18n/i18n";
import { MOOD_ACTS } from "../mochi/engine";
import { emit } from "@tauri-apps/api/event";

export interface ExtrasContext {
  settings(): Settings;
  save(): void;
  /** The window's on/off switch. */
  toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement;
}

/** A name box: saves on change; empty falls back to `fallback`. */
export function nameInput(value: string, fallback: string, apply: (v: string) => void, save: () => void): HTMLInputElement {
  const input = h("input", {
    type: "text",
    value,
    placeholder: fallback,
    maxlength: "32",
    spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  input.addEventListener("change", () => {
    apply(input.value.trim());
    save();
  });
  return input;
}

/** Redraws what follows other windows' saves. */
let redrawModels: () => void = () => {};

export function extrasSettingsChanged() {
  syncWardrobe();
  redrawModels();
}

// ── Wardrobe ──────────────────────────────────────────────────────────────────

/** Follows the island's choices (a right-click on Mochi saves too). */
let syncWardrobe: () => void = () => {};

/** The user's Mochis, as the wardrobe keys them: the main one, then each declared pill's. */
export function yourMochis(s: Settings): { key: string; name: string; color: string }[] {
  const d = sanitizeDeclared(s);
  const mochi = (id: string, key: string, name?: string) => {
    const def = pillDefinition(id);
    return { key, name: name || def?.name || id, color: pillColor(id, def?.color ?? "#888888", s.pillColors) };
  };
  return [mochi(d.mainPill, MAIN_MOCHI, "Mochi"), ...d.activeIntegrations.map((id) => mochi(id, id))];
}

/**
 * Mochi: the island's wardrobe, the same picker as a right-click on Mochi,
 * outfits then body shapes. Either every Mochi wears one look, or each its
 * own: then the row of Mochis picks whom the picker dresses. Switching keeps
 * both sets (each Mochi's own looks are in wardrobe-looks.json, settings.rs).
 * The island and the desktop Mochi follow at once.
 */
export function mochiSection(ctx: ExtrasContext): HTMLElement {
  let who = MAIN_MOCHI;
  const mode = h("select", {}) as HTMLSelectElement;
  for (const [value, text] of [
    ["perMochi", t("Each Mochi has its own outfit")],
    ["all", t("Same outfit for every Mochi")],
  ]) mode.append(h("option", { value, text }));
  mode.addEventListener("change", () => {
    ctx.settings().wardrobeMode = mode.value;
    ctx.save();
    sync();
  });
  const mochis = h("div", { class: "row" });
  const choose = (change: { outfit?: string; shape?: string }) => {
    setLook(ctx.settings(), who, change);
    ctx.save();
    sync();
  };
  const picker = wardrobePicker({
    outfit: () => lookOf(ctx.settings(), who).outfit,
    shape: () => lookOf(ctx.settings(), who).shape,
    chooseOutfit: (outfit) => choose({ outfit }),
    chooseShape: (shape) => choose({ shape }),
  });

  function sync() {
    const s = ctx.settings();
    const all = parseWardrobeMode(s.wardrobeMode) === "all";
    mode.value = all ? "all" : "perMochi";
    const list = yourMochis(s);
    if (!list.some((m) => m.key === who)) who = MAIN_MOCHI;
    mochis.style.display = all ? "none" : "";
    mochis.replaceChildren(h("label", {}), ...list.map((m) => {
      const button = h(
        "button",
        { class: m.key === who ? "primary" : "", "aria-pressed": String(m.key === who) },
        h("i", { class: "dot", style: `background:${m.color};margin-right:6px` }),
        m.name,
      );
      button.addEventListener("click", () => {
        who = m.key;
        sync();
      });
      return button;
    }));
    picker.sync();
  }
  syncWardrobe = sync;
  sync();

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Mochi" })),
    h("div", { class: "row" },
      h("label", { text: t("Mochi's name") }),
      nameInput(ctx.settings().mochiName ?? "", "Mochi", (v) => { ctx.settings().mochiName = v; }, ctx.save),
    ),
    h("div", { class: "hint", text: t("What the chat calls itself, and the main Mochi's pill when nothing runs. Each coloured Mochi's name is under Integrations.") }),
    h("div", { class: "row" }, h("label", { text: t("Wardrobe") }), mode),
    mochis,
    h("div", { class: "hint" }, picker.note),
    picker.el,    h("div", { class: "subhead", text: t("Play an emote") }),
    h("div", { class: "row" }, ...Object.keys(MOOD_ACTS).map((mood) => {
      const button = h("button", { text: mood });
      button.addEventListener("click", () => void emit("mochi-mood", mood));
      return button;
    })),
    h("div", { class: "row" },
      h("label", { text: t("Quick screenshot") }),
      ctx.toggle(ctx.settings().quickScan ?? false, (v) => {
        ctx.settings().quickScan = v;
        ctx.save();
      }),
    ),
    h("div", { class: "hint", text: t("Ctrl+drag Mochi out of the island and drop him for a screenshot; this skips his scan and captures right after the drop.") }),
  );
}

// ── Media and voice models ────────────────────────────────────────────────


const PROVIDERS: [string, string][] = [
  ["https://api.groq.com/openai/v1", "Groq"],
  ["https://openrouter.ai/api/v1", "OpenRouter"],
  ["https://api.openai.com/v1", "OpenAI"],
  ["https://gen.pollinations.ai/v1", "Pollinations"],
  ["https://integrate.api.nvidia.com/v1", "NVIDIA NIM"],
];

const OUTPUTS: [ModelOutput, string][] = [
  ["image", N_("Images")],
  ["video", "Video"],
  ["audio", "Speech"],
  ["3d", "3D"],
];

/** Groq's Orpheus English voices (console.groq.com/docs/text-to-speech/orpheus). */
const ORPHEUS_VOICES = ["autumn", "diana", "hannah", "austin", "daniel", "troy"];

function providerName(endpoint: string): string {
  const known = PROVIDERS.find(([url]) => endpoint.replace(/\/+$/, "") === url);
  if (known) return known[1];
  return endpoint.replace(/^\w+:\/\//, "").split("/")[0] || "custom";
}

function outputSelect(value: string): HTMLSelectElement {
  const select = h("select", { title: "What this model makes" }) as HTMLSelectElement;
  for (const [v, text] of OUTPUTS) select.append(h("option", { value: v, text: t(text) }));
  select.value = value || "image";
  return select;
}

/** A speech model's voice: Orpheus's six to pick from, any other model's by name. */
function voiceInput(m: ModelEntry, save: () => void): HTMLElement {
  const orpheus = /orpheus/i.test(m.model);
  const el = orpheus
    ? (h("select", {}, ...ORPHEUS_VOICES.map((v) => h("option", { value: v, text: v[0].toUpperCase() + v.slice(1) }))) as HTMLSelectElement)
    : (h("input", { type: "text", placeholder: "Voice, e.g. alloy", value: m.voice ?? "", spellcheck: "false" }) as HTMLInputElement);
  if (orpheus) el.value = ORPHEUS_VOICES.includes(m.voice ?? "") ? m.voice : "troy";
  el.addEventListener("change", () => {
    m.voice = el.value.trim();
    save();
  });
  return el;
}

/** TRELLIS 2's output detail (Pollinations: low 512³, medium 1024³, high 1536³). */
function detailInput(m: ModelEntry, save: () => void): HTMLSelectElement {
  const el = h("select", { title: "More detail takes longer and costs more" }) as HTMLSelectElement;
  for (const [v, text] of [["low", "Low detail"], ["medium", "Medium detail"], ["high", "High detail"]]) {
    el.append(h("option", { value: v, text }));
  }
  el.value = ["low", "medium", "high"].includes(m.detail ?? "") ? m.detail : "low";
  el.addEventListener("change", () => {
    m.detail = el.value;
    save();
  });
  return el;
}

/**
 * Models that make something other than chat text, from any OpenAI-compatible
 * provider. One key per provider host, shared by all its models (enter it once
 * for Groq, every Groq model uses it). Chat models themselves are picked from
 * upstream's providers, on the model name above the chat box.
 */
export function mediaModelsSection(ctx: ExtrasContext): HTMLElement {
  const list = h("div", { class: "model-list" });
  const input = (placeholder: string, type = "text") =>
    h("input", { type, placeholder, style: "flex:1 1 auto;min-width:0", autocomplete: "off", spellcheck: "false" }) as HTMLInputElement;

  // Draws overlap (a save redraws, and a redraw awaits the key checks): each
  // builds its rows apart and only the newest one is put on screen.
  let drawn = 0;
  async function draw() {
    const mine = ++drawn;
    const rows: HTMLElement[] = [];
    const s = ctx.settings();
    for (const m of s.models ?? []) {
      const inUse = s.chatProvider === "media" && s.chatModels.media === m.id;
      const use = h("button", { class: inUse ? "primary" : "", text: inUse ? t("In use") : t("Use in chat") });
      use.addEventListener("click", () => {
        const now = ctx.settings();
        now.chatProvider = "media";
        now.chatModels = { ...now.chatModels, media: m.id };
        ctx.save();
        void draw();
      });
      const label = h("input", { type: "text", value: m.label, placeholder: m.model, style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
      label.addEventListener("change", () => {
        m.label = label.value.trim();
        ctx.save();
      });
      const makes = outputSelect(m.output);
      makes.addEventListener("change", () => {
        m.output = makes.value as ModelOutput;
        ctx.save();
        void draw();
      });
      const remove = h("button", { class: "danger", text: t("Remove") });
      remove.addEventListener("click", () => {
        const now = ctx.settings();
        now.models = (now.models ?? []).filter((x) => x.id !== m.id);
        if (now.chatModels.media === m.id) {
          const { media: _gone, ...rest } = now.chatModels;
          now.chatModels = rest;
          if (now.chatProvider === "media") now.chatProvider = "anthropic";
        }
        ctx.save();
        void draw();
      });
      const keyName = await Bridge.endpointKey(m.endpoint);
      const keyDot = statusDot(!!keyName && !!(await Bridge.secretPresent(keyName)));
      keyDot.title = "API key for this provider";
      const named = m.label && m.label !== m.model && m.label !== m.model.split("/").pop();
      const provider = providerName(m.endpoint);
      rows.push(h("div", { class: "model" },
        h("div", { class: "row" }, label, makes, keyDot, use, remove),
        h("div", { class: "hint", text: named ? `${provider} · ${m.model}` : provider }),
        m.output === "audio"
          ? h("div", { class: "row" }, h("span", { class: "hint", text: t("Voice") }), voiceInput(m, ctx.save))
          : null,
        m.output === "3d"
          ? h("div", { class: "row" },
              /trellis/i.test(m.model) ? detailInput(m, ctx.save) : null,
              h("span", { class: "hint", text: "Drop a picture on the island, then send (or make an image first)." }))
          : null,
      ));
    }
    if (mine === drawn) list.replaceChildren(...rows);
  }
  redrawModels = () => void draw();

  // Add a model.
  const provider = h("select", {}) as HTMLSelectElement;
  for (const [url, name] of PROVIDERS) provider.append(h("option", { value: url, text: name }));
  provider.append(h("option", { value: "", text: t("Other…") }));
  const endpoint = input("https://…/v1");
  endpoint.value = PROVIDERS[0][0];
  const modelId = input("Model id, e.g. gpt-image-1");
  const label = input("Name in the picker (optional)");
  // Guessed from the model id until the user picks one.
  const makes = outputSelect("image");
  let makesPicked = false;
  makes.addEventListener("change", () => (makesPicked = true));
  modelId.addEventListener("input", async () => {
    if (makesPicked) return;
    const guess = (await Bridge.guessOutput(modelId.value)) ?? "image";
    if (OUTPUTS.some(([v]) => v === guess)) makes.value = guess;
  });
  const key = input("API key for this provider", "password");
  const add = h("button", { class: "primary", text: "Add model" });
  const feedback = h("div", {});

  const syncProvider = async () => {
    endpoint.style.display = provider.value === "" ? "" : "none";
    const name = await Bridge.endpointKey(endpoint.value);
    key.placeholder = name && (await Bridge.secretPresent(name)) ? `••••••  ${t("(stored)")}` : "API key for this provider";
  };
  provider.addEventListener("change", () => {
    endpoint.value = provider.value;
    void syncProvider();
  });
  endpoint.addEventListener("change", () => void syncProvider());

  add.addEventListener("click", async () => {
    clear(feedback);
    const id = modelId.value.trim();
    const url = endpoint.value.trim();
    if (!id || !/^https:\/\//i.test(url)) {
      feedback.append(h("div", { class: "notice err", text: "Enter the provider's https address and a model id." }));
      return;
    }
    if (key.value.trim()) {
      const name = await Bridge.endpointKey(url);
      if (name) await Bridge.secretSet(name, key.value.trim());
    }
    const entry: ModelEntry = {
      id: `m-${Date.now().toString(36)}`,
      label: label.value.trim() || (id.split("/").pop() ?? id),
      kind: "openai",
      model: id,
      endpoint: url,
      vision: null,
      output: makes.value as ModelOutput,
      voice: "",
      detail: "",
    };
    const s = ctx.settings();
    s.models = [...(s.models ?? []), entry];
    ctx.save();
    modelId.value = "";
    label.value = "";
    key.value = "";
    makesPicked = false;
    feedback.append(h("div", { class: "notice ok", text: `Added ${entry.label}: pick it on "Create" above the chat box.` }));
    void draw();
    void syncProvider();
  });

  void draw();
  void syncProvider();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Media and voice models" })),
    h("div", {
      class: "hint",
      text: "Image, video, speech and 3D models turn your message into a file instead of answering; pick them on \"Create\" above the chat box. Keys go to the Credential Manager, one per provider.",
    }),
    list,
    h("div", { class: "subhead", text: "Add a model" }),
    h("div", { class: "row" }, h("label", { text: "Provider" }), provider, endpoint),
    h("div", { class: "row" }, h("label", { text: t("Model") }), modelId),
    h("div", { class: "row" }, h("label", { text: "Makes" }), makes),
    h("div", { class: "row" }, h("label", { text: t("Name") }), label),
    h("div", { class: "row" }, h("label", { text: t("API key") }), key),
    h("div", { class: "row" }, add),
    feedback,
  );
}
