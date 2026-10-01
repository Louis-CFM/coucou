// Settings window — the place where anything that writes to disk is confirmed.
// Claude Code hooks, Cursor agent hooks, preferences, API keys and integrations.

import "./settings.css";
import { Bridge, onEvent, type HookPreview, type HookStatus } from "../core/bridge";
import { DEFAULT_SETTINGS, INTEGRATION_AGENTS, type Settings } from "../core/state";
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

// ── Hook installers (Claude Code and Cursor) ─────────────────────────────────

interface HookSectionCopy {
  title: string;
  fileLabel: string;
  installed: string;
  missing: string;
  previewInstall: string;
  previewRemove: string;
  done: (backup: string) => string;
  /** Shown when the installed timeout is too short for a click to land. */
  outdated?: string;
  load: () => Promise<HookStatus | null>;
  preview: (install: boolean) => Promise<HookPreview>;
  apply: (install: boolean, fingerprint: string) => Promise<string>;
}

function hooksSection(copy: HookSectionCopy, status: HookStatus): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, statusDot(status.installed), h("span", { text: copy.title })),
    body,
  );

  const rebuild = async () => {
    const fresh = await copy.load();
    if (fresh) Object.assign(status, fresh);
    clear(body);
    draw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: copy.title }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: status.installed ? copy.installed : copy.missing,
      }),
      h("div", { class: "row" },
        h("label", { text: copy.fileLabel }),
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
    if (status.hooksOutdated && copy.outdated) {
      body.append(h("div", { class: "notice warn", text: copy.outdated }));
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
      preview = await copy.preview(install);
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
        text: install ? copy.previewInstall : copy.previewRemove,
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
        const backup = await copy.apply(install, preview.fingerprint);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: copy.done(backup),
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

const CLAUDE_HOOKS: HookSectionCopy = {
  title: "Claude Code",
  fileLabel: "settings.json",
  installed: "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.",
  missing: "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.",
  previewInstall: "This is exactly what will change in your settings.json. Your own hooks are left untouched.",
  previewRemove: "This removes Coucou's entries only. Your own hooks are left untouched.",
  done: (backup) => `Done. Previous settings saved as ${backup}. Open a new Claude Code session to pick the hooks up.`,
  load: () => Bridge.hooksStatus(),
  preview: (install) => Bridge.hooksPreview(install),
  apply: (install, fingerprint) => Bridge.hooksApply(install, fingerprint),
};

const CURSOR_HOOKS: HookSectionCopy = {
  title: "Cursor",
  fileLabel: "hooks.json",
  installed: "Coucou watches your local Cursor agent sessions. Deny / Allow appears only when Cursor itself would ask: a command that needs full access, a file delete, or a change outside the project. Cloud agents are not included.",
  missing: "Install the hooks to see your local Cursor agent sessions, and to answer the permissions Cursor would ask for. Edits inside the project are not interrupted. Cloud agents are not included.",
  previewInstall: "This is exactly what will change in your hooks.json. Your own hooks are left untouched.",
  previewRemove: "This removes Coucou's entries only. Your own hooks are left untouched.",
  done: (backup) => `Done. Previous hooks saved as ${backup}. Start a new Cursor agent chat to pick the hooks up.`,
  outdated: "Reinstall the hooks. The copy installed now can let Cursor run the tool when the wait runs out, before you have clicked.",
  load: () => Bridge.cursorHooksStatus(),
  preview: (install) => Bridge.cursorHooksPreview(install),
  apply: (install, fingerprint) => Bridge.cursorHooksApply(install, fingerprint),
};

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

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Shown instead of a key field. Spotify has nothing to store. */
  note?: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_spotify", name: "Spotify", color: "#1DB954",
    note: "Uses the Spotify app already open. No key.",
    fields: [] },
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

/** Rebuilt when an integration is toggled, so a disabled pill leaves the list. */
let refreshDefaultPill: () => void = () => {};

function defaultPillChoices(): { id: string; name: string }[] {
  return INTEGRATION_AGENTS.filter(
    (t) =>
      t.id === "integration_claude" ||
      t.id === "integration_cursor" ||
      settings.activeIntegrations.includes(t.id),
  ).map((t) => ({ id: t.id, name: t.name }));
}

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
      refreshDefaultPill();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    if (def.note) rows.append(h("div", { class: "hint", text: def.note }));
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

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
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

  if (settings.hideMode !== "manual") settings.hideMode = "timer";
  if (settings.shrinkMode !== "outside") settings.shrinkMode = "timer";

  const hideMode = h("select", {}) as HTMLSelectElement;
  hideMode.append(
    h("option", { value: "timer", text: "After a pause" }),
    h("option", { value: "manual", text: "Close button" }),
  );
  hideMode.value = settings.hideMode;
  const hideHint = h("span", { class: "hint" });

  const shrinkMode = h("select", {}) as HTMLSelectElement;
  shrinkMode.append(
    h("option", { value: "timer", text: "After you leave it" }),
    h("option", { value: "outside", text: "Click outside" }),
  );
  shrinkMode.value = settings.shrinkMode;
  const shrinkHint = h("span", { class: "hint" });

  function syncBehavior() {
    const manual = hideMode.value === "manual";
    hideHint.textContent = manual
      ? "Stays until you click ×. Hover the top of the screen to bring it back."
      : "Hides on its own. Hover the top of the screen to bring it back.";
    const outside = shrinkMode.value === "outside";
    autoClose.hidden = outside;
    shrinkHint.textContent = outside
      ? "Stays open until you click somewhere else."
      : "seconds after you leave the island";
  }
  hideMode.addEventListener("change", () => {
    settings.hideMode = hideMode.value === "manual" ? "manual" : "timer";
    syncBehavior();
    void save();
  });
  shrinkMode.addEventListener("change", () => {
    settings.shrinkMode = shrinkMode.value === "outside" ? "outside" : "timer";
    syncBehavior();
    void save();
  });
  syncBehavior();

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

  const pill = h("select", {}) as HTMLSelectElement;
  function fillDefaultPill() {
    const choices = defaultPillChoices();
    if (!choices.some((c) => c.id === settings.defaultPill)) {
      settings.defaultPill = "integration_claude";
    }
    clear(pill);
    for (const choice of choices) {
      pill.append(h("option", { value: choice.id, text: choice.name }));
    }
    pill.value = settings.defaultPill;
  }
  refreshDefaultPill = fillDefaultPill;
  fillDefaultPill();
  pill.addEventListener("change", () => {
    settings.defaultPill = pill.value;
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
      h("label", { text: "Hide completely" }),
      hideMode,
      hideHint,
    ),
    h("div", { class: "row" },
      h("label", { text: "Shrink" }),
      shrinkMode,
      autoClose,
      shrinkHint,
    ),
    h("div", { class: "row" },
      h("label", { text: "Default pill" }),
      pill,
      h("span", { class: "hint", text: "Shown when Coucou starts" }),
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
  const emptyHooks = { installed: false, settingsPath: "", hookPath: "", hookReady: false, hooksOutdated: false };
  const status = (await Bridge.hooksStatus()) ?? { ...emptyHooks };
  const cursorStatus = (await Bridge.cursorHooksStatus()) ?? { ...emptyHooks };

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
    hooksSection(CLAUDE_HOOKS, status),
    hooksSection(CURSOR_HOOKS, cursorStatus),
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
