// The Portfolio card — DOM port of PortfolioCardView, PortfolioAccountSection,
// PortfolioHoldingRow and SparklineView (PortfolioViews.swift). Real balances
// from connected exchange accounts and self-custody wallets, in dollars.

import { h, clear, dot } from "./dom";
import {
  PORTFOLIO_GOLD, Portfolio, accountLabel, accountValue, formatAmount, formatChange, formatValue, historyPath,
  type Account, type Holding,
} from "../core/portfolio";
import { language, t } from "../i18n/i18n";

export interface PortfolioCardHost {
  el: HTMLElement;
  sync(): void;
}

function sparkline(prices: number[], positive: boolean): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const el = document.createElementNS(ns, "svg");
  el.setAttribute("width", "36");
  el.setAttribute("height", "14");
  el.setAttribute("viewBox", "0 0 36 14");
  el.setAttribute("aria-hidden", "true");
  const p = document.createElementNS(ns, "path");
  p.setAttribute("d", historyPath(prices, 36, 14));
  p.setAttribute("fill", "none");
  p.setAttribute("stroke", positive ? "#4CAF50" : "#F4505E");
  p.setAttribute("stroke-width", "1.2");
  p.setAttribute("stroke-linecap", "round");
  p.setAttribute("stroke-linejoin", "round");
  el.append(p);
  return el;
}

function holdingRow(x: Holding): HTMLElement {
  const color = x.change24h == null ? "#8E939C" : x.change24h >= 0 ? "#4CAF50" : "#F4505E";
  return h("div", { class: "pf-row" },
    h("span", { class: "pf-sym", text: x.symbol }),
    h("span", { class: "pf-amount", text: formatAmount(x.amount) }),
    h("span", { class: "grow" }),
    x.priceHistory.length >= 2 ? sparkline(x.priceHistory, (x.change24h ?? 0) >= 0) : null,
    x.change24h != null ? h("span", { class: "pf-change", style: `color:${color}`, text: formatChange(x.change24h) }) : null,
    x.price > 0 ? h("span", { class: "pf-value", text: formatValue(x.amount * x.price, language()) }) : null,
  );
}

function accountSection(a: Account): HTMLElement {
  const value = accountValue(a);
  const head = h("div", { class: "pf-account" },
    h("span", { class: "pf-label", text: accountLabel(a) }),
    h("span", { class: "grow" }),
    a.fetchError
      ? h("span", { class: "pf-error", text: a.fetchError, title: a.fetchError })
      : value > 0 ? h("span", { class: "pf-total", text: formatValue(value, language()) }) : null,
  );
  const el = h("div", { class: "pf-section" }, head);
  if (!a.fetchError) for (const x of a.holdings) el.append(holdingRow(x));
  return el;
}

export function buildPortfolioCard(): PortfolioCardHost {
  const el = h("div", { class: "int-card pf-card" });
  let key = "";

  function sync() {
    const s = Portfolio.state;
    const k = `${language()}~${JSON.stringify(s.accounts)}~${s.loaded}`;
    if (k === key) return;
    key = k;
    clear(el);
    const total = s.accounts.reduce((n, a) => n + accountValue(a), 0);
    el.append(h("div", { class: "int-head" },
      dot(PORTFOLIO_GOLD, 7),
      h("b", { text: t("Portfolio") }),
      h("span", { class: "grow" }),
      s.loaded && total > 0 ? h("span", { class: "pf-grand", text: formatValue(total, language()) }) : null,
    ));
    if (!s.loaded) {
      el.append(h("div", { class: "pf-empty", text: t("Loading…") }));
    } else if (s.accounts.length === 0) {
      el.append(h("div", { class: "pf-empty", text: t("No accounts connected — add one in Settings → Integrations.") }));
    } else {
      el.append(h("div", { class: "pf-list" }, ...s.accounts.map(accountSection)));
    }
  }

  return { el, sync };
}
