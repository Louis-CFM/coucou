import { Bridge } from "../core/bridge";
import { EXCHANGE_NAMES, accountValue, readPortfolio } from "../core/portfolio";
import { sparklinePoints } from "../core/markets";
import { h } from "./dom";
import { language, t } from "../i18n/i18n";

function money(value: number | null): string {
  return value == null || !Number.isFinite(value) ? "—" : new Intl.NumberFormat(language(), { style: "currency", currency: "USD", maximumFractionDigits: Math.abs(value) < 1 ? 6 : 2 }).format(value);
}

export function portfolioCard(data: Record<string, unknown>, detail: boolean, toggleDetail: () => void, openSettings: () => void): HTMLElement {
  const portfolio = readPortfolio(data);
  const rows = h("div", { class: detail ? "int-detail-body" : "int-rows", style: "overflow:auto;max-height:260px" });
  for (const account of detail ? portfolio.accounts : portfolio.accounts.slice(0, 3)) {
    const total = accountValue(account);
    rows.append(h("div", { class: "int-row" }, h("b", { class: "int-name", text: EXCHANGE_NAMES[account.label] ?? account.label, title: account.network }),
      h("span", { text: `${total.complete ? "" : "≈ "}${money(total.value)}` })));
    if (account.error) rows.append(h("div", { class: "int-status", style: "color:#F4505E", text: account.error }));
    if (!detail) continue;
    for (const holding of account.holdings) {
      const row = h("div", { class: "int-row" }, h("span", { class: "int-name", text: holding.symbol }),
        h("span", { text: new Intl.NumberFormat(language(), { maximumFractionDigits: 8 }).format(holding.amount) }),
        h("span", { text: money(holding.priceUsd == null ? null : holding.priceUsd * holding.amount) }));
      if (holding.change != null) row.append(h("small", { style: `color:${holding.change >= 0 ? "#22C55E" : "#F4505E"}`, text: `${holding.change > 0 ? "+" : ""}${holding.change.toFixed(1)}%` }));
      const points = sparklinePoints(holding.history);
      if (points) {
        const chart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        chart.setAttribute("viewBox", "-1 -1 74 26"); chart.setAttribute("width", "72"); chart.setAttribute("height", "24");
        chart.setAttribute("role", "img"); chart.setAttribute("aria-label", `${holding.symbol} · ${t("History")}`);
        const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
        line.setAttribute("points", points); line.setAttribute("fill", "none"); line.setAttribute("stroke", "#FFD700"); line.setAttribute("stroke-width", "1.5");
        chart.append(line); row.append(chart);
      }
      rows.append(row);
    }
  }
  const summary = h("div", { class: "int-status", text: `${portfolio.complete ? t("Total") : t("Partial total")} · ${money(portfolio.totalUsd)}` });
  const errors = h("div", { class: "int-status", role: "status" });
  if (portfolio.unpriced) errors.append(h("div", { text: t("Unpriced assets: {n}", { n: portfolio.unpriced }) }));
  if (portfolio.failed) errors.append(h("div", { text: t("Failed accounts: {n}", { n: portfolio.failed }) }));
  if (portfolio.priceError) errors.append(h("div", { text: portfolio.priceError }));
  return h("div", { class: "int-card" }, h("div", { class: "int-head" }, h("b", { text: "Portfolio" })), summary, rows, errors,
    h("div", { class: "int-actions" }, h("button", { class: "link-btn", text: detail ? t("Back") : t("Details"), onclick: toggleDetail }),
      h("button", { class: "link-btn", text: t("Refresh"), onclick: () => void Bridge.refreshIntegration("integration_portfolio") }),
      h("button", { class: "link-btn", text: t("Settings…"), onclick: openSettings })));
}
