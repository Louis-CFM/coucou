// Settings → Chat provider: Anthropic or the user's own 9router (an
// OpenAI-compatible gateway). Self-contained: it reads and saves settings
// through the bridge and follows settings-changed like the island does.

import { Bridge, onEvent } from "../core/bridge";
import { DEFAULT_SETTINGS, type ChatProvider, type Settings } from "../core/state";
import { ANTHROPIC_MODELS, DEFAULT_ANTHROPIC_MODEL } from "../core/models";
import { h, clear } from "../views/dom";

const KEY = "router-api-key";
const OK = "#22c55e";
const MISSING = "#f4505e";

function errText(err: unknown): string {
  return String(err).replace(/^Error:\s*/, "");
}

export function renderRouterSection(container: HTMLElement): void {
  let settings: Settings = { ...DEFAULT_SETTINGS };

  async function save(patch: Partial<Settings>) {
    settings = { ...settings, ...patch };
    await Bridge.saveSettings(settings);
  }

  // ── Provider ────────────────────────────────────────────────────────────────
  const provider = h("select", { "aria-label": "Chat provider" }) as HTMLSelectElement;
  provider.append(
    h("option", { value: "anthropic", text: "Anthropic (Claude API)" }),
    h("option", { value: "router", text: "9router (OpenAI-compatible)" }),
  );

  // ── Base URL ────────────────────────────────────────────────────────────────
  const url = h("input", {
    type: "text",
    placeholder: "https://your-9router-host/v1",
    autocomplete: "off",
    spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
    "aria-label": "9router base URL",
  }) as HTMLInputElement;
  const saveUrl = h("button", { text: "Save URL" });

  // ── API key ─────────────────────────────────────────────────────────────────
  const dot = h("i", { class: "dot", style: `background:${MISSING}` });
  const keyState = h("span", { class: "hint" });
  const keyField = h("input", {
    type: "password",
    placeholder: "API key",
    autocomplete: "off",
    spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
    "aria-label": "9router API key",
  }) as HTMLInputElement;
  const saveKey = h("button", { class: "primary", text: "Save key" });
  const clearKey = h("button", { class: "danger", text: "Remove" });

  const test = h("button", { text: "Test connection" });
  const feedback = h("div", {});

  function say(kind: "ok" | "err" | "warn", text: string) {
    clear(feedback);
    feedback.append(h("div", { class: `notice ${kind}`, text }));
  }

  async function refreshKey() {
    const present = (await Bridge.secretPresent(KEY)) ?? false;
    dot.style.background = present ? OK : MISSING;
    keyState.textContent = present
      ? "Key saved in the Windows Credential Manager."
      : "No 9router key yet — the 9router chat needs one.";
    keyField.placeholder = present ? "••••••••••••  (stored)" : "API key";
    clearKey.style.display = present ? "" : "none";
  }

  function syncFields() {
    provider.value = settings.chatProvider;
    if (document.activeElement !== url) url.value = settings.routerBaseUrl;
  }

  /** The URL in the field, validated and normalised by Rust. */
  async function checkedUrl(): Promise<string | null> {
    try {
      const normalized = await Bridge.routerNormalizeUrl(url.value);
      url.value = normalized;
      return normalized;
    } catch (err) {
      say("err", errText(err));
      return null;
    }
  }

  provider.addEventListener("change", async () => {
    const next = provider.value as ChatProvider;
    let model = settings.model;
    if (next === "anthropic" && !ANTHROPIC_MODELS.some(([id]) => id === model)) {
      model = DEFAULT_ANTHROPIC_MODEL;
    }
    if (next === "router") {
      // Land on a model the gateway actually offers when the list is reachable;
      // otherwise keep the saved one and let the island picker show the error.
      try {
        const ids = await Bridge.routerModels(false);
        if (ids.length && !ids.includes(model)) model = ids[0];
      } catch (err) {
        say("warn", `Switched to 9router, but the model list did not load: ${errText(err)}`);
      }
    }
    await save({ chatProvider: next, model });
  });

  async function persistUrl(announce: boolean): Promise<string | null> {
    if (!url.value.trim()) return null;
    const normalized = await checkedUrl();
    if (normalized == null) return null;
    if (normalized !== settings.routerBaseUrl) await save({ routerBaseUrl: normalized });
    if (announce) say("ok", "Base URL saved.");
    return normalized;
  }

  saveUrl.addEventListener("click", () => void persistUrl(true));
  url.addEventListener("change", () => void persistUrl(true));
  url.addEventListener("keydown", (e) => {
    if (e.key === "Enter") void persistUrl(true);
  });

  saveKey.addEventListener("click", async () => {
    const value = keyField.value.trim();
    if (!value) return;
    try {
      await Bridge.secretSet(KEY, value);
      keyField.value = "";
      say("ok", "Saved. It never touches disk.");
      await refreshKey();
    } catch (err) {
      say("err", `Could not save: ${errText(err)}`);
    }
  });

  clearKey.addEventListener("click", async () => {
    try {
      await Bridge.secretClear(KEY);
      say("ok", "Key removed.");
      await refreshKey();
    } catch (err) {
      say("err", `Could not remove: ${errText(err)}`);
    }
  });

  test.addEventListener("click", async () => {
    const normalized = await persistUrl(false);
    if (normalized == null) {
      if (!url.value.trim()) say("err", "Enter the 9router base URL first.");
      return;
    }
    test.disabled = true;
    say("warn", "Testing…");
    try {
      const ids = await Bridge.routerModels(true, normalized);
      if (settings.chatProvider === "router" && ids.length && !ids.includes(settings.model)) {
        await save({ model: ids[0] });
      }
      say("ok", `Connected — ${ids.length} model${ids.length === 1 ? "" : "s"} available. URL saved; pick a model from the dropdown left of the chat field.`);
    } catch (err) {
      say("err", errText(err));
    } finally {
      test.disabled = false;
    }
  });

  container.append(
    h(
      "section",
      {},
      h("h2", {}, dot, h("span", { text: "Chat provider" })),
      h("div", {
        class: "hint",
        text: "Choose what the island chat talks to. 9router gets plain text chat without web search; pick its model from the dropdown left of the chat field.",
      }),
      h("div", { class: "row" }, h("label", { text: "Provider" }), provider),
      h("div", { class: "row" }, h("label", { text: "9router base URL" }), url, saveUrl),
      keyState,
      h("div", { class: "row" }, h("label", { text: "9router API key" }), keyField, saveKey, clearKey),
      h("div", { class: "row" }, h("label", { text: "" }), test),
      feedback,
    ),
  );

  void (async () => {
    const boot = await Bridge.boot();
    if (boot) settings = { ...settings, ...boot.settings };
    syncFields();
    await refreshKey();
  })();

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
    syncFields();
  });
}
