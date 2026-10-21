import { Bridge } from "../core/bridge";
import { t } from "../i18n/i18n";
import { h } from "../views/dom";

/** Codex owns the shared CLI login; this section never signs other clients out. */
export function codexChatSection(useInChat: () => void): HTMLElement {
  const state = h("div", { class: "hint", role: "status", "aria-live": "polite" });
  const refresh = h("button", { text: t("Refresh") });
  const use = h("button", { class: "primary", text: t("Use in chat") });
  use.disabled = true;
  use.addEventListener("click", useInChat);

  async function check() {
    refresh.disabled = true;
    use.disabled = true;
    try {
      const status = await Bridge.codexChatStatus();
      state.textContent = status.connected
        ? `${t("Connected")}${status.plan ? ` · ${status.plan}` : ""}`
        : status.installed
          ? t("Sign in to Codex with ChatGPT first: run codex login in a terminal, then refresh.")
          : t("Install Codex CLI, then sign in with ChatGPT using codex login.");
      use.disabled = !status.connected;
    } catch (err) {
      state.textContent = String(err).replace(/^Error:\s*/, "");
    } finally {
      refresh.disabled = false;
    }
  }
  refresh.addEventListener("click", () => void check());
  void check();
  return h("section", {},
    h("h2", { text: "Codex (ChatGPT)" }),
    h("div", { class: "hint", text: t("Use your ChatGPT plan through Codex CLI. No API key; your plan's limits apply.") }),
    state,
    h("div", { class: "row" }, refresh, use),
  );
}
