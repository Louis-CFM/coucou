// Settings window — the place where anything that writes to disk is confirmed.

import "./settings.css";
import {
  Bridge, onEvent,
  type HookStatus, type AgentHookStatus, type AgentId, type DetectedAgent, type SetupOutcome, type SetupReport,
} from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { h, clear } from "../views/dom";
import { renderRouterSection } from "./router";
import { hotkeysSection, voiceSection } from "./hotkeys";
import { SettingsSaveQueue } from "./save-queue";

let settings: Settings = structuredClone(DEFAULT_SETTINGS);
let settingsRevision = 0;
let version = "";

const root = document.getElementById("settings-root")!;
const saveStatus = h("div", { class: "notice-region", role: "status", "aria-live": "polite" });
const saveQueue = new SettingsSaveQueue(async (entry: { revision: number; settings: Settings }) => {
  if (entry.revision > settingsRevision) settingsRevision = entry.revision;
  await Bridge.saveSettingsStrict(entry.settings);
});

async function save() {
  saveQueue.schedule({ revision: ++settingsRevision, settings: structuredClone(settings) });
  try { await saveQueue.idle(); saveStatus.textContent = ""; saveStatus.className = "notice-region"; }
  catch (error) { saveStatus.textContent = `Settings were not saved: ${String(error).replace(/^Error:\s*/, "")}`; saveStatus.className = "notice err"; throw error; }
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

const AGENT_LABELS: Record<AgentId, string> = {
  "kimi-code": "Kimi Code CLI",
  codex: "Codex CLI",
  hermes: "Hermes Agent",
};

function agentSection(agent: AgentId, initial: AgentHookStatus | null): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h("section", {}, h("h2", {}, h("span", { text: AGENT_LABELS[agent] })), body);
  let status = initial;

  function draw() {
    clear(body);
    if (!status) {
      body.append(h("div", { class: "notice err", text: "Could not read this CLI configuration status." }));
      return;
    }
    const detected = status.version
      || (status.versionReason ? `Unknown (${status.versionReason})` : "Unknown");
    body.append(
      h("div", { class: "hint", text: !status.available
        ? "Not found on this PC (no CLI on PATH, desktop app or config folder). Hook installation is unavailable."
        : !status.cliFound
          ? "CLI not on PATH, but the desktop app or config folder is here. You can review and install; the hook version can't be checked."
          : status.compatible
            ? "Installed CLI matches the tested hook version. Hook installation is optional."
            : "This CLI version is not the tested one. You can still review and install; existing hooks can always be removed." }),
      h("div", { class: "row" }, h("label", { text: "Detected version" }),
        h("span", { text: status.cliFound ? detected : "CLI not found" })),
      h("div", { class: "row" }, h("label", { text: "Tested version" }),
        h("span", { text: status.testedVersion })),
    );
    if (status.available && status.versionWarning) {
      body.append(h("div", { class: `notice ${status.versionState === "unknown" ? "err" : "warn"}`,
        text: status.versionWarning }));
    }
    body.append(
      h("div", { class: "row" }, h("label", { text: "Configuration" }),
        h("span", { text: status.configured ? "Configured" : "Not configured" })),
      h("div", { class: "row" }, h("label", { text: "Live event" }),
        h("span", { text: status.liveEventSeen ? "Seen during this Coucou run" : "Not yet seen" })),
      h("div", { class: "row" }, h("label", { text: "Config file" }),
        h("span", { class: "path", text: status.settingsPath })),
      h("div", { class: "row" }, h("label", { text: "Relay" }),
        h("span", { class: "path", text: status.hookPath }), statusDot(status.hookReady)),
    );
    if (agent === "codex" || agent === "hermes") {
      body.append(h("div", { class: "notice warn", text: agent === "codex"
        ? "Hook trust not verified. After installing, restart Codex (CLI and the ChatGPT desktop app) and trust each exact Coucou hook in /hooks or the desktop hook review; changed hooks need trust again. Coucou never enables trust for you."
        : "Hook consent not verified. Restart Hermes and approve each exact event and command at its own prompt; Coucou never auto-accepts hooks." }));
    }
    if (status.detail) body.append(h("div", { class: "notice err", text: status.detail }));
    const installButton = h("button", { class: "primary", text: status.configured ? "Review reinstall…" : "Review install…",
      onclick: () => void showPreview(true) });
    installButton.disabled = !status.available || !status.hookReady || !!status.detail;
    const actions = h("div", { class: "row" }, installButton);
    if (status.configured) actions.append(h("button", { class: "danger", text: "Review uninstall…",
      onclick: () => void showPreview(false) }));
    body.append(actions);
  }

  async function refresh() {
    try { status = await Bridge.agentHooksStatus(agent); }
    catch (err) { clear(body); body.append(h("div", { class: "notice err", text: String(err) })); return; }
    draw();
  }

  async function showPreview(install: boolean) {
    try {
      const preview = await Bridge.agentHooksPreview(agent, install);
      clear(body);
      body.append(
        h("div", { class: "hint", text: install
          ? "Review Coucou's proposed hook block. Unchanged config values are hidden; existing hooks stay in place."
          : "Review Coucou's block removal. Unchanged config values are hidden." }),
      );
      if (install && preview.versionWarning) {
        body.append(h("div", { class: "notice warn", text:
          `${preview.versionWarning} Clicking "Back up and install" confirms you accept this.` }));
      }
      body.append(
        renderDiff(preview.diff),
        h("div", { class: "row" }, h("span", { class: "path", text: preview.backup
          ? `Backup name: ${preview.backup} (actual unique path reported after write)`
          : "No existing file to back up." })),
      );
      const confirm = h("button", { class: install ? "primary" : "danger",
        text: install ? "Back up and install" : "Back up and uninstall" });
      confirm.addEventListener("click", async () => {
        confirm.disabled = true;
        try {
          const backup = await Bridge.agentHooksApply(agent, install, preview.fingerprint);
          clear(body);
          body.append(h("div", { class: "notice ok", text: backup
            ? `Done. Previous config backed up at ${backup}. Restart the CLI to load hooks.`
            : "Done. No prior config needed a backup. Restart the CLI to load hooks." }));
          window.setTimeout(() => void refresh(), 2600);
        } catch (err) {
          confirm.disabled = false;
          body.append(h("div", { class: "notice err", text: `Could not apply: ${String(err)}` }));
        }
      });
      body.append(h("div", { class: "row" }, confirm, h("button", { text: "Cancel",
        onclick: () => draw() })));
    } catch (err) {
      clear(body);
      body.append(h("div", { class: "notice err", text: String(err) }),
        h("button", { text: "Back", onclick: () => draw() }));
    }
  }

  draw();
  return section;
}

// ── One-step setup ────────────────────────────────────────────────────────────

const OUTCOME_TEXT: Record<SetupOutcome, string> = {
  installed: "Installed",
  "already-set-up": "Already set up",
  "would-install": "Would install",
  removed: "Removed",
  "would-remove": "Would remove",
  "not-installed": "Nothing to remove",
  skipped: "Skipped: not found",
  error: "Error",
};

const OUTCOME_OK = new Set<SetupOutcome>(["installed", "already-set-up", "removed"]);

function detectedSummary(found: DetectedAgent[]): string {
  const here = found.filter((d) => d.found);
  if (!here.length) return "No agents found on this PC (Claude Code, Codex, Kimi Code, Hermes).";
  const parts = here.map((d) => `${d.label}${d.configured ? " ✓" : ""}`);
  const todo = here.filter((d) => !d.configured).length;
  return `Found: ${parts.join(", ")}. ${todo ? `${todo} not set up yet.` : "All set up."}`;
}

function setupSection(initial: DetectedAgent[] | null, onDone: () => void): HTMLElement {
  const summary = h("div", { class: "hint" });
  const results = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
  const button = h("button", { class: "primary setup-all", text: "Set up all my agents" }) as HTMLButtonElement;
  const section = h("section", { id: "setup-all", class: "setup" },
    h("h2", {}, h("span", { text: "Connect your agents" })),
    summary,
    h("div", { class: "hint", text: "One click: Coucou backs up each config, adds its hooks, and skips agents you don't have. Your own hooks and settings stay as they are." }),
    h("div", { class: "row" }, button),
    results,
  );

  const showSummary = (found: DetectedAgent[] | null) => {
    summary.textContent = found ? detectedSummary(found) : "Could not look for agents.";
    button.disabled = !found?.some((d) => d.found);
  };
  showSummary(initial);
  refreshSetup = async () => {
    try { showSummary(await Bridge.agentsDetect()); } catch { showSummary(null); }
  };

  button.addEventListener("click", async () => {
    button.disabled = true;
    button.textContent = "Setting up…";
    clear(results);
    try {
      const report = await Bridge.agentsSetupAll();
      renderReport(results, report);
    } catch (err) {
      results.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
    }
    button.textContent = "Set up all my agents";
    try { showSummary(await Bridge.agentsDetect()); } catch { button.disabled = false; }
    onDone();
  });

  return section;
}

function renderReport(box: HTMLElement, report: SetupReport) {
  if (!report.relayReady) {
    box.append(h("div", { class: "notice err", text: `Relay not ready: ${report.relayMessage}` }));
  }
  for (const a of report.agents) {
    const kind = a.outcome === "error" ? "err" : OUTCOME_OK.has(a.outcome) ? "ok" : "";
    const lines = [`${a.label}: ${OUTCOME_TEXT[a.outcome]}`];
    if (a.message) lines.push(a.message);
    if (a.warning) lines.push(`Warning: ${a.warning}`);
    if (a.backup) lines.push(`Backup: ${a.backup}`);
    box.append(h("div", { class: kind ? `notice ${kind}` : "hint", text: lines.join("\n"), style: "white-space:pre-wrap" }));
  }
  const next = report.agents.filter((a) => a.followUp);
  if (next.length) {
    const list = h("ol", { class: "follow-ups" });
    for (const a of next) list.append(h("li", {}, h("b", { text: `${a.label}: ` }), h("span", { text: a.followUp })));
    box.append(h("div", { class: "notice warn" }, h("div", { text: "Still to do, by you:" }), list));
  }
}

function highlightSetup() {
  const el = document.getElementById("setup-all");
  if (!el) return;
  el.classList.remove("highlight");
  void el.offsetWidth;
  el.classList.add("highlight");
  el.scrollIntoView({ behavior: "smooth", block: "start" });
  el.querySelector<HTMLButtonElement>("button.setup-all")?.focus();
  void Bridge.agentsSetupDismiss();
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

  const modelRow = h("div", { class: "row" }, h("label", { text: "Model" }), model);
  const syncModelRow = () => {
    modelRow.style.display = settings.chatProvider === "router" ? "none" : "";
    if (settings.chatProvider !== "router" && model.value !== settings.model) {
      if (![...model.options].some((o) => o.value === settings.model)) {
        model.append(h("option", { value: settings.model, text: settings.model }));
      }
      model.value = settings.model;
    }
  };
  syncModelRow();
  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    syncModelRow();
  });

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Claude" })),
    state,
    h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn),
    modelRow,
    feedback,
  );
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

  const lockToggle = toggle(settings.islandLocked, (v) => {
    settings.islandLocked = v;
    void Bridge.islandSetLocked(v);
  });
  const resetBtn = h("button", {
    text: "Reset position",
    title: "Back to the top centre of the display above",
    onclick: () => void Bridge.islandResetPosition(),
  }) as HTMLButtonElement;
  const syncPlacement = () => {
    lockToggle.classList.toggle("on", settings.islandLocked);
    lockToggle.setAttribute("aria-pressed", String(settings.islandLocked));
    resetBtn.disabled = !settings.islandPosition;
  };
  syncPlacement();
  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    syncPlacement();
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
      h("label", { text: "Lock position" }),
      lockToggle,
      resetBtn,
    ),
    h("div", { class: "hint", text: "Unlocked: hold the mouse on an empty part of the island and drag it anywhere, on any display. The spot is saved when you let go." }),
    h("div", { class: "row" },
      h("label", { text: "Launch at startup" }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
  );
}

// ── Robot ─────────────────────────────────────────────────────────────────────

/** One entry per line, blanks dropped. */
function lines(text: string): string[] {
  return text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
}

function robotSection(): HTMLElement {
  const area = (value: string, rows: number) => {
    const el = h("textarea", { rows: String(rows), spellcheck: "false", class: "robot-list" }) as HTMLTextAreaElement;
    el.value = value;
    return el;
  };
  const agents = area(settings.robotAgents.join("\n"), 2);
  const preapproved = area(settings.robotPreapproved.join("\n"), 3);
  const browser = h("input", { type: "text", spellcheck: "false", style: "flex:1;min-width:0" }) as HTMLInputElement;
  browser.value = settings.robotBrowserStart;

  agents.addEventListener("change", () => {
    settings.robotAgents = lines(agents.value);
    void save();
  });
  preapproved.addEventListener("change", () => {
    settings.robotPreapproved = lines(preapproved.value);
    void save();
  });
  browser.addEventListener("change", () => {
    settings.robotBrowserStart = browser.value.trim();
    void save();
  });
  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    if (document.activeElement !== agents) agents.value = settings.robotAgents.join("\n");
    if (document.activeElement !== preapproved) preapproved.value = settings.robotPreapproved.join("\n");
    if (document.activeElement !== browser) browser.value = settings.robotBrowserStart;
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "Robot" })),
    h("div", { class: "hint", text: "A background agent does web tasks in the hidden browser (127.0.0.1:9222). Your mouse and windows are never touched." }),
    h("label", { text: "Agents, in fallback order (one per line: hermes:<profile>, hermes, codex)" }),
    agents,
    h("label", { text: "Pre-approved actions (one per line). Anything else that sends, posts, pays or deletes asks you first." }),
    preapproved,
    h("div", { class: "row" }, h("label", { text: "Browser start" }), browser),
    h("div", { class: "hint", text: "Run hidden when the browser is not answering. Downloads go to Downloads\\Coucou-Robot." }),
  );
}

// ── Hindsight memory ─────────────────────────────────────────────────────────

function hindsightSection(tokenInitiallyPresent: boolean): HTMLElement {
  let tokenPresent = tokenInitiallyPresent;
  const feedback = h("div", { class: "notice-region", role: "status", "aria-live": "polite" });
  const enabled = toggle(settings.hindsight.enabled, (value) => { settings.hindsight.enabled = value; void save(); });
  enabled.setAttribute("aria-label", "Enable Hindsight memory");
  const automatic = toggle(settings.hindsight.automaticRecall, (value) => { settings.hindsight.automaticRecall = value; void save(); });
  automatic.setAttribute("aria-label", "Automatic recall");
  const inferred = toggle(settings.hindsight.inferredRetention, (value) => { settings.hindsight.inferredRetention = value; void save(); });
  inferred.setAttribute("aria-label", "Inferred retention");
  const baseUrl = h("input", { id: "hindsight-base-url", type: "url", autocomplete: "url", spellcheck: "false" }) as HTMLInputElement;
  const tenant = h("input", { id: "hindsight-tenant", type: "text", autocomplete: "off", spellcheck: "false" }) as HTMLInputElement;
  const bank = h("input", { id: "hindsight-bank", type: "text", autocomplete: "off", spellcheck: "false" }) as HTMLInputElement;
  baseUrl.value = settings.hindsight.baseUrl;
  tenant.value = settings.hindsight.tenant;
  bank.value = settings.hindsight.bank;
  const token = h("input", { id: "hindsight-token", type: "password", autocomplete: "new-password", spellcheck: "false", placeholder: "Paste bearer token" }) as HTMLInputElement;
  const tokenState = h("span", { class: "hint" });
  const tokenSave = h("button", { class: "primary" }) as HTMLButtonElement;
  const tokenRemove = h("button", { class: "danger", text: "Remove" }) as HTMLButtonElement;

  function show(message: string, error = false) {
    feedback.className = `notice ${error ? "err" : "ok"}`;
    feedback.textContent = message;
  }
  function syncToken() {
    token.value = "";
    tokenState.textContent = tokenPresent ? "Token stored in Windows Credential Manager." : "No token stored.";
    tokenSave.textContent = tokenPresent ? "Replace token" : "Save token";
    tokenRemove.hidden = !tokenPresent;
  }
  syncToken();

  for (const control of [baseUrl, tenant, bank]) control.addEventListener("change", () => {
    settings.hindsight.baseUrl = baseUrl.value.trim();
    settings.hindsight.tenant = tenant.value.trim();
    settings.hindsight.bank = bank.value.trim();
    void save();
  });
  tokenSave.addEventListener("click", async () => {
    const value = token.value.trim();
    if (!value) { show("Enter a bearer token before saving.", true); token.focus(); return; }
    try { await Bridge.hindsightBearerTokenSet(value); tokenPresent = true; syncToken(); show("Token stored securely."); }
    catch (error) { token.value = ""; show(String(error).replace(/^Error:\s*/, ""), true); }
  });
  tokenRemove.addEventListener("click", async () => {
    try { await Bridge.hindsightBearerTokenDelete(); tokenPresent = false; syncToken(); show("Token removed."); }
    catch (error) { show(String(error).replace(/^Error:\s*/, ""), true); }
  });
  const test = h("button", { text: "Test connection" }) as HTMLButtonElement;
  test.addEventListener("click", async () => {
    test.disabled = true; feedback.textContent = "Testing connection…"; feedback.className = "hint";
    try { await save(); await Bridge.hindsightTestConnection(); show("Connected to Hindsight."); }
    catch (error) { show(String(error).replace(/^Error:\s*/, ""), true); }
    finally { test.disabled = false; }
  });

  return h("section", { "aria-labelledby": "hindsight-heading" },
    h("h2", { id: "hindsight-heading", text: "Hindsight memory" }),
    h("div", { class: "hint", text: "Coucou sends memory network requests from Rust. The bearer token is never read back into this page." }),
    h("div", { class: "row" }, h("label", { text: "Enabled" }), enabled),
    h("div", { class: "row" }, h("label", { for: "hindsight-base-url", text: "Base URL" }), baseUrl),
    h("div", { class: "row" }, h("label", { for: "hindsight-tenant", text: "Tenant" }), tenant),
    h("div", { class: "row" }, h("label", { for: "hindsight-bank", text: "Bank" }), bank),
    h("div", { class: "row" }, h("label", { text: "Automatic recall" }), automatic),
    h("div", { class: "row" }, h("label", { text: "Inferred retention" }), inferred),
    h("div", { class: "row" }, h("label", { for: "hindsight-token", text: "Bearer token" }), token, tokenSave, tokenRemove),
    tokenState,
    h("div", { class: "row" }, test, h("button", { text: "Open Memory Manager", onclick: () => void Bridge.openMemoryWindow() })),
    feedback,
  );
}

// ── Boot ──────────────────────────────────────────────────────────────────────

/** Re-reads which agents are here; set once the setup section exists. */
let refreshSetup: () => Promise<void> = async () => {};

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
  }
  let detected: DetectedAgent[] | null = null;
  try { detected = await Bridge.agentsDetect(); } catch { detected = null; }
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };
  const agents: AgentId[] = ["kimi-code", "codex", "hermes"];
  const agentStatuses = await Promise.all(agents.map(async (agent) => {
    try { return await Bridge.agentHooksStatus(agent); }
    catch { return null; }
  }));

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
  const hindsightTokenPresent = (await Bridge.hindsightBearerTokenPresent()) ?? false;

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  const agentsBox = h("div", { style: "display:contents" });
  const drawAgents = async () => {
    const fresh = (await Bridge.hooksStatus()) ?? status;
    const statuses = await Promise.all(agents.map(async (agent) => {
      try { return await Bridge.agentHooksStatus(agent); }
      catch { return null; }
    }));
    clear(agentsBox);
    agentsBox.append(claudeSection(fresh), ...agents.map((agent, index) => agentSection(agent, statuses[index])));
  };
  agentsBox.append(claudeSection(status), ...agents.map((agent, index) => agentSection(agent, agentStatuses[index])));

  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    saveStatus,
    setupSection(detected, () => void drawAgents()),
    agentsBox,
    apiSection(hasKey),
    hindsightSection(hindsightTokenPresent),
    integrationsSection(present),
    generalSection(),
    hotkeysSection(() => settings, async (next) => { settings = next; await save(); }),
    voiceSection(() => settings, async (next) => { settings = next; await save(); }),
    robotSection(),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );
  renderRouterSection(root);

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    saveQueue.replaceCurrent({ revision: ++settingsRevision, settings: structuredClone(settings) });
  });
  // The island's "Set them up" opens this window with the button marked.
  void onEvent<null>("setup-highlight", () => {
    void refreshSetup().then(highlightSetup);
  });
}

void main();
