// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type ChatProvider, type HookHarness } from "../core/bridge";
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

// ── Hooks section ────────────────────────────────────────────────────────────

/**
 * Every coding harness Coucou can watch, one row each.
 *
 * The collapsed row is the whole story at a glance: a dot for the state, and whether
 * the harness can hand a permission decision back. Only Claude Code and Codex can, so
 * the note under Cursor's row is not decoration — a Cursor user needs to know before
 * installing that their sessions will appear but that nothing in the island can approve.
 *
 * Clicking expands into where the config lives and the button that writes it; the
 * button opens a preview inside that same panel, because the diff is the thing the
 * user has to read before clicking, and a system dialog would truncate it.
 */
function hooksSection(): HTMLElement {
  const list = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  const note = h("span", {
    class: "hint",
    text: "Hook your coding agents to Mochi. Each harness keeps its own config, and only yours is touched.",
  });

  async function load() {
    clear(list);
    const rows = (await Bridge.hookHarnesses()) ?? [];
    if (rows.length === 0) {
      list.append(h("div", { class: "hint", text: "Loading…" }));
      return;
    }
    for (const row of rows) list.append(harnessRow(row, load));
  }

  void load();
  return h("section", {}, h("h2", {}, h("span", { text: "Hooks" })), note, list);
}

function harnessRow(row: HookHarness, reload: () => Promise<void>): HTMLElement {
  const s = row.status;
  const body = h("div", { class: "pbody" });
  const chevron = h("span", { class: "hint", style: "flex:0 0 auto", text: "▸" });

  const head = h(
    "button",
    {
      type: "button",
      style: "display:flex;align-items:center;gap:9px;width:100%;text-align:left;" +
        "border:1px solid #2a2a30;background:transparent;border-radius:9px;" +
        "padding:8px 11px;color:inherit;cursor:pointer;font:inherit;",
      title: `Configure ${row.label}`,
    },
    statusDot(s.installed),
    h(
      "span",
      { style: "display:flex;flex-direction:column;gap:1px;flex:1;min-width:0" },
      h("strong", { text: row.label }),
      h("span", {
        class: "hint",
        text: s.installed
          ? (s.approval ? "Hooked in — sessions and approvals" : "Hooked in — sessions only")
          : "Not hooked in",
      }),
    ),
    chevron,
  );

  function drawBody() {
    clear(body);
    body.append(
      h("div", { class: "prow" }, h("label", { text: "Config" }),
        h("div", { class: "ctl" }, h("span", { class: "path", text: s.settingsPath }))),
      h("div", { class: "prow" }, h("label", { text: "Relay" }),
        h("div", { class: "ctl" }, h("span", { class: "path", text: s.hookPath }),
          statusDot(s.hookReady))),
    );
    if (s.note) body.append(h("div", { class: "hint", text: s.note }));
    if (!s.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: "coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.",
      }));
    }
    body.append(h("div", { style: "display:flex;gap:8px" }, ...actions()));
  }

  function actions(): HTMLElement[] {
    const install = h("button", {
      class: "primary",
      text: s.installed ? "Reinstall hooks…" : "Install hooks…",
    }) as HTMLButtonElement;
    install.addEventListener("click", () => void showPreview(true));
    // Writing hook commands that point at a relay which is not there would give
    // every session a broken hook and nothing to show for it.
    if (!s.hookReady) {
      install.disabled = true;
      install.title = "The relay isn't in place yet.";
    }
    const out: HTMLElement[] = [install];
    if (s.installed) {
      const uninstall = h("button", { class: "danger", text: "Uninstall hooks…" });
      uninstall.addEventListener("click", () => void showPreview(false));
      out.push(uninstall);
    }
    return out;
  }

  async function showPreview(install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(row.id, install);
    } catch (err) {
      // An unreadable or invalid config stops here rather than being treated as
      // empty and written over.
      clear(body);
      body.append(h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }));
      const back = h("button", { text: "Back" });
      back.addEventListener("click", drawBody);
      body.append(h("div", { style: "display:flex;gap:8px" }, back));
      return;
    }

    clear(body);
    body.append(
      h("div", {
        class: "hint",
        text: install
          ? `This is exactly what will change in ${row.label}'s config. Your own hooks are left untouched.`
          : `This removes Coucou's entries from ${row.label}'s config. Your own hooks are left untouched.`,
      }),
      renderDiff(preview.diff),
      h("div", { class: "row" }, h("span", { class: "path", text: `Backup → ${preview.backup}` })),
    );

    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: install ? "Back up and write" : "Back up and remove",
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(row.id, install, preview.fingerprint);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `Done. Previous config saved as ${backup}. Open a new ${row.label} session to pick the hooks up.`,
        }));
        const back = h("button", { text: "Close" });
        back.addEventListener("click", () => {
          expanded = false;
          chevron.textContent = "▸";
          body.style.display = "none";
        });
        body.append(h("div", { style: "display:flex;gap:8px" }, back));
        await reload();
      } catch (err) {
        confirm.disabled = false;
        body.append(h("div", { class: "notice err", text: `Could not write: ${String(err)}` }));
      }
    });

    const cancel = h("button", { text: "Cancel" });
    cancel.addEventListener("click", drawBody);
    body.append(h("div", { style: "display:flex;gap:8px" }, confirm, cancel));
  }

  let expanded = false;
  head.addEventListener("click", () => {
    expanded = !expanded;
    chevron.textContent = expanded ? "▾" : "▸";
    if (expanded) {
      if (body.childElementCount === 0) drawBody();
      body.style.display = "";
    } else {
      body.style.display = "none";
    }
  });

  body.style.display = "none";
  return h("div", { style: "display:flex;flex-direction:column;gap:6px" }, head, body);
}

// ── Chat providers section ────────────────────────────────────────────────────

/**
 * The gateway list, as an accordion.
 *
 * Every provider Coucou knows is listed, whether or not it can be reached: a row
 * missing reads as "not supported", while a greyed row tells you why. The dot is the
 * whole status in one glance — green when a key is stored or the provider is keyless,
 * red when one is needed and missing, hollow when the provider is out of reach.
 *
 * Clicking a row expands it to the two things a provider actually needs: which model
 * to call and which key to call it with. Neither is editable from the collapsed row,
 * because a 1 100-entry list next to a password field is not a list anyone reads.
 */
function chatSection(): HTMLElement {
  const list = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  const feedback = h("div", {});
  const note = h("span", {
    class: "hint",
    text: "Pick the gateway Mochi talks to. Keys stay in the Windows Credential Manager.",
  });

  async function load() {
    const rows = (await Bridge.chatProviders()) ?? [];
    clear(list);
    if (rows.length === 0) {
      list.append(h("div", { class: "hint", text: "Loading…" }));
      return;
    }
    for (const p of rows) list.append(providerRow(p, load, feedback));
  }

  void load();
  return h("section", {}, h("h2", {}, h("span", { text: "Chat" })), note, list, feedback);
}

/** Green when reachable, red when a key is missing, hollow when out of reach. */
function stateDot(p: ChatProvider): HTMLElement {
  if (p.unavailable !== null) {
    return h("i", {
      style: "width:8px;height:8px;border-radius:50%;flex:0 0 auto;" +
        "box-shadow:inset 0 0 0 1.5px #6b6b73;background:transparent;",
      title: p.unavailable,
    });
  }
  const on = p.keyPresent || p.keyless;
  return h("i", {
    style: `width:8px;height:8px;border-radius:50%;flex:0 0 auto;` +
      `background:${on ? "#22c55e" : "#f4505e"};`,
    title: on ? "Connected" : "No key yet",
  });
}

function providerRow(
  p: ChatProvider,
  reload: () => Promise<void>,
  feedback: HTMLElement,
): HTMLElement {
  const body = h("div", { class: "pbody" });
  const chevron = h("span", { class: "hint", style: "flex:0 0 auto", text: "▸" });
  const isDefault = settings.chatProvider === p.id;
  const reachable = p.unavailable === null;

  const head = h(
    "button",
    {
      type: "button",
      style: "display:flex;align-items:center;gap:9px;width:100%;text-align:left;" +
        `border:1px solid ${isDefault ? p.accent : "#2a2a30"};` +
        `background:${isDefault ? "rgba(255,255,255,0.05)" : "transparent"};` +
        "border-radius:9px;padding:8px 11px;color:inherit;cursor:pointer;" +
        "font:inherit;",
      title: reachable ? `Configure ${p.label}` : (p.unavailable ?? ""),
    },
    stateDot(p),
    h(
      "span",
      { style: "display:flex;flex-direction:column;gap:1px;flex:1;min-width:0" },
      h("strong", { text: p.label }),
      h("span", {
        class: "hint",
        text: !reachable
          ? (p.unavailable ?? "Unavailable")
          : p.keyless
            ? "Local engine — no key needed"
            : p.keyPresent
              ? "Key saved"
              : p.envVar
                ? `No key yet · ${p.envVar}`
                : "No key yet",
      }),
    ),
    isDefault ? h("span", { class: "hint", text: "default" }) : null,
    reachable ? chevron : null,
  );

  let expanded = false;
  head.addEventListener("click", () => {
    if (!reachable) return;
    expanded = !expanded;
    chevron.textContent = expanded ? "▾" : "▸";
    if (expanded) {
      if (body.childElementCount === 0) body.append(...providerBody(p, feedback, reload));
      body.style.display = "";
    } else {
      body.style.display = "none";
    }
  });

  body.style.display = "none";
  return h("div", { style: "display:flex;flex-direction:column;gap:6px" }, head, body);
}

/** The expanded half of a provider: which model, which key, and a way to make it default. */
function providerBody(
  p: ChatProvider,
  feedback: HTMLElement,
  reload: () => Promise<void>,
): HTMLElement[] {
  const out: HTMLElement[] = [];
  const key = `provider-${p.id}`;

  // ── Model ────────────────────────────────────────────────────────────────────
  // The count sits after the picker, not before it: it is a detail, and putting it
  // first pushed the select onto its own line.
  const modelCtl = h("div", { class: "ctl" });
  const modelNote = h("span", { class: "hint", style: "flex:0 0 auto", text: "…" });

  const current = () => settings.providerModels[p.id] ?? p.defaultModel;
  const select = h("select", {}) as HTMLSelectElement;
  const typed = h("input", {
    value: current(),
    style: "display:none;",
    spellcheck: "false",
    autocomplete: "off",
  }) as HTMLInputElement;

  const applyModel = (value: string) => {
    settings.providerModels[p.id] = value || p.defaultModel;
    void save();
  };
  select.addEventListener("change", () => applyModel(select.value));
  typed.addEventListener("change", () => applyModel(typed.value.trim()));

  modelCtl.append(select, typed, modelNote);
  out.push(h("div", { class: "prow" }, h("label", { text: "Model" }), modelCtl));

  void Bridge.chatModels(p.id).then((rows) => {
    const list = rows ?? [];
    clear(modelNote);
    if (list.length === 0) {
      // A local engine's roster is whatever the user pulled locally, so there is
      // nothing to enumerate — a free-text field is the honest control.
      select.style.display = "none";
      typed.style.display = "";
      modelNote.textContent = "type it";
      return;
    }
    modelNote.textContent = `${list.length}`;
    for (const [id, label] of list) {
      select.append(h("option", { value: id, text: id === label ? id : `${label} · ${id}` }));
    }
    // A model the user set by hand is not in the roster; keep it selectable rather
    // than silently resetting their choice to the catalog default.
    const chosen = current();
    if (!list.some(([id]) => id === chosen)) {
      select.append(h("option", { value: chosen, text: `${chosen} · custom` }));
    }
    select.value = chosen;
  });

  // ── Key ──────────────────────────────────────────────────────────────────────
  if (!p.keyless) {
    const field = h("input", {
      type: "password",
      placeholder: p.keyPresent ? "••••••••••••  (stored)" : (p.envVar ?? "API key"),
      autocomplete: "off",
      spellcheck: "false",
    }) as HTMLInputElement;
    const saveBtn = h("button", { class: "primary", text: "Save key" });
    const clearBtn = h("button", { class: "danger", text: "Remove" });
    clearBtn.style.display = p.keyPresent ? "" : "none";

    saveBtn.addEventListener("click", async () => {
      const value = field.value.trim();
      if (!value) return;
      clear(feedback);
      try {
        await Bridge.secretSet(key, value);
        field.value = "";
        feedback.append(h("div", { class: "notice ok", text: "Saved. It never touches disk." }));
        await reload();
      } catch (err) {
        feedback.append(h("div", { class: "notice err", text: `Could not save: ${String(err)}` }));
      }
    });

    clearBtn.addEventListener("click", async () => {
      clear(feedback);
      try {
        await Bridge.secretClear(key);
        feedback.append(h("div", { class: "notice ok", text: "Key removed." }));
        await reload();
      } catch (err) {
        feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
      }
    });

    out.push(
      h("div", { class: "prow" }, h("label", { text: "Key" }),
        h("div", { class: "ctl" }, field, saveBtn, clearBtn)),
    );
  } else {
    out.push(h("div", { class: "hint", text: "This engine runs locally and needs no key." }));
  }

  // ── Default ──────────────────────────────────────────────────────────────────
  if (p.isCustom) {
    out.push(...customFields());
  }
  const makeDefault = h("button", {
    class: "primary",
    text: settings.chatProvider === p.id ? "This is the default" : "Set as default",
    disabled: settings.chatProvider === p.id,
  }) as HTMLButtonElement;
  if (settings.chatProvider !== p.id) {
    makeDefault.addEventListener("click", () => {
      settings.chatProvider = p.id;
      void save();
      void reload();
    });
  }
  out.push(h("div", { class: "prow" }, h("label", { text: "Default" }),
    h("div", { class: "ctl" }, makeDefault)));
  return out;
}

/** The custom gateway: endpoint, dialect and model, since none come from a catalog. */
function customFields(): HTMLElement[] {
  const url = h("input", {
    value: settings.customBaseUrl,
    placeholder: "https://gateway.example.com/v1",
    style: "flex:1 1 auto;min-width:0",
    spellcheck: "false",
    autocomplete: "off",
  }) as HTMLInputElement;
  url.addEventListener("change", () => {
    settings.customBaseUrl = url.value.trim();
    void save();
  });

  const dialect = h("select", {}) as HTMLSelectElement;
  dialect.append(h("option", { value: "openAI", text: "OpenAI compatible" }));
  dialect.append(h("option", { value: "anthropic", text: "Anthropic Messages" }));
  dialect.value = settings.customDialect;
  dialect.addEventListener("change", () => {
    settings.customDialect = dialect.value as "openAI" | "anthropic";
    void save();
  });

  const model = h("input", {
    value: settings.customModel,
    placeholder: "model id",
    style: "flex:1 1 auto;min-width:0",
    spellcheck: "false",
    autocomplete: "off",
  }) as HTMLInputElement;
  model.addEventListener("change", () => {
    settings.customModel = model.value.trim();
    void save();
  });

  return [
    h("div", { class: "prow" }, h("label", { text: "Base URL" }),
      h("div", { class: "ctl" }, url)),
    h("div", { class: "prow" }, h("label", { text: "API shape" }),
      h("div", { class: "ctl" }, dialect)),
    h("div", { class: "prow" }, h("label", { text: "Model id" }),
      h("div", { class: "ctl" }, model)),
  ];
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
  // The harness list fetches its own state through hook_harnesses; this pass only
  // asks about the integration keys that still have their own fields.

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    hooksSection(),
    chatSection(),
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
