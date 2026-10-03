// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type GithubAccount, type HookStatus } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
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

/** Green for what is in place, red for what is missing. */
const statusColor = (ok: boolean) => (ok ? "var(--green)" : "var(--red)");

function statusDot(ok: boolean): HTMLElement {
  return h("i", { class: "dot", style: `background:${statusColor(ok)}` });
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
    dot.style.background = statusColor(present);
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
    clear(feedback);
    try {
      await Bridge.secretClear("anthropic-api-key");
      feedback.append(h("div", { class: "notice ok", text: "Key removed." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
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
    h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn),
    h("div", { class: "row" }, h("label", { text: "Model" }), model),
    feedback,
  );
}

// ── GitHub setup ──────────────────────────────────────────────────────────────

const GITHUB_ID = "integration_github";
const GITHUB_KEY = "github-token";
const GITHUB_NEW_TOKEN_URL = "https://github.com/settings/personal-access-tokens/new";
const DAY_MS = 86_400_000;
/** A token this close to its end gets a word about it. */
const EXPIRES_SOON_DAYS = 7;

/** GitHub's line in the integrations, and what opens under it once it is on. */
function githubSetup(present: Record<string, boolean>): IntegrationSetup {
  const hasToken = present[GITHUB_KEY] ?? false;
  const dot = statusDot(hasToken);
  const state = h("span", { class: "hint" });

  const field = h("input", {
    type: "password",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  const saveBtn = h("button", { class: "primary", text: "Save token" });
  const clearBtn = h("button", { class: "danger", text: "Remove" });
  const testBtn = h("button", { text: "Test connection" });
  const feedback = h("div", {});

  function show(present: boolean) {
    dot.style.background = statusColor(present);
    state.textContent = present
      ? "Token saved in the Windows Credential Manager."
      : "No token yet — the GitHub pill needs one.";
    field.placeholder = present ? "••••••••••••  (stored)" : "github_pat_…";
    clearBtn.style.display = present ? "" : "none";
  }

  async function refresh() {
    show((await Bridge.secretPresent(GITHUB_KEY)) ?? false);
  }

  /** Saves whatever is in the field. True when there was nothing to save, too. */
  async function store(): Promise<boolean> {
    const value = field.value.trim();
    if (!value) return true;
    try {
      await Bridge.secretSet(GITHUB_KEY, value);
      field.value = "";
      await refresh();
      // Fill the pill now rather than at the next poll.
      void Bridge.refreshIntegration(GITHUB_ID);
      return true;
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not save: ${String(err)}` }));
      return false;
    }
  }

  saveBtn.addEventListener("click", async () => {
    if (!field.value.trim()) return;
    clear(feedback);
    if (await store()) {
      feedback.append(h("div", { class: "notice ok", text: "Saved. It never touches disk — test it below." }));
    }
  });

  clearBtn.addEventListener("click", async () => {
    clear(feedback);
    try {
      await Bridge.secretClear(GITHUB_KEY);
      feedback.append(h("div", { class: "notice ok", text: "Token removed." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
    }
  });

  // A token pasted but not saved yet is saved first: the test only ever runs on
  // the stored token, so the value never has to travel anywhere else.
  testBtn.addEventListener("click", async () => {
    clear(feedback);
    if (!(await store())) return;
    testBtn.disabled = true;
    testBtn.textContent = "Testing…";
    try {
      feedback.append(githubResult(await Bridge.githubTest()));
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    } finally {
      testBtn.disabled = false;
      testBtn.textContent = "Test connection";
    }
  });

  const newToken = h("button", {
    class: "link",
    text: "fine-grained token",
    onclick: () => void Bridge.openUrl(GITHUB_NEW_TOKEN_URL),
  });

  show(hasToken);

  const status = h("div", { class: "row", style: "gap:8px;padding-top:5px" }, dot, state);
  const panel = h(
    "div",
    { class: "setup" },
    h("div", { class: "row" }, h("label", { text: "Token" }), field, saveBtn, clearBtn),
    h(
      "div",
      { class: "hint" },
      "Create a ", newToken, " with ",
      h("b", { text: "Repository access: All repositories" }), ", then under ",
      h("b", { text: "Repository permissions" }), " set ",
      h("b", { text: "Actions" }), ", ", h("b", { text: "Contents" }), ", ",
      h("b", { text: "Deployments" }), ", ", h("b", { text: "Issues" }), " and ",
      h("b", { text: "Pull requests" }),
      " to Read-only (Metadata is added on its own). Under ",
      h("b", { text: "Account permissions" }), ", ", h("b", { text: "Events" }),
      " Read-only is optional and adds your private activity. Nothing else — Coucou only reads.",
    ),
    h("div", { class: "row" }, testBtn),
    feedback,
  );
  return { status, panel };
}

function githubResult(account: GithubAccount): HTMLElement {
  const missing = account.checks.some((c) => !c.ok);
  const who = account.name ? `@${account.login} (${account.name})` : `@${account.login}`;
  const list = h("ul", { class: "checks" });
  for (const c of account.checks) {
    list.append(
      h("li", {}, statusDot(c.ok), h("span", { text: c.label }), c.note ? h("span", { class: "check-note", text: c.note }) : null),
    );
  }
  return h(
    "div",
    { class: missing ? "notice warn" : "notice ok" },
    h("div", { text: `Connected as ${who}.` }),
    h("div", { text: tokenExpiry(account.expiresAt) }),
    list,
  );
}

/** "2026-12-12 10:00:00 +0100" → a date, with a nudge when it is close. */
function tokenExpiry(raw: string | null): string {
  if (!raw) return "This token has no expiry date.";
  const date = new Date(raw.slice(0, 10));
  if (Number.isNaN(date.getTime())) return `Token expires ${raw}.`;
  const when = date.toLocaleDateString(undefined, { day: "numeric", month: "long", year: "numeric" });
  const days = Math.ceil((date.getTime() - Date.now()) / DAY_MS);
  if (days < 0) return `This token expired on ${when}.`;
  if (days <= EXPIRES_SOON_DAYS) return `Token expires on ${when} — in ${days} day${days === 1 ? "" : "s"}. Make a new one soon.`;
  return `Token expires on ${when}.`;
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
  /** For an integration that needs more than its fields. */
  setup?: (present: Record<string, boolean>) => IntegrationSetup;
  /** For one that needs nothing: what it reads, in a line. */
  note?: string;
  /** A choice of its own, kept with the settings: a switch and what it does. */
  option?: { setting: "announceSongs"; label: string };
}

interface IntegrationSetup {
  /** Where it stands, on the integration's own line. */
  status: HTMLElement;
  /** Opens under the line while the integration is on. */
  panel: HTMLElement;
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: "Secret key", placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [], setup: githubSetup },
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
  { id: "integration_spotify", name: "Spotify", color: "#1DB954", fields: [],
    note: "No key: asks Windows what the Spotify desktop app is playing. Nothing is asked of Spotify.",
    option: { setting: "announceSongs", label: "Show each new song: the island unfolds for a moment when the song changes" } },
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
    const setup = def.setup?.(present);
    const drawer = setup ? h("div", { class: "drawer" }, h("div", {}, setup.panel)) : null;
    const open = (on: boolean) => {
      drawer?.classList.toggle("open", on);
      // Folded away, its fields are out of reach of the keyboard too.
      if (setup) setup.panel.inert = !on;
    };
    open(active);
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        if (settings.activeIntegrations.length >= MAX_ACTIVE) return;
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      open(!on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    if (setup) rows.append(setup.status);
    if (def.note) rows.append(h("span", { class: "hint", style: "padding-top:5px", text: def.note }));
    if (def.option) {
      const { setting, label } = def.option;
      rows.append(
        h("div", { class: "row" },
          toggle(settings[setting], (on) => {
            settings[setting] = on;
            void save();
          }),
          h("span", { style: "font-size:12.5px", text: label }),
        ),
      );
    }
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
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        try {
          await Bridge.secretSet(field.key, value);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? "••••••••  (stored)" : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: field.label }),
          input, saveBtn, dotEl,
        ),
      );
    }

    const line = h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
      h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
        sw,
        h("i", { class: "dot", style: `background:${def.color}` }),
        h("span", { style: "font-size:12.5px", text: def.name }),
      ),
      rows,
    );
    list.append(drawer ? h("div", {}, line, drawer) : line);
  }

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: "Integrations" })), note, list);
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
    integrationsSection(present),
    generalSection(),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
  });
}

void main();
