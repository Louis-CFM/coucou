import { h } from "./dom";
import { Bridge } from "../core/bridge";
import { readQuotes, sparklinePoints } from "../core/markets";
import { language, t } from "../i18n/i18n";

export function cryptoCard(data: Record<string, unknown>, openSettings: () => void): HTMLElement {
  const rows = h("div", { class: "int-rows" });
  for (const quote of readQuotes(data)) {
    const color = quote.change == null ? "#8e939c" : quote.change >= 0 ? "#22C55E" : "#F4505E";
    const price = quote.price == null ? "—" : ["USD", "EUR"].includes(quote.currency)
      ? new Intl.NumberFormat(language(), { style: "currency", currency: quote.currency, maximumFractionDigits: quote.price < 1 ? 6 : 2 }).format(quote.price)
      : `${new Intl.NumberFormat(language(), { maximumFractionDigits: 6 }).format(quote.price)} ${quote.currency}`;
    const row = h("div", { class: "int-row", style: "flex-wrap:wrap", title: quote.fetchedAt ? new Date(quote.fetchedAt).toLocaleString(language()) : "" },
      h("b", { class: "int-name", text: quote.symbol }), h("span", { text: price }),
      h("span", { style: `color:${color}`, text: quote.change == null ? "—" : `${quote.change > 0 ? "+" : ""}${quote.change.toFixed(2)}%` }));
    const points = sparklinePoints(quote.history);
    if (points) {
      const chart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      chart.setAttribute("viewBox", "-1 -1 74 26"); chart.setAttribute("width", "72"); chart.setAttribute("height", "24");
      chart.setAttribute("role", "img"); chart.setAttribute("aria-label", `${quote.symbol} · ${t("History")}`);
      const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
      line.setAttribute("points", points); line.setAttribute("fill", "none"); line.setAttribute("stroke", color); line.setAttribute("stroke-width", "1.5");
      chart.append(line); row.append(chart);
    }
    if (quote.error) row.append(h("small", { style: "flex-basis:100%;color:#F4505E", text: quote.error }));
    rows.append(row);
  }
  if (!rows.childNodes.length) rows.append(h("div", { class: "int-status", text: t("Add coins in Settings → Integrations") }));
  return h("div", { class: "int-card" }, h("div", { class: "int-head" }, h("b", { text: "Crypto" }),
    h("span", { text: data.exchange === "okx" ? "OKX" : "Coinbase" })), rows,
    h("div", { class: "int-actions" }, h("button", { class: "link-btn", text: t("Refresh"), onclick: () => void Bridge.refreshIntegration("integration_crypto") }),
      h("button", { class: "link-btn", text: t("Settings…"), onclick: openSettings })));
}
