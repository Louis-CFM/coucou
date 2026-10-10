// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type HookPreview, type HookStatus, type ShortcutsReport } from "../core/bridge";
import { CUSTOM_SERVER_KEY, providerDef, urlExposure } from "../core/providers";
import {
  ISLAND_SHORTCUTS, SHORTCUTS, SHORTCUT_TEXT, activeKeys, displayKeys, duplicates, effective,
  recordPress, type Binding,
} from "../core/shortcuts";
import { DEFAULT_PLUS, DEFAULT_SETTINGS, type PlusPrefs, type Settings } from "../core/state";
import { SOUND_NAMES } from "../core/sound";
import {
  HOST_OS, MAX_DECLARED, PILL_CATEGORIES, availablePills, chooseMainPill, isComingSoon, mainPillChoices,
  sanitizeDeclared, toggleDeclared, type PillDefinition,
} from "../core/pills";
import { h, clear } from "../views/dom";
import { agentsSection } from "./agents";
import { colorDot } from "./colors";
import { renderDiff, statusDot } from "./parts";
import {
  LANGUAGES, N_, isRtl, onLanguageChange, resolveLanguage, setLanguage, systemLanguages, t, tn,
} from "../i18n/i18n";

/** Where secrets.rs keeps the keys on this OS. */
const KEY_STORE = navigator.userAgent.includes("Windows")
  ? "Windows Credential Manager"
  : "Secret Service (GNOME Keyring, KWallet)";

let settings: Settings = { ...DEFAULT_SETTINGS };
let version = "";

const root = document.getElementById("settings-root")!;

async function save() {
  await Bridge.saveSettings(settings);
}

/** A colour was picked for a pill's Mochi (see ./colors.ts): the island follows. */
function pickColor(next: Record<string, string>) {
  settings.pillColors = next;
  void save();
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

// ── Changes to Claude Code's settings.json ────────────────────────────────────

/** One kind of change to ~/.claude/settings.json, with the words that go with it. */
interface Change {
  preview: (install: boolean) => Promise<HookPreview | null>;
  apply: (install: boolean, fingerprint: string) => Promise<string | null>;
  installText: string;
  removeText: string;
  installButton: string;
  removeButton: string;
  /** The note once written; `backup` is "" when there was no file to back up. */
  done: (backup: string) => string;
}

const HOOKS_CHANGE: Change = {
  preview: Bridge.hooksPreview,
  apply: Bridge.hooksApply,
  get installText() { return t("This is exactly what will change in your settings.json. Your own hooks are left untouched."); },
  get removeText() { return t("This removes Coucou's entries only. Your own hooks are left untouched."); },
  get installButton() { return t("Back up and write"); },
  get removeButton() { return t("Back up and remove"); },
  done: (backup) => backup
    ? t("Done. Previous settings saved as {backup}. Open a new Claude Code session to pick the hooks up.", { backup })
    : t("Done. Open a new Claude Code session to pick the hooks up."),
};

const STATUS_LINE_CHANGE: Change = {
  preview: Bridge.statusLinePreview,
  apply: Bridge.statusLineApply,
  get installText() { return t("This is exactly what will change: only the status line. If you already have one it keeps working, Coucou's relay runs it for you."); },
  get removeText() { return t("This puts your previous status line back, or removes the entry if there was none."); },
  get installButton() { return t("Back up and write"); },
  get removeButton() { return t("Back up and remove"); },
  done: (backup) => backup
    ? t("Done. Previous settings saved as {backup}. The numbers appear after the next reply of a Claude Code session.", { backup })
    : t("Done. The numbers appear after the next reply of a Claude Code session."),
};

/**
 * Shows the diff of a change in `body` and writes it only after an explicit
 * click, and only if settings.json still matches the diff that was shown.
 * `back` redraws the section; `applied` runs a moment after a successful write.
 */
async function reviewChange(
  body: HTMLElement,
  change: Change,
  install: boolean,
  back: () => void,
  applied: () => void,
) {
  let preview;
  try {
    preview = await change.preview(install);
  } catch (err) {
    // An unreadable or invalid settings.json stops here rather than being
    // treated as empty and written over.
    clear(body);
    body.append(
      h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
      h("div", { class: "row" }, h("button", { text: t("Back"), onclick: back })),
    );
    return;
  }
  if (!preview) return;
  clear(body);
  body.append(
    h("div", { class: "hint", text: install ? change.installText : change.removeText }),
    renderDiff(preview.diff),
    h("div", { class: "row" },
      h("span", {
        class: "path",
        text: preview.backup
          ? t("Backup → {path}", { path: preview.backup })
          : t("No settings.json yet — nothing to back up."),
      }),
    ),
  );
  const confirm = h("button", {
    class: install ? "primary" : "danger",
    text: install ? change.installButton : change.removeButton,
  });
  confirm.addEventListener("click", async () => {
    confirm.disabled = true;
    try {
      const backup = await change.apply(install, preview.fingerprint);
      clear(body);
      body.append(h("div", { class: "notice ok", text: change.done(backup ?? "") }));
      window.setTimeout(applied, 2600);
    } catch (err) {
      confirm.disabled = false;
      body.append(h("div", { class: "notice err", text: t("Could not write: {error}", { error: String(err) }) }));
    }
  });
  body.append(h("div", { class: "row" }, confirm, h("button", { text: t("Cancel"), onclick: back })));
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

  const redraw = () => {
    clear(body);
    draw();
  };
  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus();
    if (fresh) Object.assign(status, fresh);
    redraw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: "Claude Code" }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: status.installed
          ? t("Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.")
          : t("Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing."),
      }),
      h("div", { class: "row" },
        h("label", { text: "settings.json" }),
        h("span", { class: "path", text: status.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: t("Relay") }),
        h("span", { class: "path", text: status.hookPath }),
        statusDot(status.hookReady),
      ),
    );

    if (!status.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: t("coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`."),
      }));
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: status.installed ? t("Reinstall hooks…") : t("Install hooks…"),
      onclick: () => void reviewChange(body, HOOKS_CHANGE, true, redraw, () => void rebuild()),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every Claude Code session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = t("The relay isn't installed yet.");
    }
    actions.append(install);
    if (status.installed) {
      actions.append(h("button", {
        class: "danger",
        text: t("Uninstall hooks…"),
        onclick: () => void reviewChange(body, HOOKS_CHANGE, false, redraw, () => void rebuild()),
      }));
    }
    body.append(actions);
  }

  draw();
  return section;
}

// ── Plan usage section ────────────────────────────────────────────────────────

/**
 * The 5-hour and weekly limits in the island's header. They come from Claude
 * Code's status line, so the relay has to be the status line first: turning the
 * switch on without it starts the install, and the switch only stays on once
 * that has been confirmed. A status line the user had keeps working.
 */
const PLAN_SETTINGS_TEXT = {
  get claude() { return t("Shows your Claude plan usage (5-hour and weekly limits) in the island's header. Coucou adds a status line relay in ~/.claude/settings.json. If you already have a status line, it keeps working as before. Pro and Max plans only."); },
  get showClaude() { return t("Show in notch"); },
  get codex() { return t("Shows your Codex plan usage (weekly limit and free resets left) in the island's header. Coucou asks the Codex CLI (codex app-server) when the pill shows; nothing is installed. Codex must be signed in with ChatGPT."); },
  get showCodex() { return t("Show Codex plan in the notch"); },
};

function planSection(status: HookStatus): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h("section", {}, h("h2", {}, h("span", { text: t("Plan usage") })), body);

  const redraw = () => {
    clear(body);
    draw();
  };
  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus();
    if (fresh) Object.assign(status, fresh);
    settings.planRelayInstalled = status.planRelayInstalled;
    // Cancelled or failed: a switch that was waiting for the install falls back.
    if (!status.planRelayInstalled) settings.showPlanInNotch = false;
    redraw();
  };

  function draw() {
    // The switch shows "on" while the install it asked for is being reviewed.
    const sw = toggle(settings.showPlanInNotch, (on) => {
      if (!on) {
        settings.showPlanInNotch = false;
        void save();
      } else if (status.planRelayInstalled) {
        settings.showPlanInNotch = true;
        void save();
      } else {
        // Turned on before the relay is in: install it first; it stays on once confirmed.
        void reviewChange(body, STATUS_LINE_CHANGE, true, () => void rebuild(), () => {
          settings.planRelayInstalled = true;
          settings.showPlanInNotch = true;
          void save().then(rebuild);
        });
      }
    });
    body.append(
      h("div", {
        class: "hint",
        text: PLAN_SETTINGS_TEXT.claude,
      }),
      h("div", { class: "row" }, h("label", { text: PLAN_SETTINGS_TEXT.showClaude }), sw),
      h("div", { class: "row" },
        h("label", { text: t("Relay") }),
        statusDot(status.planRelayInstalled),
        h("span", { class: "hint", text: status.planRelayInstalled ? t("installed") : t("not installed") }),
        status.planRelayInstalled
          ? h("button", {
              class: "danger",
              text: t("Uninstall relay…"),
              onclick: () => void reviewChange(body, STATUS_LINE_CHANGE, false, redraw, () => void rebuild()),
            })
          : h("button", {
              class: "primary",
              text: t("Install relay…"),
              onclick: () => void reviewChange(body, STATUS_LINE_CHANGE, true, redraw, () => void rebuild()),
            }),
      ),
      // Codex: nothing to install, Coucou asks the Codex CLI when the pill shows.
      h("div", { class: "hint", text: PLAN_SETTINGS_TEXT.codex }),
      h("div", { class: "row" },
        h("label", { text: PLAN_SETTINGS_TEXT.showCodex }),
        toggle(settings.showCodexPlanInNotch, (on) => {
          settings.showCodexPlanInNotch = on;
          void save();
        }),
      ),
    );
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
  const state = h("span", { class: "hint", text: hasKey ? t("Key saved in the {store}.", { store: KEY_STORE }) : t("No key yet — the chat needs one.") });

  const field = h("input", {
    type: "password",
    placeholder: hasKey ? `••••••••••••  ${t("(stored)")}` : "sk-ant-...",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  const saveBtn = h("button", { class: "primary", text: t("Save key") });
  const clearBtn = h("button", { class: "danger", text: t("Remove") });
  const feedback = h("div", {});

  async function refresh() {
    const present = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
    dot.style.background = present ? "#22c55e" : "#f4505e";
    state.textContent = present
      ? t("Key saved in the {store}.", { store: KEY_STORE })
      : t("No key yet — the chat needs one.");
    field.placeholder = present ? `••••••••••••  ${t("(stored)")}` : "sk-ant-...";
    clearBtn.style.display = present ? "" : "none";
  }

  saveBtn.addEventListener("click", async () => {
    const value = field.value.trim();
    if (!value) return;
    clear(feedback);
    try {
      await Bridge.secretSet("anthropic-api-key", value);
      field.value = "";
      feedback.append(h("div", { class: "notice ok", text: t("Saved. It never touches disk.") }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: t("Could not save: {error}", { error: String(err) }) }));
    }
  });

  clearBtn.addEventListener("click", async () => {
    clear(feedback);
    try {
      await Bridge.secretClear("anthropic-api-key");
      feedback.append(h("div", { class: "notice ok", text: t("Key removed.") }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: t("Could not remove: {error}", { error: String(err) }) }));
    }
  });

  const model = h("select", {}) as HTMLSelectElement;
  for (const [id, label] of MODELS) model.append(h("option", { value: id, text: label }));
  if (!MODELS.some(([id]) => id === settings.model)) {
    model.append(h("option", { value: settings.model, text: settings.model }));
  }
  model.value = settings.model;
  model.addEventListener("change", () => {
    settings.model = model.value;
    void save();
  });

  clearBtn.style.display = hasKey ? "" : "none";

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Claude" })),
    state,
    h("div", { class: "row" }, h("label", { text: t("API key") }), field, saveBtn, clearBtn),
    h("div", { class: "row" }, h("label", { text: t("Model") }), model),
    feedback,
  );
}

// ── Active pills section ──────────────────────────────────────────────────────

/**
 * The tools you use (Mac 0.1.1–0.1.2): pick the main workspace tool, which is
 * always on and takes no slot, and declare the agents and chat providers you
 * want as pills. Services are declared in Integrations below, next to their keys.
 */
function activePillsSection(connected: Record<string, boolean>): HTMLElement {
  const slots = h("div", { class: "hint" });
  const main = h("select", {}) as HTMLSelectElement;
  for (const def of mainPillChoices()) main.append(h("option", { value: def.id, text: def.name }));
  main.addEventListener("change", () => {
    const next = chooseMainPill(settings, main.value);
    if (!next) return;
    settings.mainPill = next.mainPill;
    settings.activeIntegrations = next.activeIntegrations;
    declaredChanged();
  });
  const groups = h("div", { style: "display:flex;flex-direction:column;gap:12px" });

  /** Why a pill would show nothing yet, as on the Mac's row. */
  function hint(def: PillDefinition): string | null {
    if (isComingSoon(def.id)) return t("Coming soon");
    if (def.connect.kind === "hooks" && !connected[def.id]) return t("Hooks not installed");
    if (def.connect.kind === "key" && !connected[def.id]) return t("Key not configured");
    if (def.connect.kind === "server" && !settings[def.connect.field]) return t("Not connected");
    return null;
  }

  function row(def: PillDefinition): HTMLElement {
    const isMain = def.id === settings.mainPill;
    const on = settings.activeIntegrations.includes(def.id);
    const full = !isMain && !on && settings.activeIntegrations.length >= MAX_ACTIVE;
    const el = h("div", { class: full ? "pill-row full" : "pill-row" },
      colorDot(def, "width:10px;height:10px", () => settings.pillColors, pickColor),
      h("span", { class: "name", text: def.name }),
    );
    if (isMain) {
      el.append(h("span", { class: "state", text: t("Main") }));
      return el;
    }
    const why = hint(def);
    el.append(h("span", { class: "state", text: why ?? "" }));
    const sw = h("button", { class: on ? "switch on" : "switch" }) as HTMLButtonElement;
    sw.disabled = full;
    sw.addEventListener("click", () => {
      const next = toggleDeclared(settings, def.id);
      if (!next) return;
      settings.activeIntegrations = next;
      declaredChanged();
    });
    el.append(sw);
    return el;
  }

  function draw() {
    const used = settings.activeIntegrations.length;
    slots.textContent = t("{used}/{max} slots in use — the main tool doesn't take one.", { used, max: MAX_ACTIVE });
    slots.classList.toggle("full", used >= MAX_ACTIVE);
    main.value = settings.mainPill;
    clear(groups);
    for (const cat of PILL_CATEGORIES) {
      if (cat.id === "service") continue;
      const pills = availablePills().filter((p) => p.category === cat.id);
      if (pills.length === 0) continue;
      groups.append(h("div", { class: "pill-group" }, h("h3", { text: t(cat.title) }), ...pills.map(row)));
    }
  }
  declaredViews.push(draw);
  draw();

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("Active pills") })),
    h("div", { class: "hint", text: t("Choose the tools you use. Coucou only shows what you declare here.") }),
    slots,
    h("div", { class: "row" }, h("label", { text: t("Main tool") }), main),
    groups,
  );
}

// ── Chat providers section ────────────────────────────────────────────────────

const CHAT_STRINGS = {
  get providersTitle() { return t("Chat providers"); },
  get providersHint() { return t("Chat with Google AI, OpenAI or OpenRouter instead of Claude: add a key here, then click the model name above the chat box to switch provider and model. Keys stay in the system keychain. These providers get no web search and no tools: they can answer, never act on this computer."); },
  get stored() { return `••••••••  ${t("(stored)")}`; },
  get save() { return t("Save"); },
  get remove() { return t("Remove"); },
  get localTitle() { return t("Local models"); },
  get localHint() { return t("Chat with a model you run yourself: Ollama or LM Studio (leave the address empty for the usual one on this computer), or any server that speaks the OpenAI API, such as vLLM or llama.cpp. Once connected, pick it above the chat box."); },
  get connect() { return t("Connect"); },
  get connecting() { return t("Connecting…"); },
  get disconnect() { return t("Disconnect"); },
  get useInChat() { return t("Use in chat"); },
  get inUse() { return t("In use"); },
  get keyOptional() { return t("API key (optional)"); },
  get localOnly() { return t("Nothing leaves your PC: the server runs on this computer."); },
  get remote() { return t("This address is another machine: what you ask is sent to it."); },
  get remoteHttp() { return t("This address is another machine, over plain http: what you ask travels unencrypted."); },
  get keyOverHttp() { return t("Warning: the key would be sent unencrypted (http://) to another machine. Use https://, or a server on this computer."); },
  get invalid() { return t("Not a valid http:// or https:// address."); },
  noModels: (name: string) => t("No models yet. Download one in {name} first.", { name }),
  models: (n: number) => tn("{count} model", "{count} models", n),
};

interface CloudDef {
  id: "google" | "openai" | "openrouter";
  name: string;
  placeholder: string;
  where: string;
}

const CLOUD: CloudDef[] = [
  { id: "google", name: "Google AI", placeholder: "AIza…", where: "aistudio.google.com" },
  { id: "openai", name: "OpenAI", placeholder: "sk-…", where: "platform.openai.com" },
  { id: "openrouter", name: "OpenRouter", placeholder: "sk-or-…", where: "openrouter.ai/keys" },
];

function chatProvidersSection(
  present: Record<string, boolean>,
  keyChanged: (key: string, on: boolean) => void,
): HTMLElement {
  const list = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
  for (const def of CLOUD) {
    const p = providerDef(def.id);
    const key = p.key!;
    const input = h("input", {
      type: "password",
      placeholder: present[key] ? CHAT_STRINGS.stored : def.placeholder,
      autocomplete: "off",
      spellcheck: "false",
      style: "flex:1 1 auto;min-width:0",
    }) as HTMLInputElement;
    const dotEl = statusDot(present[key] ?? false);
    const saveBtn = h("button", { text: CHAT_STRINGS.save });
    const removeBtn = h("button", { class: "danger", text: CHAT_STRINGS.remove });
    const refresh = () => {
      input.placeholder = present[key] ? CHAT_STRINGS.stored : def.placeholder;
      dotEl.style.background = present[key] ? "#22c55e" : "#f4505e";
      removeBtn.style.display = present[key] ? "" : "none";
    };
    saveBtn.addEventListener("click", async () => {
      const value = input.value.trim();
      if (!value) return;
      try {
        await Bridge.secretSet(key, value);
        present[key] = true;
        input.value = "";
        keyChanged(key, true);
      } catch {
        dotEl.style.background = "#f5a524";
        return;
      }
      refresh();
    });
    removeBtn.addEventListener("click", async () => {
      try {
        await Bridge.secretClear(key);
        present[key] = false;
        keyChanged(key, false);
      } catch {
        dotEl.style.background = "#f5a524";
        return;
      }
      refresh();
    });
    refresh();
    list.append(
      h("div", { class: "row" },
        h("label", {},
          h("i", { class: "dot", style: `background:${p.accent};margin-right:8px` }),
          h("span", { text: def.name }),
        ),
        input, saveBtn, removeBtn, dotEl,
      ),
      h("div", { class: "hint", style: "margin:-4px 0 0 144px", text: t("Key from {site}", { site: def.where }) }),
    );
  }
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: CHAT_STRINGS.providersTitle })),
    h("div", { class: "hint", text: CHAT_STRINGS.providersHint }),
    list,
  );
}

// ── Local models section ──────────────────────────────────────────────────────

type LocalId = "ollama" | "lmstudio" | "custom";

/** Redraws the local models section after a change made elsewhere (the island). */
let localRedraw: (() => void) | null = null;

const LOCAL: Record<LocalId, { name: string; usual: string }> = {
  ollama: { name: "Ollama", usual: "http://127.0.0.1:11434" },
  lmstudio: { name: "LM Studio", usual: "http://127.0.0.1:1234" },
  // No usual address: any server that speaks the OpenAI API.
  custom: { name: N_("OpenAI-compatible"), usual: "" },
};

/** What an address means for the user's data, as a hint line. */
function exposureNotice(url: string, withKey: boolean): HTMLElement | null {
  switch (urlExposure(url)) {
    case "local":
      return h("div", { class: "hint", text: CHAT_STRINGS.localOnly });
    case "remote":
      return h("div", { class: "hint", text: CHAT_STRINGS.remote });
    case "remote-http":
      return withKey
        ? h("div", { class: "notice warn", text: CHAT_STRINGS.keyOverHttp })
        : h("div", { class: "hint", text: CHAT_STRINGS.remoteHttp });
    case "invalid":
      return url.trim() ? h("div", { class: "notice err", text: CHAT_STRINGS.invalid }) : null;
  }
}

function localSection(customKey: boolean): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:14px" });
  const section = h(
    "section",
    {},
    h("h2", {}, h("span", { text: CHAT_STRINGS.localTitle })),
    h("div", { class: "hint", text: CHAT_STRINGS.localHint }),
    body,
  );
  const redraw = () => {
    clear(body);
    for (const id of Object.keys(LOCAL) as LocalId[]) body.append(serverBlock(id));
  };

  function serverBlock(id: LocalId): HTMLElement {
    const def = LOCAL[id];
    const p = providerDef(id);
    const field = p.urlField!;
    const connected = settings[field] !== "";
    const status = h("div", {});
    const exposure = h("div", {});
    const label = h("label", {},
      h("i", { class: "dot", style: `background:${p.accent};margin-right:8px` }),
      h("span", { text: t(def.name) }),
    );
    const block = h("div", { style: "display:flex;flex-direction:column;gap:6px" });

    if (connected) {
      const inUse = settings.chatProvider === id;
      const use = h("button", { class: inUse ? "" : "primary", text: inUse ? CHAT_STRINGS.inUse : CHAT_STRINGS.useInChat });
      use.disabled = inUse;
      use.addEventListener("click", () => {
        settings.chatProvider = id;
        void save().then(redraw);
      });
      const disconnect = h("button", { class: "danger", text: CHAT_STRINGS.disconnect });
      disconnect.addEventListener("click", async () => {
        settings[field] = "";
        if (settings.chatProvider === id) settings.chatProvider = "anthropic";
        if (id === "custom") {
          await Bridge.secretClear(CUSTOM_SERVER_KEY).catch(() => {});
          customKey = false;
        }
        await save();
        redraw();
      });
      block.append(
        h("div", { class: "row" }, label, h("span", { class: "path", text: settings[field] }), statusDot(true), use, disconnect),
        status,
      );
      exposure.append(exposureNotice(settings[field], id === "custom" && customKey) ?? "");
      block.append(exposure);
      return block;
    }

    const input = h("input", {
      type: "text",
      placeholder: def.usual || "https://llm.example.com",
      style: "flex:1 1 auto;min-width:0",
      spellcheck: "false",
      autocomplete: "off",
    }) as HTMLInputElement;
    // A custom server may want a key; it goes to the keychain, never to settings.json.
    const key = h("input", {
      type: "password",
      placeholder: customKey ? CHAT_STRINGS.stored : CHAT_STRINGS.keyOptional,
      style: "flex:1 1 auto;min-width:0",
      autocomplete: "off",
      spellcheck: "false",
    }) as HTMLInputElement;
    const connect = h("button", { class: "primary", text: CHAT_STRINGS.connect });

    const showExposure = () => {
      clear(exposure);
      const withKey = id === "custom" && (customKey || key.value.trim() !== "");
      const notice = exposureNotice(input.value || def.usual, withKey);
      if (notice) exposure.append(notice);
    };
    input.addEventListener("input", showExposure);
    key.addEventListener("input", showExposure);

    connect.addEventListener("click", async () => {
      connect.disabled = true;
      clear(status);
      status.append(h("div", { class: "hint", text: CHAT_STRINGS.connecting }));
      try {
        if (id === "custom" && key.value.trim()) {
          // Stored with this address: the key is only ever sent there.
          await Bridge.localSetKey(input.value || def.usual, key.value.trim());
          key.value = "";
          customKey = true;
        }
        const server = await Bridge.localConnect(id, input.value);
        if (!server.models.length) {
          clear(status);
          status.append(h("div", { class: "notice err", text: CHAT_STRINGS.noModels(t(def.name)) }));
        } else {
          settings[field] = server.url;
          if (!server.models.includes(settings.chatModels[id] ?? "")) {
            settings.chatModels = { ...settings.chatModels, [id]: server.models[0] };
          }
          await save();
          redraw();
          return;
        }
      } catch (err) {
        clear(status);
        status.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
      }
      connect.disabled = false;
    });

    block.append(h("div", { class: "row" }, label, input, connect));
    if (id === "custom") block.append(h("div", { class: "row" }, h("label", { text: "" }), key));
    block.append(status, exposure);
    showExposure();
    return block;
  }

  redraw();
  localRedraw = redraw;
  return section;
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
  /** What the key needs, shown under its field. */
  hint?: string;
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: N_("Secret key"), placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: N_("Token"), placeholder: "ghp_…", secret: true }],
    hint: N_("Classic token with the repo scope, or fine-grained with read access to Pull requests, Commit statuses and Actions.") },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: N_("Token"), placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: N_("Instance URL"), placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: N_("API key"), placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: N_("API key"), placeholder: "re_…", secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: N_("Integration token"), placeholder: "ntn_…", secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: N_("API key"), placeholder: "cal_…", secret: true }] },
  { id: "integration_calendar", name: "iCal", color: "#4F9DF7",
    fields: [{ key: "calendar-ics-url", label: N_("iCal link"), placeholder: "https://…/basic.ics", secret: true }],
    hint: N_("Google Calendar: Settings → your calendar → Secret address in iCal format. Outlook: Settings → Shared calendars → Publish → ICS.") },
  // Nothing to enter: the music pills read the player (D-Bus on Linux, the
  // media controls on Windows — see core/pills.ts).
  { id: "integration_music", name: "Apple Music", color: "#FA2D48", fields: [] },
  { id: "integration_spotify", name: "Spotify", color: "#1DB954", fields: [] },
  { id: "integration_media", name: "Now Playing", color: "#A78BFA", fields: [],
    hint: N_("Any app that plays: a browser tab, VLC, Media Player…") },
];

const MAX_ACTIVE = MAX_DECLARED;

/** Everything that shows the declared pills, redrawn when any of them changes. */
const declaredViews: (() => void)[] = [];

function declaredChanged() {
  for (const redraw of declaredViews) redraw();
  void save();
}

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = t("Pick up to {max} pills to show next to Mochi — {used}/{max} in use. Keys are stored in the {store}, never on disk.", { max: MAX_ACTIVE, used, store: KEY_STORE });
  }
  declaredViews.push(updateNote);

  const offered = new Set(availablePills().map((p) => p.id));
  for (const def of INTEGRATIONS.filter((d) => offered.has(d.id))) {
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
      declaredChanged();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    for (const field of def.fields) {
      const input = h("input", {
        type: field.secret ? "password" : "text",
        placeholder: present[field.key] ? CHAT_STRINGS.stored : field.placeholder,
        autocomplete: "off",
        spellcheck: "false",
        style: "flex:1 1 auto;min-width:0",
      }) as HTMLInputElement;
      const saveBtn = h("button", { text: t("Save") });
      const dotEl = statusDot(present[field.key] ?? false);
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        try {
          await Bridge.secretSet(field.key, value);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? CHAT_STRINGS.stored : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: t(field.label) }),
          input, saveBtn, dotEl,
        ),
      );
    }

    if (def.hint) rows.append(h("div", { class: "hint", text: t(def.hint) }));
    if (def.id === "integration_spotify" || def.id === "integration_music") {
      // As on the Mac's row: said only when there is no player to launch.
      const hint = h("div", { class: "hint", style: "padding-top:5px" });
      rows.append(hint);
      void Bridge.spotifyInstalled(def.id).then((ok) => {
        hint.textContent = ok === false ? t("Not installed") : "";
      });
    }

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
        h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
          sw,
          colorDot(def, "", () => settings.pillColors, pickColor),
          h("span", { style: "font-size:12.5px", text: def.name }),
        ),
        rows,
      ),
    );
  }

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: t("Integrations") })), note, list);
}

// ── General section ───────────────────────────────────────────────────────────

function generalSection(): HTMLElement {
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    value: String(settings.soundVolume),
  }) as HTMLInputElement;
  volume.addEventListener("input", () => {
    settings.soundVolume = Number(volume.value);
    void save();
  });

  // Your own sounds: the folder, a reload, and how many are replaced.
  const customCount = h("span", { class: "hint" });
  const countCustom = () =>
    void Bridge.customSounds(SOUND_NAMES).then((own) => {
      const n = own?.length ?? 0;
      customCount.textContent = n > 0 ? t("{0} custom", { 0: n }) : "";
    });
  countCustom();
  const soundsFolder = h("button", { text: t("Open sounds folder"), onclick: () => void Bridge.revealSoundsFolder() });
  const reloadSounds = h("button", {
    text: t("Reload sounds"),
    onclick: () => void Bridge.reloadSounds().then(() => window.setTimeout(countCustom, 300)),
  });

  const autoClose = h("input", {
    type: "number", min: "5", max: "120", step: "1",
    value: String(Math.round(settings.autoCloseInterval)),
    style: "width:72px",
  }) as HTMLInputElement;
  autoClose.addEventListener("change", () => {
    settings.autoCloseInterval = Math.max(5, Math.min(120, Number(autoClose.value) || 15));
    autoClose.value = String(settings.autoCloseInterval);
    void save();
  });

  const screen = h("select", {}) as HTMLSelectElement;
  screen.append(
    h("option", { value: "primary", text: t("Main display") }),
    h("option", { value: "cursor", text: t("Display under the cursor") }),
  );
  screen.value = settings.screen;
  void Bridge.listMonitors().then((list) => {
    for (const m of list ?? []) screen.append(h("option", { value: m.key, text: m.label }));
    // Set again now the option exists. A display saved under an older key (moved,
    // resized, or saved before names were kept) is shown by its place or its
    // name; one that is gone shows as the main one.
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
  screen.addEventListener("change", () => {
    settings.screen = screen.value;
    void save();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("General") })),
    h("div", { class: "row" },
      h("label", { text: t("Sound") }),
      toggle(settings.soundEnabled, (v) => { settings.soundEnabled = v; void save(); }),
      volume,
    ),
    h("div", { class: "row" }, soundsFolder, reloadSounds, customCount),
    h("div", { class: "hint", text: t("Drop a file named like one of Mochi's sounds (finish.wav, approval.mp3, greet.m4a…) in the sounds folder to replace it, then Reload.") }),
    h("div", { class: "row" },
      h("label", { text: t("Open on hover") }),
      toggle(settings.openOnHover, (v) => { settings.openOnHover = v; void save(); }),
    ),
    h("div", { class: "hint", text: t("Hovering the island opens it; it folds again shortly after the pointer leaves. Click inside to keep it open.") }),
    h("div", { class: "row" },
      h("label", { text: t("Auto-close") }),
      autoClose,
      h("span", { class: "hint", text: t("seconds after you leave the island") }),
    ),
    h("div", { class: "row" },
      h("label", { text: t("Island lives on") }),
      screen,
    ),
    h("div", { class: "row" },
      h("label", { text: t("Launch at startup") }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
    ...recapRows(),
    languageRow(),
  );
}

/** Settings → Island extras (Windows): the live activities and the clipboard. */
function islandExtrasSection(): HTMLElement {
  const plus = (): PlusPrefs => (settings.plus = { ...DEFAULT_PLUS, ...settings.plus });
  const item = (key: keyof PlusPrefs, label: string, hint: string) => [
    h("div", { class: "row" },
      h("label", { text: t(label) }),
      toggle(plus()[key], (v) => { plus()[key] = v; void save(); }),
    ),
    h("div", { class: "hint", text: t(hint) }),
  ];
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("Island extras") })),
    ...item("alwaysVisible", N_("Always show the island"), N_("The compact island stays at the top of the screen instead of hiding after a minute.")),
    ...item("volumeHud", N_("Volume"), N_("The volume keys show the level in the island instead of Windows' popup.")),
    ...item("brightnessHud", N_("Brightness"), N_("The island shows the brightness when it changes.")),
    ...item("batteryAlerts", N_("Battery"), N_("Plugged in, unplugged, and a word at 20 % and 10 % left.")),
    ...item("clipboardHistory", N_("Clipboard history"), N_("The last texts you copied, on the Shelf pill. Kept in memory only, never on disk; what password managers copy is never kept.")),
  );
}

/**
 * Settings → iPhone (Windows): links both ways through iCloud Drive, and
 * alerts on the phone through ntfy. No Mac and no Apple account here.
 */
function iphoneSection(): HTMLElement {
  const plus = (): PlusPrefs => (settings.plus = { ...DEFAULT_PLUS, ...settings.plus });
  const item = (key: keyof PlusPrefs, label: string, hint: string) => [
    h("div", { class: "row" },
      h("label", { text: t(label) }),
      toggle(plus()[key], (v) => { plus()[key] = v; void save(); }),
    ),
    h("div", { class: "hint", text: t(hint) }),
  ];
  const status = h("div", { class: "hint" });
  void Bridge.phoneStatus().then((s) => {
    status.textContent = !s ? "" : s.icloud
      ? t("iCloud Drive found. Shared folder: {0}", { 0: s.folder })
      : t("iCloud Drive not found. Install iCloud for Windows from the Microsoft Store and sign in.");
  });
  const steps = h("ol", { class: "hint", style: "margin:4px 0 8px 18px;padding:0;line-height:1.6" },
    ...[
      N_("On the iPhone, open Shortcuts → + → name it “Send to laptop”, and turn on “Show in Share Sheet”."),
      N_("Add “Receive URLs and Text from Share Sheet”, then “Save File” → iCloud Drive/Coucou/to-laptop, with “Ask Where to Save” off."),
      N_("For the other way, a second Shortcut: “Get File” from iCloud Drive/Coucou/to-iphone.txt, then “Copy to Clipboard” (or “Open URLs”)."),
    ].map((s) => h("li", { text: t(s) })),
  );

  const topic = h("input", {
    type: "password", placeholder: t("ntfy topic, e.g. mithun-coucou-7x9q2"), autocomplete: "off", spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  const dotEl = statusDot(false);
  void Bridge.secretPresent("ntfy-topic").then((ok) => { dotEl.style.background = ok ? "#22c55e" : "#f4505e"; });
  const saveBtn = h("button", { text: t("Save") });
  saveBtn.addEventListener("click", async () => {
    const value = topic.value.trim();
    await Bridge.secretSet("ntfy-topic", value);
    topic.value = "";
    dotEl.style.background = value ? "#22c55e" : "#f4505e";
  });
  const testBtn = h("button", { text: t("Send a test") });
  const testNote = h("span", { class: "hint" });
  testBtn.addEventListener("click", async () => {
    const ok = await Bridge.phonePush("Coucou", t("Mochi says hi from your laptop 👋"), false, true);
    testNote.textContent = ok ? t("Sent — check your iPhone.") : t("Not sent: check the topic.");
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: t("iPhone") })),
    ...item("icloudBridge", N_("Links from iPhone"), N_("Share a link or text from the iPhone and it lands on the laptop's clipboard, with a card in the island. Goes through your own iCloud Drive.")),
    status,
    steps,
    ...item("shareCopiesToIphone", N_("Copies to iPhone"), N_("What you copy on the laptop is saved for the iPhone's “Get from laptop” Shortcut. Off by default: it puts your copies in iCloud Drive.")),
    h("div", { class: "row" }, h("label", { text: t("Phone alerts") }), topic, saveBtn, dotEl),
    h("div", { class: "hint", text: t("Install the free ntfy app on the iPhone, subscribe to a long, hard-to-guess topic, and paste the same topic here. Anyone who knows the topic can read the alerts.") }),
    h("div", { class: "row" }, testBtn, testNote),
    ...item("pushOnlyWhenAway", N_("Only when I'm away"), N_("Alerts go to the phone only after a minute without keyboard or mouse: an agent finished, failed, or needs your answer.")),
    ...item("notifications", N_("Notifications in the island"), N_("Your iPhone's calls and messages (through Microsoft Phone Link) and other apps' notifications, shown in the island and never stored. Needs the identity package: run identity\\make-identity.ps1 once, then click Allow.")),
  );
}

/**
 * Settings → General → Language, as on the Mac: "System" follows the
 * system's language when Coucou has it (else English), or one of the ten.
 * Both windows and the tray switch in place, without a restart.
 */
function languageRow(): HTMLElement {
  const select = h("select", {}) as HTMLSelectElement;
  select.append(h("option", { value: "", text: t("System") }));
  for (const { code, name } of LANGUAGES) select.append(h("option", { value: code, text: name, lang: code }));
  select.value = LANGUAGES.some((l) => l.code === settings.language) ? settings.language : "";
  select.addEventListener("change", () => {
    settings.language = select.value;
    void save();
    applyLanguage();
  });
  return h("div", { class: "row" }, h("label", { text: t("Language") }), select);
}

// ── Shortcuts section ─────────────────────────────────────────────────────────

const SHORTCUTS_UI = {
  get title() { return t("Shortcuts"); },
  get hint() { return t("Work from any app. Click a shortcut to change it, then press the new keys — Esc cancels, Backspace removes it."); },
  get global() { return t("From anywhere"); },
  get island() { return t("In the open island"); },
  get recording() { return t("Press keys…"); },
  get none() { return t("None"); },
  get reset() { return t("Reset to defaults"); },
  get inUse() { return t("In use by another app"); },
  get duplicate() { return t("Used twice"); },
  get invalid() { return t("Not a valid shortcut"); },
  get unavailable() { return t("Not available"); },
  types: (ch: string) => t("Types “{char}”", { char: ch }),
  typesNote: (keys: string, ch: string) =>
    t("{keys} types “{char}” on your keyboard, so it can't be a shortcut. Pick another key.", { keys, char: ch }),
  get needsModifier() { return t("Hold Ctrl, Alt or the Windows key with it."); },
  get unsupportedKey() { return t("That key can't be used in a shortcut."); },
  get wayland() {
    return t("Your Wayland desktop doesn't let apps listen for keys outside their own windows. Add the shortcuts in your system's keyboard settings instead, with these commands:");
  },
  get noDisplay() { return t("No display server was found, so global shortcuts are off."); },
  get portalPending() {
    return t("Asking your desktop to register the shortcuts. It may show its own window to confirm them.");
  },
  get portalActive() {
    return t("These shortcuts are registered with your desktop. It may ask you to confirm them or to pick other keys; when it says which keys it uses, they show next to each shortcut.");
  },
  get portalFallback() {
    return t("If one doesn't work, you can also add it in your system's keyboard settings with these commands:");
  },
  desktopKeys: (keys: string) => t("Desktop: {keys}", { keys }),
  get refused() { return t("Not set by your desktop"); },
};

function shortcutsSection(initial: ShortcutsReport | null): HTMLElement {
  let report = initial;
  const list = h("div", { class: "shortcut-list" });
  const feedback = h("div", {});
  const blockedNote = h("div", {});

  let stopRecording: (() => void) | null = null;

  function store(id: string, binding: Binding) {
    settings.shortcuts = { ...settings.shortcuts, [id]: binding };
    void save();
  }

  function tagFor(id: string, dups: Set<string>): HTMLElement | null {
    if (dups.has(id)) return h("span", { class: "tag err", text: SHORTCUTS_UI.duplicate });
    const st = report?.actions.find((a) => a.id === id);
    switch (st?.status) {
      case "inUse": return h("span", { class: "tag warn", text: SHORTCUTS_UI.inUse });
      case "duplicate": return h("span", { class: "tag err", text: SHORTCUTS_UI.duplicate });
      case "invalid": return h("span", { class: "tag err", text: SHORTCUTS_UI.invalid });
      case "typesCharacter": return h("span", { class: "tag warn", text: SHORTCUTS_UI.types(st.typed ?? "?") });
      case "unsupported": return h("span", { class: "tag", text: SHORTCUTS_UI.unavailable });
      case "refused": return h("span", { class: "tag warn", text: SHORTCUTS_UI.refused });
      // Wayland: the desktop may run it on other keys than the ones asked for.
      case "active": return st.trigger ? h("span", { class: "tag", text: SHORTCUTS_UI.desktopKeys(st.trigger) }) : null;
      default: return null;
    }
  }

  function record(id: string, binding: Binding, button: HTMLButtonElement) {
    stopRecording?.();
    clear(feedback);
    button.classList.add("recording");
    button.textContent = SHORTCUTS_UI.recording;
    void Bridge.shortcutsSuspend(true);

    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      const result = recordPress(e);
      switch (result.kind) {
        case "pending":
          return;
        case "keys":
          finish();
          store(id, { keys: result.keys, enabled: true });
          return;
        case "clear":
          finish();
          store(id, { keys: "", enabled: binding.enabled });
          return;
        case "typesCharacter":
          finish();
          feedback.append(h("div", {
            class: "notice warn",
            text: SHORTCUTS_UI.typesNote(displayKeys(result.keys), result.typed),
          }));
          return;
        case "needsModifier":
          feedback.replaceChildren(h("div", { class: "notice warn", text: SHORTCUTS_UI.needsModifier }));
          return;
        case "unsupported":
          feedback.replaceChildren(h("div", { class: "notice warn", text: SHORTCUTS_UI.unsupportedKey }));
          return;
        case "cancel":
          finish();
          return;
      }
    };
    const onBlur = () => finish();

    function finish() {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("blur", onBlur);
      stopRecording = null;
      // Takes the global shortcuts back, from what is saved by now.
      void Bridge.shortcutsSuspend(false);
      draw();
    }
    stopRecording = finish;
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("blur", onBlur);
  }

  function draw() {
    clear(list);
    const dups = duplicates(activeKeys(settings.shortcuts));
    for (const d of SHORTCUTS) {
      if (!d.ported) continue;
      const binding = effective(d, settings.shortcuts);
      const keycap = h("button", {
        class: "keycap",
        text: binding.keys ? displayKeys(binding.keys) : SHORTCUTS_UI.none,
      }) as HTMLButtonElement;
      keycap.disabled = !binding.enabled;
      keycap.addEventListener("click", () => record(d.id, binding, keycap));
      const sw = toggle(binding.enabled, (on) => store(d.id, { keys: binding.keys, enabled: on }));
      const tag = binding.enabled ? tagFor(d.id, dups) : null;
      list.append(h("div", { class: binding.enabled ? "row shortcut" : "row shortcut off" },
        sw,
        h("span", { class: "shortcut-name", text: t(SHORTCUT_TEXT[d.id]) }),
        ...(tag ? [tag] : []),
        keycap,
      ));
    }

    clear(blockedNote);
    const commands = (command: string) => {
      const list = h("div", { class: "diff" });
      for (const d of SHORTCUTS) {
        if (d.ported) list.append(h("div", { class: "ctx", text: `${command} ${d.id}` }));
      }
      return list;
    };
    if (report?.portal) {
      // Wayland, through the desktop's GlobalShortcuts portal; the commands
      // stay as a way around a shortcut the desktop didn't take.
      const active = report.portal === "active";
      blockedNote.append(
        h("div", {
          class: active ? "notice ok" : "notice",
          text: active ? SHORTCUTS_UI.portalActive : SHORTCUTS_UI.portalPending,
        }),
        h("div", { class: "hint", text: SHORTCUTS_UI.portalFallback }),
        commands(report.command),
      );
    } else if (report?.blocked === "wayland") {
      blockedNote.append(h("div", { class: "notice warn", text: SHORTCUTS_UI.wayland }), commands(report.command));
    } else if (report?.blocked) {
      blockedNote.append(h("div", { class: "notice warn", text: SHORTCUTS_UI.noDisplay }));
    }
  }

  const islandList = h("div", { class: "shortcut-list" });
  for (const row of ISLAND_SHORTCUTS) {
    islandList.append(h("div", { class: "row shortcut" },
      h("span", { class: "shortcut-name", text: t(row.description) }),
      h("span", { class: "keycap static", text: row.keys }),
    ));
  }

  const reset = h("button", {
    text: SHORTCUTS_UI.reset,
    onclick: () => {
      stopRecording?.();
      settings.shortcuts = {};
      clear(feedback);
      void save();
      draw();
    },
  });

  // The events are listened to once (see main); only the section on screen redraws.
  shortcutsListener = {
    report(fresh) {
      report = fresh;
      if (!stopRecording) draw();
    },
    settingsChanged() {
      if (!stopRecording) draw();
    },
  };

  draw();
  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: SHORTCUTS_UI.title })),
    h("div", { class: "hint", text: SHORTCUTS_UI.hint }),
    h("div", { class: "subhead", text: SHORTCUTS_UI.global }),
    list,
    blockedNote,
    feedback,
    h("div", { class: "row" }, reset),
    h("div", { class: "subhead", text: SHORTCUTS_UI.island }),
    islandList,
  );
}

/** Settings → General → Weekly recap. The prefs live with the history in Rust. */
function recapRows(): HTMLElement[] {
  const T = {
    label: t("Weekly recap"),
    keep: t("Keep a history of my coding sessions"),
    clear: t("Clear history"),
    cleared: t("History cleared."),
    about: t("Counts and project names only — never commands, files or prompts. Kept on this computer for 12 weeks."),
  };
  const feedback = h("span", { class: "hint" });
  const sw = toggle(true, (v) => { void Bridge.recapSetEnabled(v); });
  void Bridge.recapPrefs().then((prefs) => {
    if (prefs) sw.classList.toggle("on", prefs.enabled);
  });
  const clearBtn = h("button", {
    class: "danger",
    text: T.clear,
    onclick: async () => {
      clearBtn.disabled = true;
      await Bridge.recapClear();
      feedback.textContent = T.cleared;
      window.setTimeout(() => {
        clearBtn.disabled = false;
        feedback.textContent = "";
      }, 2400);
    },
  }) as HTMLButtonElement;
  return [
    h("div", { class: "row" },
      h("label", { text: T.label }),
      sw,
      h("span", { class: "hint", text: T.keep }),
    ),
    h("div", { class: "row" },
      h("label", {}),
      clearBtn,
      feedback,
    ),
    h("div", { class: "row" },
      h("label", {}),
      h("span", { class: "hint", style: "flex:1 1 0;min-width:0", text: T.about }),
    ),
  ];
}

// ── Language ──────────────────────────────────────────────────────────────────

/** The shortcuts section on screen, told about the events listened to once in main. */
let shortcutsListener: { report(fresh: ShortcutsReport): void; settingsChanged(): void } | null = null;

/**
 * Shows the language Settings asks for. A change redraws the window in place,
 * where it was scrolled to: nothing reloads, nothing is written.
 */
function applyLanguage() {
  setLanguage(resolveLanguage(settings.language, systemLanguages()));
}

function applyDirection() {
  document.documentElement.dir = isRtl() ? "rtl" : "ltr";
  document.title = t("Settings — Coucou");
}

let rendering: Promise<void> | null = null;
let renderAgain = false;

/** Redraws every section from fresh state, keeping the scroll position. */
async function rerender() {
  if (rendering) {
    renderAgain = true;
    return;
  }
  const scroll = document.scrollingElement?.scrollTop ?? 0;
  rendering = render();
  try {
    await rendering;
  } finally {
    rendering = null;
  }
  if (document.scrollingElement) document.scrollingElement.scrollTop = scroll;
  if (renderAgain) {
    renderAgain = false;
    await rerender();
  }
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
  }
  setLanguage(resolveLanguage(settings.language, systemLanguages()));
  applyDirection();
  onLanguageChange(() => {
    applyDirection();
    void rerender();
  });
  await render();

  void onEvent<ShortcutsReport>("shortcuts-status", (fresh) => shortcutsListener?.report(fresh));
  void onEvent<Settings>("settings-changed", (s) => {
    const before = `${settings.chatProvider}|${settings.ollamaUrl}|${settings.lmstudioUrl}|${settings.customUrl}`;
    settings = { ...settings, ...s };
    shortcutsListener?.settingsChanged();
    for (const redraw of declaredViews) redraw();
    const after = `${settings.chatProvider}|${settings.ollamaUrl}|${settings.lmstudioUrl}|${settings.customUrl}`;
    if (before !== after) localRedraw?.();
    applyLanguage();
  });
}

/** Reads what the sections show and draws them all. */
async function render() {
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, planRelayInstalled: false, settingsPath: "", hookPath: "", hookReady: false,
  };
  const agents = await Bridge.agentHooksList();

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
  const shortcutReport = await Bridge.shortcutsStatus();

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key", "calendar-ics-url",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  // A main pill this build can run, and no pill declared twice.
  settings = { ...settings, ...sanitizeDeclared(settings) };
  const connected: Record<string, boolean> = { ...((await Bridge.agentHooksStatus()) ?? {}) };
  for (const def of availablePills()) {
    if (def.connect.kind === "key") {
      connected[def.id] = present[def.connect.key] ?? (await Bridge.secretPresent(def.connect.key)) ?? false;
    }
  }
  /** A chat provider's key was saved or removed: its pill's row says so at once. */
  const keyChanged = (key: string, on: boolean) => {
    for (const def of availablePills()) {
      if (def.connect.kind === "key" && def.connect.key === key) connected[def.id] = on;
    }
    for (const redraw of declaredViews) redraw();
  };
  const chatKeys: Record<string, boolean> = {};
  for (const def of CLOUD) {
    const key = providerDef(def.id).key!;
    chatKeys[key] = (await Bridge.secretPresent(key)) ?? false;
  }
  const customKey = (await Bridge.secretPresent(CUSTOM_SERVER_KEY)) ?? false;

  declaredViews.length = 0;
  localRedraw = null;
  shortcutsListener = null;
  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    claudeSection(status),
    agentsSection(agents),
    planSection(status),
    apiSection(hasKey),
    chatProvidersSection(chatKeys, keyChanged),
    localSection(customKey),
    activePillsSection(connected),
    integrationsSection(present),
    generalSection(),
    ...(HOST_OS === "windows" ? [islandExtrasSection(), iphoneSection()] : []),
    shortcutsSection(shortcutReport),
    h("div", {
      class: "hint",
      text: t("No telemetry. Network requests only go to the services you configure yourself."),
    }),
  );
}

void main();
