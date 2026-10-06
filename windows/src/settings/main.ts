// Settings window — the place where anything that writes to disk is confirmed.
// Agent hooks (Pi, Copilot CLI, Antigravity, Claude Code), the API key, the
// integrations and the general preferences all live here.

import "./settings.css";
import { Bridge, onEvent, type HookStatus } from "../core/bridge";
import { DEFAULT_SETTINGS, MAX_PILLS, type Settings } from "../core/state";
import { h, clear, dot } from "../views/dom";

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

// ── Agents section ────────────────────────────────────────────────────────────

interface AgentDef {
  id: Settings["activeAgent"];
  name: string;
  /** What installing actually writes, and why it is safe. */
  hint: string;
  /** What the user has to restart for the hooks to take effect. */
  restart: string;
}

const AGENTS: AgentDef[] = [
  {
    id: "pi",
    name: "Pi",
    hint: "Installs a single extension file in ~/.pi/agent/extensions/. Pi then reports its sessions, tool calls and permission requests to the island, and waits for your Allow or Deny.",
    restart: "Restart Pi to load the extension.",
  },
  {
    id: "copilot",
    name: "Copilot CLI",
    hint: "Adds Coucou's entries to ~/.copilot/hooks/coucou.json. Your own Copilot hooks are left exactly as they are.",
    restart: "Open a new Copilot CLI session to pick the hooks up.",
  },
  {
    id: "antigravity",
    name: "Antigravity",
    hint: "Adds Coucou's entries to ~/.gemini/config/hooks.json, using Antigravity's own invocation events plus the legacy lifecycle names so a session is never half-tracked.",
    restart: "Restart Antigravity to pick the hooks up.",
  },
  {
    id: "codex",
    name: "Codex",
    hint: "Adds Coucou's entries to ~/.codex/hooks/hooks.json, using the same matcher shape and event set the macOS app installs. Your own Codex hooks are left alone.",
    restart: "Restart Codex to pick the hooks up.",
  },
  {
    id: "claudeCode",
    name: "Claude Code",
    hint: "Adds Coucou's entries to ~/.claude/settings.json. Tool calls, questions and permission requests show up in the island, and you can answer them there.",
    restart: "Open a new Claude Code session to pick the hooks up.",
  },
];

const agentDef = (id: Settings["activeAgent"]): AgentDef =>
  AGENTS.find((a) => a.id === id) ?? AGENTS[0];

/** Whether the user has switched an agent off in settings. */
const isDisabled = (id: string): boolean => (settings.disabledAgents ?? []).includes(id);

async function agentsSection(initial: HookStatus): Promise<HTMLElement> {
  const statuses: Record<string, HookStatus> = { [settings.activeAgent]: initial };
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const picker = h("div", { class: "row" });
  const head = h("h2", {}, h("span", { text: "Agents" }));
  const toggles = h("div", { style: "display:flex;flex-direction:column;gap:6px" });
  const section = h("section", {}, head, picker, toggles, body);

  const statusFor = (def: AgentDef): HookStatus =>
    statuses[def.id] ?? {
      installed: false, managed: false, settingsPath: "", hookPath: "", hookReady: false,
    };

  const drawPicker = () => {
    clear(picker);
    for (const def of AGENTS) {
      const active = def.id === settings.activeAgent;
      picker.append(
        h("button", {
          class: active ? "seg on" : "seg",
          text: def.name,
          onclick: async () => {
            if (settings.activeAgent === def.id) return;
            settings.activeAgent = def.id;
            void save();
            drawPicker();
            await rebuild();
          },
        }),
      );
    }
  };

  const rebuild = async () => {
    const def = agentDef(settings.activeAgent);
    const fresh = await Bridge.hooksStatus(def.id);
    if (fresh) statuses[def.id] = fresh;
    clear(body);
    draw();
    drawHead();
  };

  const drawHead = () => {
    const def = agentDef(settings.activeAgent);
    clear(head);
    head.append(statusDot(statusFor(def).installed), h("span", { text: "Agents" }));
  };

  function draw() {
    const def = agentDef(settings.activeAgent);
    const status = statusFor(def);

    body.append(
      h("div", {
        class: "hint",
        text: status.installed
          ? `Coucou is hooked into your ${def.name} sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there.`
          : def.hint,
      }),
      h("div", { class: "row" },
        h("label", { text: def.id === "pi" ? "extension" : "config" }),
        h("span", { class: "path", text: status.settingsPath || "…" }),
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

    // Something is there that Coucou did not write — for Pi, almost always an
    // extension you have edited yourself. Coucou will not overwrite or delete it,
    // so it does not offer buttons that would: the only honest action left is to
    // tell you where the file is and let you decide.
    const yours = status.installed && !status.managed;
    if (yours) {
      body.append(
        h("div", {
          class: "notice",
          text: `There is already a ${def.name} extension at ${status.settingsPath} that Coucou did not write. `
            + "Coucou has left it exactly as it is — reinstalling would replace it and uninstalling would "
            + "delete it, and neither is something Coucou can undo, so neither button is offered. "
            + "Your agent keeps reporting to the island; the file on disk is the one that gets loaded.",
        }),
      );
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: status.installed ? `Reinstall ${def.name} hooks…` : `Install ${def.name} hooks…`,
      onclick: () => showPreview(def, true),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = "The relay isn't installed yet.";
    }
    if (yours) {
      install.disabled = true;
      install.title = "That file is yours. Coucou will not overwrite it.";
    }
    actions.append(install);
    if (status.installed && !yours) {
      actions.append(h("button", {
        class: "danger",
        text: "Uninstall hooks…",
        onclick: () => showPreview(def, false),
      }));
    }
    body.append(actions);
  }

  async function showPreview(def: AgentDef, install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(install, def.id);
    } catch (err) {
      // An unreadable or invalid config stops here rather than being treated as
      // empty and written over.
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
          ? `This is exactly what will change in ${preview.settingsPath}. Your own hooks are left untouched.`
          : "This removes Coucou's entries only. Your own hooks are left untouched.",
      }),
      renderDiff(preview.diff),
    );
    if (preview.backup) {
      body.append(h("div", { class: "row" },
        h("span", { class: "path", text: `Backup → ${preview.backup}` }),
      ));
    }
    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: install ? "Back up and write" : "Back up and remove",
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(install, preview.fingerprint, def.id);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `Done. Previous settings saved as ${backup}. ${def.restart}`,
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

  /**
   * Per-agent on/off switches.
   *
   * Switching an agent off is not just a UI hiding. The hooks are removed, so the
   * agent genuinely stops calling Coucou and sees it as off, and the pill stops
   * appearing, which frees a slot in the island. Anything less would leave an
   * agent still wired up to a Coucou the user believes they have turned off —
   * which is worse than not offering the switch at all.
   */
  const drawToggles = () => {
    clear(toggles);
    // Claude Code is still pickable as the active agent above, but it is a pill
    // like any other, so its switch lives in the Integrations section beside
    // the rest of them rather than buried among the agent hook toggles.
    for (const def of AGENTS.filter((a) => a.id !== "claudeCode")) {
      const off = isDisabled(def.id);
      const btn = h("button", {
        class: "link-btn",
        style: "color:#8e939c;font-size:11.5px",
        text: off ? "Enable" : "Turn off",
      });
      btn.addEventListener("click", async () => {
        btn.disabled = true;
        const list = settings.disabledAgents ?? [];
        if (off) {
          // Enabling an agent spends a pill slot, same as an integration.
          // Refused before anything is written, so the button never ends up
          // saying "on" for an agent the island had no room to show.
          if (pillBudgetFull()) {
            btn.disabled = false;
            body.append(h("div", {
              class: "notice err",
              text: `That is ${MAX_ACTIVE} pills already. Turn one off before enabling ${def.name}.`,
            }));
            return;
          }
          settings.disabledAgents = list.filter((a) => a !== def.id);
          await save();
        } else {
          // Removing the hooks is the part that matters. If it fails the switch
          // is not flipped, so the list can never claim an agent is off while it
          // is still wired up.
          try {
            const status = await Bridge.hooksStatus(def.id);
            if (status?.installed) {
              const preview = await Bridge.hooksPreview(false, def.id);
              if (preview) await Bridge.hooksApply(false, preview.fingerprint, def.id);
            }
            settings.disabledAgents = [...list, def.id];
            await save();
          } catch (err) {
            btn.disabled = false;
            body.append(h("div", {
              class: "notice err",
              text: `Could not turn ${def.name} off: ${String(err)}`,
            }));
            return;
          }
        }
        const fresh = await Bridge.hooksStatus(def.id);
        if (fresh) statuses[def.id] = fresh;
        drawToggles();
        drawPicker();
        drawHead();
      });
      toggles.append(h("div", { class: "row" },
        h("span", { class: off ? "hint" : "", text: `${def.name} — ${off ? "off" : "on"}` }),
        h("div", { class: "grow" }),
        btn,
      ));
    }
  };

  drawToggles();
  drawPicker();
  drawHead();
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

  // ── Provider ───────────────────────────────────────────────────────────
  //
  // Provider is not a model. Pi is a whole agent with its own authentication,
  // so picking it must not present an API key field: there is no key to enter,
  // and offering an empty one implies Pi is configured the way Claude is. The
  // Claude-only rows are removed from the tree rather than hidden, so they are
  // genuinely gone from the accessibility tree too.
  const providerSeg = h("div", { class: "seg" });
  const claudeRows = h("div", {});
  const piNote = h("div", { class: "row" });

  const claudeBtn = h("button", {
    text: "Claude",
    onclick: () => {
      if (settings.chatProvider === "claude") return;
      settings.chatProvider = "claude";
      void save();
      applyProvider();
    },
  });
  const piBtn = h("button", {
    text: "Pi",
    onclick: () => {
      if (settings.chatProvider === "pi") return;
      settings.chatProvider = "pi";
      void save();
      applyProvider();
    },
  });
  providerSeg.append(claudeBtn, piBtn);

  function applyProvider() {
    const isPi = settings.chatProvider === "pi";
    claudeBtn.classList.toggle("on", !isPi);
    piBtn.classList.toggle("on", isPi);
    clear(claudeRows);
    if (!isPi) {
      claudeRows.append(
        h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn),
        h("div", { class: "row" }, h("label", { text: "Model" }), model),
      );
    } else {
      clear(piNote);
      piNote.append(
        h("div", {
          class: "notice",
          text:
            "The island will ask Pi directly, using your own Pi install and its own " +
            "settings. No API key is needed — Pi is already signed in. Coucou runs it as " +
            "a separate process, so this never touches a Pi session an agent is using.",
        }),
      );
    }
  }
  applyProvider();

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Chat" })),
    state,
    h("div", { class: "row" }, h("label", { text: "Provider" }), providerSeg),
    claudeRows,
    piNote,
    feedback,
  );
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. Empty when there is
   *  nothing to store - see `hint`. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
  /** Shown when there are no fields. An integration that needs no API key says
   *  why it is always available rather than rendering an empty form. */
  hint?: string;
}

const INTEGRATIONS: IntegrationDef[] = [
  // No fields: Global Media Control needs no key and asks for no permission, so
  // it is ready as soon as anything is playing. Listed first because it is the
  // one integration that is basically always available.
  { id: "integration_music", name: "Music", color: "#FA2D48", fields: [],
    hint: "Reads whatever is playing on this PC - Spotify, Chrome, VLC, anything publishing a media session. No keys, no permissions." },
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

/**
 * Pill budget, shared with the island (core/state.ts).
 *
 * Defined here too because this window edits the settings object directly and
 * never touches State. Both numbers have to agree, or a switch in this window
 * can enable something the island has no room to show.
 */
const MAX_ACTIVE = MAX_PILLS;

/** Enabled agents plus enabled integrations: what the pill budget actually counts. */
function budgetUsed(): number {
  const disabled = new Set(settings.disabledAgents ?? []);
  const agents = AGENTS.filter((a) => !disabled.has(a.id)).length;
  // Older builds recorded enabled agents in activeIntegrations; those entries
  // would otherwise be counted a second time and put the window over its cap.
  const integrations = settings.activeIntegrations.filter((id) => !id.startsWith("agent_")).length;
  return agents + integrations;
}

/** Whether one more pill would exceed the budget. */
function pillBudgetFull(): boolean {
  return budgetUsed() >= MAX_ACTIVE;
}

/**
 * Whether turning the last remaining pill off must be refused.
 *
 * An island with nothing in it is not a valid state: no card, no focus, and no
 * way back except by reopening this window. So the last pill stays on.
 */
function refuseLastPill(note: HTMLElement) {
  note.style.color = "#F4505E";
  note.textContent = "At least one pill has to stay on.";
}

/** Shown when a switch is refused. A control that silently ignores a click is
 *  indistinguishable from a broken one. */
function refuseFullBudget(sw: HTMLElement, note: HTMLElement) {
  sw.classList.remove("shake");
  void sw.offsetWidth;
  sw.classList.add("shake");
  note.textContent = `That is ${MAX_ACTIVE} pills already. Switch one off to add another.`;
  note.style.color = "#F4505E";
}

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = budgetUsed();
    note.style.color = "";
    note.textContent = `Pick up to ${MAX_ACTIVE} pills to show next to Mochi — ${used}/${MAX_ACTIVE} in use. Enabled agents count toward this too. Keys are stored in the Windows Credential Manager, never on disk.`;
  }

  // VS Code leads the Integrations section: it is the pill the island opens on,
  // and it is governed by `disabledAgents` like the agents are, not by
  // activeIntegrations. Its own switch sits with the other pill switches so that
  // every choice that costs a slot is made in the same place.
  {
    const off = isDisabled("claudeCode");
    const sw = h("button", { class: off ? "switch" : "switch on" });
    sw.addEventListener("click", () => {
      const list = settings.disabledAgents ?? [];
      const isOff = (settings.disabledAgents ?? []).includes("claudeCode");
      if (!isOff) {
        if (budgetUsed() <= 1) {
          refuseLastPill(note);
          return;
        }
        settings.disabledAgents = [...list, "claudeCode"];
      } else {
        if (pillBudgetFull()) {
          refuseFullBudget(sw, note);
          return;
        }
        settings.disabledAgents = list.filter((a) => a !== "claudeCode");
      }
      sw.classList.toggle("on", isOff);
      updateNote();
      void save();
    });
    list.append(h("div", { class: "int-row" },
      h("div", { class: "int-head" },
        sw,
        dot("#F5F6F8", 8),
        h("span", { text: "VS Code (Claude Code)" }),
      ),
    ));
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        if (budgetUsed() <= 1) {
          refuseLastPill(note);
          return;
        }
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        // Shared budget: enabled agents spend slots too, so a full agent row
        // stops this switch rather than pushing the island past its width.
        if (budgetUsed() >= MAX_ACTIVE) {
          refuseFullBudget(sw, note);
          return;
        }
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    if (def.hint) rows.append(h("div", { class: "hint", text: def.hint }));
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
    h("div", { class: "row" },
      h("label", { text: "Desktop Mochi" }),
      toggle(settings.desktopMochi, (v) => {
        settings.desktopMochi = v;
        void Bridge.desktopMochiSetEnabled(v);
      }),
    ),
    h("div", { class: "row" },
      h("span", { class: "hint", text: "Mochi lives on your desktop as a floating pet. Drag it anywhere, hover to make it love you, click to pat, double-click to send it home." }),
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
  const status = (await Bridge.hooksStatus(settings.activeAgent)) ?? {
    installed: false, managed: false, settingsPath: "", hookPath: "", hookReady: false,
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
    await agentsSection(status),
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
