import { Bridge, type CodexModel } from "../core/bridge";
import type { CodexAuthMode } from "../core/state";
import { h } from "./dom";

/** Each window owns its catalog; a billing-mode change invalidates in-flight results. */
export function codexModelPicker(className: string, invalidate: () => void) {
  const select = h("select", { class: className, "aria-label": "Codex model" });
  let mode: CodexAuthMode | null = null;
  let selected = "";
  let models: CodexModel[] = [];
  let loaded = false;
  let pending: Promise<void> = Promise.resolve();
  let request = 0;
  let failed = false;

  function render() {
    const defaultModel = models.find(model => model.isDefault);
    select.replaceChildren(h("option", {
      value: "", text: mode !== null && !loaded && !failed ? "Loading models…"
        : defaultModel ? `Default · ${defaultModel.displayName}` : "Default model",
    }), ...models.map(model => h("option", { value: model.model, text: model.displayName })),
    ...(!loaded && selected ? [h("option", {
      value: selected, disabled: true, text: failed ? "Saved model unavailable" : "Checking saved model…",
    })] : []));
    select.value = selected;
    select.disabled = !loaded && !failed;
  }

  function load() {
    const token = ++request;
    const requestedMode = mode!;
    loaded = false;
    failed = false;
    models = [];
    select.title = "Loading models from Codex CLI…";
    render();
    pending = Bridge.codexModels(requestedMode).then(result => {
      if (token !== request) return;
      models = result;
      loaded = true;
      select.title = "Models offered by your Codex CLI. Account access may vary.";
      if (selected && !models.some(model => model.model === selected)) {
        selected = "";
        invalidate();
      }
      render();
    }).catch(error => {
      if (token !== request) return;
      failed = true;
      select.title = `Could not load Codex models: ${String(error).replace(/^Error:\s*/, "")}. Reopen the menu to retry.`;
      render();
    });
  }
  select.addEventListener("focus", () => { if (failed) load(); });
  render();
  return {
    select,
    sync(authMode: CodexAuthMode, value: string) {
      selected = value;
      if (mode !== authMode) { mode = authMode; load(); }
      else if (loaded) {
        if (selected && !models.some(model => model.model === selected)) {
          selected = "";
          invalidate();
        }
        select.value = selected;
      } else if (failed) render();
    },
    async ready() {
      let current;
      do { current = pending; await current; } while (current !== pending);
      if (!loaded && selected) throw new Error("Cannot verify the saved Codex model. Select Default model or retry loading the model menu.");
    },
  };
}
