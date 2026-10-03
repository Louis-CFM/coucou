// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type HookStatus } from "../core/bridge";
import { DEFAULT_MOCHI_NAMES, DEFAULT_SETTINGS, type ModelEntry, type Settings } from "../core/state";
import { BotEngine, hexToRGB } from "../mochi/engine";
import { SHAPES, hats, type Outfit } from "../mochi/wardrobe";
import { h, clear } from "../views/dom";

let settings: Settings = { ...DEFAULT_SETTINGS };
let version = "";

const root = document.getElementById("settings-root")!;

async function save() {
  await Bridge.saveSettings(settings);
}

// ── Reusable bits ─────────────────────────────────────────────────────────────

function toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    onChange(next);
  });
  return el;
}

function statusDot(ok: boolean): HTMLElement {
  return h("i", { class: "dot", style: `background:${ok ? "#22c55e" : "#f4505e"}` });
}

function renderDiff(text: string): HTMLElement {
  const box = h("div", { class: "diff" });
  for (const line of text.split("\n")) {
    const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx";
    box.append(h("div", { class: cls, text: line }));
  }
  return box;
}

// ── Claude Code section ───────────────────────────────────────────────────────

function claudeSection(status: HookStatus): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, statusDot(status.installed), h("span", { text: "Claude Code" })),
    body,
  );

  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus();
    if (fresh) Object.assign(status, fresh);
    clear(body);
    draw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: "Claude Code" }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: status.installed
          ? "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there."
          : "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.",
      }),
      h("div", { class: "row" },
        h("label", { text: "settings.json" }),
        h("span", { class: "path", text: status.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: "Relay" }),
        h("span", { class: "path", text: status.hookPath }),
        statusDot(status.hookReady),
      ),
    );

    if (!status.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: "coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.",
      }));
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: status.installed ? "Reinstall hooks…" : "Install hooks…",
      onclick: () => showPreview(true),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every Claude Code session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = "The relay isn't installed yet.";
    }
    actions.append(install);
    if (status.installed) {
      actions.append(h("button", {
        class: "danger",
        text: "Uninstall hooks…",
        onclick: () => showPreview(false),
      }));
    }
    body.append(actions);
  }

  async function showPreview(install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(install);
    } catch (err) {
      // An unreadable or invalid settings.json stops here rather than being
      // treated as empty and written over.
      clear(body);
      body.append(
        h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
        h("div", { class: "row" }, h("button", {
          text: "Back",
          onclick: () => { clear(body); draw(); },
        })),
      );
      return;
    }
    if (!preview) return;
    clear(body);
    body.append(
      h("div", {
        class: "hint",
        text: install
          ? "This is exactly what will change in your settings.json. Your own hooks are left untouched."
          : "This removes Coucou's entries only. Your own hooks are left untouched.",
      }),
      renderDiff(preview.diff),
      h("div", { class: "row" },
        h("span", { class: "path", text: `Backup → ${preview.backup}` }),
      ),
    );
    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: install ? "Back up and write" : "Back up and remove",
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(install, preview.fingerprint);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `Done. Previous settings saved as ${backup}. Open a new Claude Code session to pick the hooks up.`,
        }));
        window.setTimeout(() => void rebuild(), 2600);
      } catch (err) {
        confirm.disabled = false;
        body.append(h("div", { class: "notice err", text: `Could not write: ${String(err)}` }));
      }
    });
    body.append(h("div", { class: "row" }, confirm, h("button", {
      text: "Cancel",
      onclick: () => { clear(body); draw(); },
    })));
  }

  draw();
  return section;
}

// ── Claude API section ────────────────────────────────────────────────────────

const MODELS: [string, string][] = [
  ["claude-opus-5", "Claude Opus 5"],
  ["claude-sonnet-5", "Claude Sonnet 5"],
  ["claude-haiku-4-5", "Claude Haiku 4.5"],
];

function apiSection(hasKey: boolean): HTMLElement {
  const dot = statusDot(hasKey);
  const state = h("span", { class: "hint", text: hasKey ? "Key saved in the Windows Credential Manager." : "No key yet — the chat needs one." });

  const field = h("input", {
    type: "password",
    placeholder: hasKey ? "••••••••••••  (stored)" : "sk-ant-...",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  const saveBtn = h("button", { class: "primary", text: "Save key" });
  const clearBtn = h("button", { class: "danger", text: "Remove" });
  const feedback = h("div", {});

  async function refresh() {
    const present = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
    dot.style.background = present ? "#22c55e" : "#f4505e";
    state.textContent = present
      ? "Key saved in the Windows Credential Manager."
      : "No key yet — the chat needs one.";
    field.placeholder = present ? "••••••••••••  (stored)" : "sk-ant-...";
    clearBtn.style.display = present ? "" : "none";
  }

  saveBtn.addEventListener("click", async () => {
    const value = field.value.trim();
    if (!value) return;
    clear(feedback);
    try {
      await Bridge.secretSet("anthropic-api-key", value);
      field.value = "";
      feedback.append(h("div", { class: "notice ok", text: "Saved. It never touches disk." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not save: ${String(err)}` }));
    }
  });

  clearBtn.addEventListener("click", async () => {
    if (!window.confirm("Remove the saved Claude API key? The chat won't work until you add it again.")) return;
    clear(feedback);
    try {
      await Bridge.secretClear("anthropic-api-key");
      feedback.append(h("div", { class: "notice ok", text: "Key removed." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
    }
  });

  clearBtn.style.display = hasKey ? "" : "none";

  const mochiName = nameInput(settings.mochiName, "Mochi", (v) => { settings.mochiName = v; });

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Claude" })),
    state,
    h("div", { class: "row" }, h("label", { text: "Mochi's name" }), mochiName),
    h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn),
    feedback,
  );
}

// ── Models ───────────────────────────────────────────────────────────────────

const PROVIDERS: [string, string][] = [
  ["https://api.groq.com/openai/v1", "Groq"],
  ["https://openrouter.ai/api/v1", "OpenRouter"],
  ["https://integrate.api.nvidia.com/v1", "NVIDIA NIM"],
  ["https://api.openai.com/v1", "OpenAI"],
  ["http://localhost:11434/v1", "Ollama (this PC)"],
];

/** Redraws the model list (set by modelsSection; vision is learnt in the background). */
let redrawModels: () => void = () => {};

function providerName(endpoint: string): string {
  const known = PROVIDERS.find(([url]) => endpoint.replace(/\/+$/, "") === url);
  if (known) return known[1];
  return endpoint.replace(/^\w+:\/\//, "").split("/")[0] || "custom";
}

/**
 * The chat's saved models, picked from the selector next to Send. Claude models
 * use the Claude key above; any OpenAI-compatible provider has one key per host,
 * shared by all its models (enter it once for Groq, every Groq model uses it).
 */
function modelsSection(): HTMLElement {
  const list = h("div", { class: "model-list" });
  const input = (placeholder: string, type = "text") =>
    h("input", { type, placeholder, style: "flex:1 1 auto;min-width:0", autocomplete: "off", spellcheck: "false" }) as HTMLInputElement;

  async function draw() {
    clear(list);
    for (const m of settings.models) {
      const active = m.id === settings.activeModel;
      const use = h("button", { class: active ? "primary" : "", text: active ? "In use" : "Use" });
      use.addEventListener("click", () => {
        settings.activeModel = m.id;
        void save();
        void draw();
      });
      const label = h("input", { type: "text", value: m.label, placeholder: m.model, style: "flex:1 1 auto;min-width:0" }) as HTMLInputElement;
      label.addEventListener("change", () => {
        m.label = label.value.trim();
        void save();
      });
      const vision = h("select", { title: "Can this model see images? Auto learns it the first time." }) as HTMLSelectElement;
      vision.append(
        h("option", { value: "auto", text: "Images: auto" }),
        h("option", { value: "yes", text: "Sees images" }),
        h("option", { value: "no", text: "Text only" }),
      );
      vision.value = m.vision === true ? "yes" : m.vision === false ? "no" : "auto";
      vision.disabled = m.kind === "claude";
      vision.addEventListener("change", () => {
        m.vision = vision.value === "yes" ? true : vision.value === "no" ? false : null;
        void save();
      });
      const remove = h("button", { class: "danger", text: "Remove" });
      remove.style.display = settings.models.length > 1 ? "" : "none";
      remove.addEventListener("click", () => {
        settings.models = settings.models.filter((x) => x.id !== m.id);
        if (settings.activeModel === m.id) settings.activeModel = settings.models[0]?.id ?? "";
        void save();
        void draw();
      });
      const keyDot = statusDot(false);
      if (m.kind === "claude") {
        keyDot.style.background = (await Bridge.secretPresent("anthropic-api-key")) ? "#22c55e" : "#f4505e";
      } else {
        const keyName = await Bridge.endpointKey(m.endpoint);
        const has = (keyName && (await Bridge.secretPresent(keyName))) || (await Bridge.secretPresent("custom-api-key"));
        keyDot.style.background = has ? "#22c55e" : "#f4505e";
      }
      keyDot.title = "API key for this provider";
      // The name defaults to the model id, so the id only adds anything once
      // the model has been given a name of its own.
      const provider = m.kind === "claude" ? "Claude" : providerName(m.endpoint);
      const named = m.label && m.label !== m.model && m.label !== m.model.split("/").pop();
      list.append(
        h("div", { class: "row" }, use, label, vision, keyDot, remove),
        h("div", { class: "hint", style: "margin:-4px 0 6px 64px", text: named ? `${provider} \u00b7 ${m.model}` : provider }),
      );
    }
  }
  redrawModels = () => void draw();

  // Add a model.
  const kind = h("select", {}) as HTMLSelectElement;
  kind.append(h("option", { value: "openai", text: "OpenAI-compatible" }), h("option", { value: "claude", text: "Claude" }));
  const provider = h("select", {}) as HTMLSelectElement;
  for (const [url, name] of PROVIDERS) provider.append(h("option", { value: url, text: name }));
  provider.append(h("option", { value: "", text: "Other\u2026" }));
  const endpoint = input("https://\u2026/v1");
  endpoint.value = PROVIDERS[0][0];
  const modelId = input("Model id, e.g. meta-llama/llama-4-scout-17b-16e-instruct");
  const claudeModel = h("select", {}) as HTMLSelectElement;
  for (const [id, name] of MODELS) claudeModel.append(h("option", { value: id, text: name }));
  const label = input("Name in the picker (optional)");
  const key = input("API key for this provider", "password");
  const add = h("button", { class: "primary", text: "Add model" });
  const feedback = h("div", {});

  const providerRow = h("div", { class: "row" }, h("label", { text: "Provider" }), provider, endpoint);
  const modelRow = h("div", { class: "row" }, h("label", { text: "Model" }), modelId, claudeModel);
  const keyRow = h("div", { class: "row" }, h("label", { text: "API key" }), key);
  const syncKind = async () => {
    const openai = kind.value === "openai";
    providerRow.style.display = openai ? "" : "none";
    keyRow.style.display = openai ? "" : "none";
    modelId.style.display = openai ? "" : "none";
    claudeModel.style.display = openai ? "none" : "";
    endpoint.style.display = openai && provider.value === "" ? "" : "none";
    if (openai) {
      const name = await Bridge.endpointKey(endpoint.value);
      key.placeholder = name && (await Bridge.secretPresent(name)) ? "\u2022\u2022\u2022\u2022\u2022\u2022  (stored for this provider)" : "API key for this provider";
    }
  };
  kind.addEventListener("change", () => void syncKind());
  provider.addEventListener("change", () => {
    if (provider.value) endpoint.value = provider.value;
    else endpoint.value = "";
    void syncKind();
  });
  endpoint.addEventListener("change", () => void syncKind());

  add.addEventListener("click", async () => {
    clear(feedback);
    const openai = kind.value === "openai";
    const id = openai ? modelId.value.trim() : claudeModel.value;
    const url = endpoint.value.trim();
    if (!id || (openai && !/^https?:\/\//i.test(url))) {
      feedback.append(h("div", { class: "notice err", text: openai ? "Enter the provider's address and a model id." : "Pick a Claude model." }));
      return;
    }
    if (openai && key.value.trim()) {
      const name = await Bridge.endpointKey(url);
      if (name) await Bridge.secretSet(name, key.value.trim());
    }
    const entry: ModelEntry = {
      id: `m-${Date.now().toString(36)}`,
      label: label.value.trim() || (openai ? id.split("/").pop() ?? id : claudeModel.selectedOptions[0]?.text ?? id),
      kind: openai ? "openai" : "claude",
      model: id,
      endpoint: openai ? url : "",
      vision: openai ? null : true,
    };
    settings.models = [...settings.models, entry];
    settings.activeModel = entry.id;
    await save();
    modelId.value = "";
    label.value = "";
    key.value = "";
    feedback.append(h("div", { class: "notice ok", text: `Added ${entry.label}, and it's now in use.` }));
    void draw();
    void syncKind();
  });

  void draw();
  void syncKind();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Models" })),
    h("span", {
      class: "hint",
      text: "Pick between these from the menu next to Send. Web search is Claude-only. Text-only models are detected automatically; you'll be asked before an image is sent to one.",
    }),
    list,
    h("h3", { text: "Add a model", style: "margin:14px 0 6px;font-size:12.5px" }),
    h("div", { class: "row" }, h("label", { text: "Type" }), kind),
    providerRow,
    modelRow,
    h("div", { class: "row" }, h("label", { text: "Name" }), label),
    keyRow,
    h("div", { class: "row" }, add),
    feedback,
  );
}

/** A Mochi name box: saves on change; empty falls back to `fallback`. */
function nameInput(value: string, fallback: string, apply: (v: string) => void): HTMLInputElement {
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
    void save();
  });
  return input;
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: "Secret key", placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: "Token", placeholder: "ghp_…", secret: true }] },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: "Token", placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: "Instance URL", placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: "API key", placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: "API key", placeholder: "re_…", secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: "Integration token", placeholder: "ntn_…", secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: "API key", placeholder: "cal_…", secret: true }] },
];

const MAX_ACTIVE = 4;

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = `Pick up to ${MAX_ACTIVE} pills to show next to Mochi — ${used}/${MAX_ACTIVE} in use. Keys are stored in the Windows Credential Manager, never on disk.`;
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        if (settings.activeIntegrations.length >= MAX_ACTIVE) return;
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    // This coloured Mochi's name first, on the same line as its service, then its keys.
    rows.append(
      h("div", { class: "row" },
        h("label", { style: "min-width:104px", text: "Mochi's name" }),
        nameInput(settings.mochiNames?.[def.id] ?? "", DEFAULT_MOCHI_NAMES[def.id] ?? def.name, (v) => {
          const names = { ...(settings.mochiNames ?? {}) };
          if (v) names[def.id] = v;
          else delete names[def.id];
          settings.mochiNames = names;
        }),
      ),
    );
    for (const field of def.fields) {
      const input = h("input", {
        type: field.secret ? "password" : "text",
        placeholder: present[field.key] ? "••••••••  (stored)" : field.placeholder,
        autocomplete: "off",
        spellcheck: "false",
        style: "flex:1 1 auto;min-width:0",
      }) as HTMLInputElement;
      const saveBtn = h("button", { text: "Save" });
      const dotEl = statusDot(present[field.key] ?? false);
      // Saving an empty field used to store an empty key, wiping the real one.
      // With a key stored and nothing typed, the button says what it does.
      const clearing = () => !!present[field.key] && !input.value.trim();
      const syncButton = () => {
        saveBtn.textContent = clearing() ? "Clear key" : "Save";
        saveBtn.className = clearing() ? "danger" : "";
      };
      input.addEventListener("input", syncButton);
      syncButton();
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        if (!value && !present[field.key]) return;
        if (!value && !window.confirm(`Clear the saved ${field.label}? ${def.name} won't work until you add it again.`)) return;
        try {
          if (value) await Bridge.secretSet(field.key, value);
          else await Bridge.secretClear(field.key);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? "••••••••  (stored)" : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
        syncButton();
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: field.label }),
          input, saveBtn, dotEl,
        ),
      );
    }

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start;padding-bottom:14px;border-bottom:1px solid rgba(255,255,255,0.08)" },
        h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
          sw,
          h("i", { class: "dot", style: `background:${def.color}` }),
          h("span", { style: "font-size:12.5px", text: def.name }),
        ),
        rows,
      ),
    );
  }

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: "Integrations" })), note, list);
}

// ── General section ───────────────────────────────────────────────────────────

// ── Wardrobe ─────────────────────────────────────────────────────────────────

/** Draws one still frame of a Mochi into a canvas (tiles don't animate). */
function stillMochi(canvas: HTMLCanvasElement, size: number, color: string, outfit: Outfit) {
  const engine = new BotEngine();
  engine.bodyColor = hexToRGB(color);
  engine.outfit = outfit;
  engine.particleOverhang = size * 0.25;
  const h = size + engine.particleOverhang;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(size * dpr);
  canvas.height = Math.round(h * dpr);
  canvas.style.width = `${size}px`;
  canvas.style.height = `${h}px`;
  for (let i = 0; i < 4; i++) engine.update(0.016);
  const ctx = canvas.getContext("2d")!;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, size, h);
  engine.draw(ctx, size, h);
}

/**
 * Dress each Mochi: pick one, then a shape and one item per slot. The live
 * preview follows the mouse and celebrates on click; every tile shows the item
 * on that Mochi, in its own colour.
 */
function wardrobeSection(): HTMLElement {
  const mochis = [
    { id: "integration_claude", color: "#F5F6F8", name: () => settings.mochiName?.trim() || "Mochi" },
    ...INTEGRATIONS.map((d) => ({
      id: d.id,
      color: d.color,
      name: () => settings.mochiNames?.[d.id]?.trim() || DEFAULT_MOCHI_NAMES[d.id] || d.name,
    })),
  ];
  let current = mochis[0];
  const outfit = (): Outfit => settings.wardrobe?.[current.id] ?? {};
  const setOutfit = (o: Outfit) => {
    settings.wardrobe = { ...(settings.wardrobe ?? {}), [current.id]: o };
    void save();
  };

  // Live preview.
  const preview = document.createElement("canvas");
  const PREVIEW = 150;
  const engine = new BotEngine();
  engine.particleOverhang = 40;
  const dpr = window.devicePixelRatio || 1;
  preview.width = Math.round(PREVIEW * dpr);
  preview.height = Math.round((PREVIEW + 40) * dpr);
  preview.style.width = `${PREVIEW}px`;
  preview.style.height = `${PREVIEW + 40}px`;
  preview.className = "wardrobe-preview";
  preview.title = "Click to celebrate";
  preview.addEventListener("click", () => engine.celebrate());
  window.addEventListener("mousemove", (e) => {
    const r = preview.getBoundingClientRect();
    engine.lookX = Math.tanh((e.clientX - (r.left + r.width / 2)) / 220);
    engine.lookY = -Math.tanh((e.clientY - (r.top + r.height / 2)) / 180);
  });
  let last = performance.now();
  const frame = (now: number) => {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if (!document.hidden && preview.isConnected) {
      engine.bodyColor = hexToRGB(current.color);
      engine.outfit = outfit();
      engine.update(dt);
      const ctx = preview.getContext("2d")!;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, PREVIEW, PREVIEW + 40);
      engine.draw(ctx, PREVIEW, PREVIEW + 40);
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  const chips = h("div", { class: "wardrobe-chips" });
  const rows = h("div", { class: "wardrobe-rows" });

  function tile(label: string, on: boolean, draw: (c: HTMLCanvasElement) => void, pick: () => void) {
    const c = document.createElement("canvas");
    draw(c);
    const t = h("button", { class: on ? "wardrobe-tile on" : "wardrobe-tile", title: label }, c, h("span", { text: label }));
    t.addEventListener("click", () => {
      pick();
      engine.squash();
      redraw();
    });
    return t;
  }

  function redraw() {
    // Rebuilding the tiles briefly empties the section, which pulled the page
    // back to the top on every pick: keep the scroll where it was.
    const scroller = document.scrollingElement ?? document.documentElement;
    const keep = scroller.scrollTop;
    requestAnimationFrame(() => (scroller.scrollTop = keep));
    clear(chips);
    for (const m of mochis) {
      const chip = h(
        "button",
        { class: m.id === current.id ? "wardrobe-chip on" : "wardrobe-chip" },
        h("i", { class: "dot", style: `background:${m.color}` }),
        h("span", { text: m.name() }),
      );
      chip.addEventListener("click", () => {
        current = m;
        redraw();
      });
      chips.append(chip);
    }

    clear(rows);
    const o = outfit();
    const shapeRow = h("div", { class: "wardrobe-row" });
    for (const sh of SHAPES) {
      const on = (o.shape || "mochi") === sh.id;
      shapeRow.append(
        tile(sh.name, on, (c) => stillMochi(c, 52, current.color, { ...o, shape: sh.id }), () =>
          setOutfit({ ...outfit(), shape: sh.id === "mochi" ? "" : sh.id }),
        ),
      );
    }
    rows.append(h("div", { class: "wardrobe-label", text: "Shape" }), shapeRow);

    const hatRow = h("div", { class: "wardrobe-row" });
    hatRow.append(
      tile("None", !o.head, (c) => stillMochi(c, 52, current.color, { ...o, head: "" }), () =>
        setOutfit({ ...outfit(), head: "" }),
      ),
    );
    for (const hat of hats()) {
      hatRow.append(
        tile(hat.name, o.head === hat.id, (c) => stillMochi(c, 52, current.color, { ...o, head: hat.id }), () =>
          setOutfit({ ...outfit(), head: hat.id }),
        ),
      );
    }
    rows.append(h("div", { class: "wardrobe-label", text: "Hat" }), hatRow);
  }
  redraw();

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Wardrobe" })),
    h("span", { class: "hint", text: "Pick each Mochi's shape and hat. Changes show up straight away; click the preview for a little celebration." }),
    chips,
    h("div", { class: "wardrobe" }, preview, rows),
  );
}

function generalSection(): HTMLElement {
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    value: String(settings.soundVolume),
  }) as HTMLInputElement;
  volume.addEventListener("input", () => {
    settings.soundVolume = Number(volume.value);
    void save();
  });

  const autoClose = h("input", {
    type: "number", min: "3", max: "120", step: "1",
    value: String(Math.round(settings.autoCloseInterval)),
    style: "width:72px",
  }) as HTMLInputElement;
  autoClose.addEventListener("change", () => {
    settings.autoCloseInterval = Math.max(3, Math.min(120, Number(autoClose.value) || 15));
    autoClose.value = String(settings.autoCloseInterval);
    void save();
  });

  const screen = h("select", {}) as HTMLSelectElement;
  screen.append(
    h("option", { value: "primary", text: "Main display" }),
    h("option", { value: "cursor", text: "Display under the cursor" }),
  );
  screen.value = settings.screen;
  screen.addEventListener("change", () => {
    settings.screen = screen.value as Settings["screen"];
    void save();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "General" })),
    h("div", { class: "row" },
      h("label", { text: "Sound" }),
      toggle(settings.soundEnabled, (v) => { settings.soundEnabled = v; void save(); }),
      volume,
    ),
    h("div", { class: "row" },
      h("label", { text: "Auto-close" }),
      autoClose,
      h("span", { class: "hint", text: "seconds after you leave the island" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Island lives on" }),
      screen,
    ),
    h("div", { class: "row" },
      h("label", { text: "Keep island visible" }),
      toggle(settings.keepVisible, (v) => { settings.keepVisible = v; void save(); }),
      h("span", { class: "hint", text: "stays compact at the top instead of hiding" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Quick screenshot" }),
      toggle(settings.quickScan, (v) => { settings.quickScan = v; void save(); }),
      h("span", { class: "hint", text: "skip Mochi's scan: capture 0.2 s after the drop" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Launch at startup" }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
  );
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
  }
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    claudeSection(status),
    apiSection(hasKey),
    modelsSection(),
    integrationsSection(present),
    wardrobeSection(),
    generalSection(),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    redrawModels();
  });
}

void main();
