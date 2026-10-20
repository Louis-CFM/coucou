// The Crypto card — DOM port of CryptoCardView, CryptoRow and CryptoSparkline
// (CryptoViews.swift). The coins picked in Settings with their price, 24 h
// curve and 24 h change; three in view, the rest a scroll away; a click opens
// the coin's page on the exchange.

import { h, clear, dot } from "./dom";
import { Bridge } from "../core/bridge";
import { CRYPTO_ORANGE, Crypto, change, formatChange, formatPrice, ordered, parseCoins, sparkPath, type CryptoQuote } from "../core/crypto";
import { language, t } from "../i18n/i18n";

export interface CryptoCardHost {
  el: HTMLElement;
  sync(): void;
}

function sparkline(values: number[], color: string): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const el = document.createElementNS(ns, "svg");
  el.setAttribute("width", "30");
  el.setAttribute("height", "12");
  el.setAttribute("viewBox", "0 0 30 12");
  el.setAttribute("aria-hidden", "true");
  const d = sparkPath(values, 30, 12);
  if (d) {
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", d);
    p.setAttribute("fill", "none");
    p.setAttribute("stroke", color);
    p.setAttribute("stroke-opacity", "0.85");
    p.setAttribute("stroke-width", "1.2");
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
    el.append(p);
  }
  return el;
}

function row(q: CryptoQuote, currency: string, highlighted: boolean): HTMLElement {
  const pct = change(q);
  const tone = pct >= 0 ? "#22C55E" : "#F4505E";
  const el = h("button", { class: "crypto-row", onclick: () => void Bridge.cryptoOpen(q.symbol) },
    h("span", { class: "crypto-sym", text: q.symbol }),
    sparkline(q.spark, tone),
    h("span", { class: "grow" }),
    h("span", { class: "crypto-price", text: formatPrice(q.price, currency) }),
    h("span", { class: "crypto-change", style: `color:${tone}`, text: formatChange(pct) }),
  );
  if (highlighted) el.style.setProperty("--hl", `${tone}1a`);
  if (highlighted) el.classList.add("hl");
  return el;
}

export function buildCryptoCard(): CryptoCardHost {
  const el = h("div", { class: "int-card crypto-card" });
  let key = "";

  function sync() {
    const s = Crypto.state;
    const k = [language(), JSON.stringify(s)].join("~");
    if (k === key) return;
    key = k;
    clear(el);
    el.append(h("div", { class: "int-head" },
      dot(CRYPTO_ORANGE, 7),
      h("b", { text: "Crypto" }),
      h("span", { text: s.exchangeName }),
      h("span", { class: "crypto-24h", text: "24h" }),
    ));
    if (s.quotes.length === 0) {
      const text = !s.loaded
        ? t("Loading…")
        : parseCoins(s.prefs.coins).length === 0
          ? t("Add coins in Settings → Integrations")
          : t("{0} did not answer", { 0: s.exchangeName });
      el.append(h("div", { class: "crypto-empty", text }));
      return;
    }
    const rows = h("div", { class: "crypto-rows" },
      ...ordered(s).map((q) => row(q, s.prefs.currency === "USD" ? "USD" : "EUR", q.symbol === s.alertSymbol)));
    if (s.missing.length) {
      rows.append(h("div", { class: "crypto-missing", text: t("Not on this exchange: {0}", { 0: s.missing.join(", ") }) }));
    }
    el.append(rows);
  }

  return { el, sync };
}
