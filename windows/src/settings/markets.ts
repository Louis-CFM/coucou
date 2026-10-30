import { Bridge } from "../core/bridge";
import { h, clear } from "../views/dom";
import { t } from "../i18n/i18n";

export function marketsSection(): HTMLElement {
  const body = h("div", { class: "hint", text: t("Loading…") });
  const section = h("section", {}, h("h2", { text: "Crypto" }),
    h("p", { class: "hint", text: t("Public prices from the exchange: no account, no key. Read every minute, only while the pill is on.") }), body);
  void Bridge.marketPrefs().then((prefs) => {
    clear(body);
    if (!prefs) { body.textContent = t("Error"); return; }
    const exchange = h("select", { "aria-label": t("Exchange") },
      h("option", { value: "coinbase", text: "Coinbase", selected: prefs.exchange === "coinbase" }),
      h("option", { value: "okx", text: "OKX", selected: prefs.exchange === "okx" }));
    const currency = h("select", { "aria-label": t("Currency") }, ...["EUR", "USD"].map((value) => h("option", { value, text: value, selected: prefs.currency === value })));
    const coins = h("input", { value: prefs.coins.join(", "), "aria-label": t("Coins (BTC, ETH, SOL…)"), maxlength: 128, spellcheck: "false" });
    const alerts = h("input", { type: "checkbox", checked: prefs.alerts });
    const percent = h("input", { type: "number", value: prefs.alertPercent, min: 0.1, max: 100, step: 0.1, style: "width:75px", "aria-label": "%" });
    const status = h("div", { class: "hint", role: "status" });
    const save = h("button", { text: t("Save"), onclick: async () => {
      save.disabled = true; status.textContent = "";
      try {
        await Bridge.marketSave({ exchange: exchange.value as "coinbase" | "okx", currency: currency.value as "EUR" | "USD",
          coins: coins.value.split(/[\s,;]+/).filter(Boolean), alerts: alerts.checked, alertPercent: Number(percent.value) });
        status.textContent = t("Done");
      } catch (error) { status.textContent = String(error); }
      finally { save.disabled = false; }
    } });
    body.append(
      h("div", { class: "row" }, h("label", { text: t("Exchange") }), exchange, h("label", { text: t("Currency") }), currency),
      h("label", { class: "row" }, h("span", { text: t("Coins (BTC, ETH, SOL…)") }), coins),
      h("label", { class: "row" }, alerts, h("span", { text: t("Alert me when a coin moves {0} %", { 0: "" }) }), percent),
      h("div", { class: "row" }, save, status),
    );
  });
  return section;
}
