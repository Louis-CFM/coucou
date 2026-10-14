import { Bridge } from "../core/bridge";
import type { Settings } from "../core/state";
import { clear, h } from "../views/dom";
import { statusDot } from "./parts";
import { t, N_ } from "../i18n/i18n";

/** Installs/removes the chat integration only; agent hooks have their own controls. */
export function codexChatSection(read: () => Settings, updated: (s: Settings) => void) {
  const body = h("div", { class: "codex-chat-actions row" });
  const feedback = h("div", { class: "codex-chat-feedback", role: "status", "aria-live": "polite" });
  const el = h("section", { class: "codex-chat-settings" },
    h("h2", { text: t("Codex CLI chat") }),
    h("div", { class: "hint", text: t("Use your Codex session to chat with Mochi. Choose the model, reasoning effort and speed in the chat.") }),
    body,
    h("div", { class: "hint", text: t("Removing this integration keeps Codex CLI, your login, island hooks and model preferences.") }),
    feedback,
  );
  let busy = false;
  function sync() {
    const installed = read().codexChatEnabled;
    clear(body);
    const button = h("button", {
      class: installed ? "danger" : "primary",
      text: t(installed ? N_("Uninstall") : N_("Install")),
      onclick: () => void apply(!installed),
    }) as HTMLButtonElement;
    button.disabled = busy;
    body.append(statusDot(installed),
      h("span", { class: "hint", text: t(installed ? N_("installed") : N_("not installed")) }),
      h("span", { class: "spacer" }), button);
    el.setAttribute("aria-busy", String(busy));
  }
  async function apply(enabled: boolean) {
    if (busy) return;
    busy = true;
    clear(feedback);
    sync();
    try {
      const next = await Bridge.codexChatSetEnabled(enabled);
      updated(next);
      feedback.append(h("div", { class: "notice ok", text: t(enabled
        ? N_("Chat integration installed. Codex is selected in the chat.")
        : N_("Chat integration removed. You can install it again at any time.")) }));
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: t("Could not update the chat integration: {error}", {
        error: String(err).replace(/^Error:\s*/, ""),
      }) }));
    } finally {
      busy = false;
      sync();
    }
  }
  sync();
  return { el, sync };
}
