// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type HookPreview, type HookStatus, type WslStatus } from "../core/bridge";
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

// ── Mochi's engine ────────────────────────────────────────────────────────────
// Mochi's chat can run on the user's own Claude Code (Windows or a WSL distro)
// instead of the API key. One "Use for Mochi" switch per Claude Code; at most
// one is on, and with none on the API key is used.

const engineListeners: (() => void)[] = [];
const engineSwitches: { backend: string; el: HTMLElement }[] = [];

function engineLabel(backend: string): string {
  if (backend === "windows") return "Claude Code on Windows";
  if (backend.startsWith("wsl:")) return `Claude Code in WSL · ${backend.slice(4)}`;
  return "the Claude API";
}

function syncEngine() {
  for (let i = engineSwitches.length - 1; i >= 0; i--) {
    const s = engineSwitches[i];
    if (!s.el.isConnected) engineSwitches.splice(i, 1); // a redrawn block
    else s.el.classList.toggle("on", settings.chatBackend === s.backend);
  }
  for (const fn of engineListeners) fn();
}

/** Why a found Claude Code can't answer yet, and the one command that fixes it. */
function signInNotice(backend: string, cli: string): HTMLElement {
  const wsl = backend.startsWith("wsl:");
  const app = !wsl && /\\Claude\\claude-code\\/i.test(cli);
  const why = wsl
    ? `This Claude Code isn't signed in. Sign it in once in ${backend.slice(4)}, then reopen the settings:`
    : app
      ? "This is the Claude app's own copy of Claude Code. The app signs it in only when the app itself runs it, so for Mochi it needs signing in once on its own. In a terminal, run this, then reopen the settings:"
      : "This Claude Code isn't signed in. Sign it in once in a terminal, then reopen the settings:";
  const command = wsl ? "claude auth login" : `& "${cli}" auth login`;
  return h("div", { class: "notice warn" },
    h("div", { text: why }),
    h("code", { class: "cmd", text: command }),
  );
}

function mochiRow(backend: string, cli: string | null, missing: string): HTMLElement {
  const sw = h("button", { class: settings.chatBackend === backend ? "switch on" : "switch" });
  engineSwitches.push({ backend, el: sw });
  if (!cli) {
    sw.disabled = true;
    sw.title = missing;
  }
  sw.addEventListener("click", () => {
    settings.chatBackend = settings.chatBackend === backend ? "api" : backend;
    void save();
    syncEngine();
  });
  const row = h("div", { class: "row" },
    h("label", { text: "Use for Mochi" }),
    sw,
    h("span", {
      class: "hint",
      text: cli
        ? "Mochi's chat answers through this Claude Code — your subscription, no API key."
        : missing,
    }),
  );
  const box = h("div", { style: "display:flex;flex-direction:column;gap:8px" }, row);
  // Installed is not enough: a Claude Code nobody signed in to can't answer.
  if (cli) {
    void Bridge.claudeLoggedIn(backend).then((loggedIn) => {
      if (loggedIn !== false) return;
      box.append(signInNotice(backend, cli));
      // Leave a switch that is already on alone, so it can still be turned off.
      if (settings.chatBackend !== backend) {
        sw.disabled = true;
        sw.title = "Sign this Claude Code in first";
      }
    });
  }
  return box;
}

// ── Diff → confirm → write ────────────────────────────────────────────────────
// The one path by which hooks are ever written, for Windows and WSL alike: show
// the exact diff and the backup, write only on the click, and refuse a file
// that changed in between (the fingerprint).

interface FlowOps {
  preview: () => Promise<HookPreview>;
  apply: (fingerprint: string) => Promise<string>;
  back: () => void;
  done: () => void;
  /** Named in the hint: "This is exactly what will change in your …". */
  what: string;
  /** Extra line shown above the diff, e.g. the relay script that comes with it. */
  extra?: string;
}

async function previewFlow(body: HTMLElement, install: boolean, ops: FlowOps) {
  let preview: HookPreview;
  try {
    preview = await ops.preview();
  } catch (err) {
    // An unreadable or invalid settings.json stops here rather than being
    // treated as empty and written over.
    clear(body);
    body.append(
      h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
      h("div", { class: "row" }, h("button", { text: "Back", onclick: ops.back })),
    );
    return;
  }
  clear(body);
  body.append(
    h("div", {
      class: "hint",
      text: install
        ? `This is exactly what will change in your ${ops.what}. Your own hooks are left untouched.`
        : "This removes Coucou's entries only. Your own hooks are left untouched.",
    }),
  );
  if (ops.extra) body.append(h("div", { class: "hint", text: ops.extra }));
  body.append(
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
      const backup = await ops.apply(preview.fingerprint);
      clear(body);
      body.append(h("div", {
        class: "notice ok",
        text: `Done. Previous settings saved as ${backup}. Open a new Claude Code session to pick the hooks up.`,
      }));
      window.setTimeout(ops.done, 2600);
    } catch (err) {
      confirm.disabled = false;
      body.append(h("div", { class: "notice err", text: `Could not write: ${String(err)}` }));
    }
  });
  body.append(h("div", { class: "row" }, confirm, h("button", { text: "Cancel", onclick: ops.back })));
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
      mochiRow("windows", status.claudeCli, "Claude Code isn't installed on Windows."),
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

  function showPreview(install: boolean) {
    void previewFlow(body, install, {
      preview: () => Bridge.hooksPreview(install),
      apply: (fingerprint) => Bridge.hooksApply(install, fingerprint),
      back: () => { clear(body); draw(); },
      done: () => void rebuild(),
      what: "settings.json",
    });
  }

  // Claude Code may have been installed (or signed in) since launch.
  void onEvent<null>("settings-shown", () => void rebuild());

  draw();
  return section;
}

// ── WSL section ───────────────────────────────────────────────────────────────
// Claude Code running inside a WSL distro. Each distro gets its own relay script
// and its own ~/.claude/settings.json, through the same reviewed-diff path.
// Asking a distro for its state starts it, so this only runs while the window
// is on screen (the "settings-shown" cue), never at launch.

function wslSection(hookReady: boolean): { section: HTMLElement; refresh: () => Promise<void> } {
  const dot = statusDot(false);
  const body = h("div", { style: "display:flex;flex-direction:column;gap:14px" });
  const section = h("section", { id: "wsl" }, h("h2", {}, dot, h("span", { text: "WSL" })), body);
  body.append(h("div", { class: "hint", text: "Open the settings to look for WSL distributions." }));

  let busy = false;
  let statuses: WslStatus[] = [];

  async function refresh() {
    if (busy) return;
    busy = true;
    try {
      clear(body);
      body.append(h("div", { class: "hint", text: "Looking for WSL distributions…" }));
      const names = (await Bridge.wslDistros()) ?? [];
      statuses = [];
      for (const name of names) {
        try {
          statuses.push(await Bridge.wslStatus(name));
        } catch (err) {
          statuses.push({
            distro: name, installed: false, settingsPath: "", relayPath: "",
            relayReady: false, claudeCli: null, error: String(err),
          });
        }
      }
      draw();
    } finally {
      busy = false;
    }
  }

  function draw() {
    clear(body);
    dot.style.background = statuses.some((s) => s.installed) ? "#22c55e" : "#f4505e";
    body.append(h("div", {
      class: "hint",
      text: statuses.length
        ? "Claude Code running inside WSL reaches Coucou through a small relay script in the distribution. Install it to see those sessions in the island and approve their permissions."
        : "No WSL distribution found. Install one with `wsl --install`, then refresh.",
    }));
    for (const st of statuses) body.append(distroBlock(st));
    body.append(h("div", { class: "row" }, h("button", { text: "Refresh", onclick: () => void refresh() })));
  }

  function distroBlock(st: WslStatus): HTMLElement {
    const block = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
    block.append(h("div", { class: "row" },
      statusDot(st.installed),
      h("span", { style: "font-weight:600", text: st.distro }),
    ));
    if (st.error) {
      block.append(h("div", { class: "notice warn", text: st.error }));
      return block;
    }
    block.append(
      h("div", { class: "row" },
        h("label", { text: "settings.json" }),
        h("span", { class: "path", text: st.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: "Relay script" }),
        h("span", { class: "path", text: st.relayPath }),
        statusDot(st.relayReady),
      ),
      mochiRow(`wsl:${st.distro}`, st.claudeCli, "Claude Code isn't installed in this distribution."),
    );
    if (st.installed && !st.relayReady) {
      block.append(h("div", {
        class: "notice warn",
        text: "The hooks are there but the relay script is missing or out of date. Reinstall to fix it.",
      }));
    }

    const back = () => draw();
    const show = (install: boolean) => {
      clear(block);
      block.append(h("div", { class: "row" }, h("span", { style: "font-weight:600", text: st.distro })));
      void previewFlow(block, install, {
        preview: () => Bridge.wslHooksPreview(st.distro, install),
        apply: (fingerprint) => Bridge.wslHooksApply(st.distro, install, fingerprint),
        back,
        done: () => void refresh(),
        what: `${st.distro} settings.json`,
        extra: install
          ? `The relay script is written to ${st.relayPath} along with it.`
          : `The relay script ${st.relayPath} is removed too.`,
      });
    };

    const install = h("button", {
      class: "primary",
      text: st.installed ? "Reinstall hooks…" : "Install hooks…",
      onclick: () => show(true),
    });
    // Same rule as Windows: no hooks pointing at a relay that isn't there.
    if (!hookReady) {
      install.disabled = true;
      install.title = "coucou-hook.exe isn't installed yet — restart Coucou.";
    }
    const actions = h("div", { class: "row" }, install);
    if (st.installed) {
      actions.append(h("button", { class: "danger", text: "Uninstall hooks…", onclick: () => show(false) }));
    }
    block.append(actions);
    return block;
  }

  return { section, refresh };
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

  const engine = h("div", { class: "notice" });
  const drawEngine = () => {
    const api = settings.chatBackend === "api";
    engine.className = api ? "hint" : "notice ok";
    engine.textContent = api
      ? "Mochi answers with this key. To use your Claude subscription instead, turn on \"Use for Mochi\" on a Claude Code above."
      : `Mochi answers through ${engineLabel(settings.chatBackend)}, on your subscription — the key below isn't used. The model is Claude Code's own.`;
  };
  engineListeners.push(drawEngine);
  drawEngine();

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Claude" })),
    engine,
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
    installed: false, settingsPath: "", hookPath: "", hookReady: false, claudeCli: null,
  };

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  // WSL is a Windows thing: the Linux build leaves the section out. WebView2
  // says "Windows" in its user agent, WebKitGTK says "Linux".
  const wsl = /Windows/.test(navigator.userAgent) ? wslSection(status.hookReady) : null;

  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    claudeSection(status),
    wsl?.section ?? "",
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

  // Every time the window comes up: refresh WSL (slow, so only while someone is
  // looking) and scroll to the section it was opened for, if any.
  const shown = (target: string) => {
    if (target) document.getElementById(target)?.scrollIntoView({ behavior: "smooth", block: "start" });
    void wsl?.refresh();
  };
  void onEvent<null>("settings-shown", async () => shown((await Bridge.takeSettingsSection()) ?? ""));
  // The first-launch offer can show the window before this page has loaded; the
  // section it left behind says so. (The window is hidden at every other launch,
  // and nothing here may start a distro then.)
  const pending = (await Bridge.takeSettingsSection()) ?? "";
  if (pending) shown(pending);
}


void main();
