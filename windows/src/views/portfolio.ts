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
  const rows = h("div", { class: `${detail ? "int-detail-body" : "int-rows"} portfolio-rows` });
  for (const account of detail ? portfolio.accounts : portfolio.accounts.slice(0, 3)) {
    const total = accountValue(account);
    const row = h("div", { class: "int-row portfolio-row" }, h("b", { class: "int-name", text: EXCHANGE_NAMES[account.label] ?? account.label, title: account.network }));
    // On the account's own line, shrunk to the room left; its tooltip has it all.
    if (account.error) row.append(h("span", { class: "portfolio-error", title: account.error, text: account.error }));
    row.append(h("span", { class: "portfolio-value", text: `${total.complete ? "" : "≈ "}${money(total.value)}` }));
    rows.append(row);
    if (!detail) continue;
    for (const holding of account.holdings) {
      const row = h("div", { class: "int-row portfolio-row" }, h("span", { class: "int-name", text: holding.symbol }),
        h("span", { class: "portfolio-amount", text: new Intl.NumberFormat(language(), { maximumFractionDigits: 8 }).format(holding.amount) }),
        h("span", { class: "portfolio-value", text: money(holding.priceUsd == null ? null : holding.priceUsd * holding.amount) }));
      if (holding.change != null) row.append(h("small", { class: "portfolio-change", style: `color:${holding.change >= 0 ? "#22C55E" : "#F4505E"}`, text: `${holding.change > 0 ? "+" : ""}${holding.change.toFixed(1)}%` }));
      // Always there, so the rows end at the same place (the Mac's 36 × 14 curve).
      const chart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      chart.setAttribute("viewBox", "-1 -1 38 16"); chart.setAttribute("width", "38"); chart.setAttribute("height", "16");
      const points = sparklinePoints(holding.history, 36, 14);
      if (points) {
        chart.setAttribute("role", "img"); chart.setAttribute("aria-label", `${holding.symbol} · ${t("History")}`);
        const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
        line.setAttribute("points", points); line.setAttribute("fill", "none"); line.setAttribute("stroke", "#FFD700"); line.setAttribute("stroke-width", "1.2");
        chart.append(line);
      } else chart.setAttribute("aria-hidden", "true");
      row.append(chart);
      rows.append(row);
    }
  }
  const summary = h("div", { class: "int-status", text: `${portfolio.complete ? t("Total") : t("Partial total")} · ${money(portfolio.totalUsd)}` });
  // At the end of the list: the summary line above already says the total is partial.
  const errors = h("div", { class: "int-status portfolio-status", role: "status" });
  if (portfolio.unpriced) errors.append(h("div", { text: t("Unpriced assets: {n}", { n: portfolio.unpriced }) }));
  if (portfolio.failed) errors.append(h("div", { text: t("Failed accounts: {n}", { n: portfolio.failed }) }));
  if (portfolio.priceError) errors.append(h("div", { text: portfolio.priceError }));
  rows.append(errors);
  return h("div", { class: "int-card portfolio-card" }, h("div", { class: "int-head" }, h("b", { text: "Portfolio" })), summary, rows,
    h("div", { class: "int-actions" }, h("button", { class: "link-btn", text: detail ? t("Back") : t("Details"), onclick: toggleDetail }),
      h("button", { class: "link-btn", text: t("Refresh"), onclick: () => void Bridge.refreshIntegration("integration_portfolio") }),
      h("button", { class: "link-btn", text: t("Settings…"), onclick: openSettings })));
}
