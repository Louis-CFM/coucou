// Settings → Integrations → Crypto: public prices, no key. Changes apply at
// once (the Mac's Crypto block in SettingsView.swift).

import { Bridge } from "../core/bridge";
import { Crypto, type CryptoExchange, type CryptoPrefs } from "../core/crypto";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

function segmented<T extends string>(options: [T, string][], value: T, change: (v: T) => void): HTMLElement {
  const box = h("div", { class: "row", style: "gap:4px" });
  const buttons = options.map(([v, label]) => {
    const b = h("button", { class: v === value ? "primary" : "", text: label });
    b.addEventListener("click", () => {
      for (const x of buttons) x.classList.toggle("primary", x === b);
      change(v);
    });
    return b;
  });
  box.append(...buttons);
  return box;
}

export function cryptoSection(): HTMLElement {
  const box = h("div", { style: "display:flex;flex-direction:column;gap:7px" });

  function save(next: Partial<CryptoPrefs>) {
    Crypto.state = { ...Crypto.state, prefs: { ...Crypto.state.prefs, ...next } };
    void Bridge.cryptoSetPrefs(Crypto.state.prefs);
  }

  function draw() {
    const p = Crypto.state.prefs;
    box.replaceChildren();
    const coins = h("input", { type: "text", placeholder: t("Coins (BTC, ETH, SOL…)"), style: "flex:1;min-width:0" }) as HTMLInputElement;
    coins.value = p.coins;
    coins.addEventListener("change", () => save({ coins: coins.value }));
    coins.addEventListener("keydown", (e) => {
      if (e.key === "Enter") save({ coins: coins.value });
    });

    const alert = h("button", { class: p.alertEnabled ? "switch on" : "switch", "aria-pressed": p.alertEnabled });
    alert.addEventListener("click", () => {
      save({ alertEnabled: !Crypto.state.prefs.alertEnabled });
      draw();
    });
    const percent = h("input", { type: "number", min: "1", max: "50", step: "1", style: "width:60px" }) as HTMLInputElement;
    percent.value = String(p.alertPercent);
    percent.addEventListener("change", () => {
      const n = Math.min(50, Math.max(1, Math.round(Number(percent.value) || 5)));
      save({ alertPercent: n });
      draw();
    });

    box.append(
      h("div", { class: "row", style: "gap:8px" },
        h("span", { style: "font-size:12px;min-width:70px", text: t("Exchange") }),
        segmented<CryptoExchange>([["coinbase", "Coinbase"], ["okx", "OKX"]], p.exchange, (v) => save({ exchange: v })),
      ),
      h("div", { class: "row", style: "gap:8px" },
        h("span", { style: "font-size:12px;min-width:70px", text: t("Currency") }),
        segmented([["EUR", "EUR €"], ["USD", "USD $"]], p.currency === "USD" ? "USD" : "EUR", (v) => save({ currency: v })),
      ),
      h("div", { class: "row", style: "gap:8px" }, coins),
      h("div", { class: "row", style: "gap:8px" },
        alert,
        h("span", { style: "font-size:12px", text: t("Alert me when a coin moves {0} %", { 0: p.alertPercent }) }),
        p.alertEnabled ? percent : null,
      ),
      h("div", { class: "hint", text: t("Public prices from the exchange: no account, no key. Read every minute, only while the pill is on.") }),
    );
  }

  void Bridge.cryptoState().then((s) => {
    if (s) Crypto.state = s;
    draw();
  });
  draw();
  return box;
}
