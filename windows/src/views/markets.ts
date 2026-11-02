import { h } from "./dom";
import { Bridge } from "../core/bridge";
import { readQuotes, sparklinePoints } from "../core/markets";
import { language, t } from "../i18n/i18n";

export function cryptoCard(data: Record<string, unknown>, openSettings: () => void): HTMLElement {
  const rows = h("div", { class: "int-rows crypto-rows" });
  for (const quote of readQuotes(data)) {
    const color = quote.change == null ? "#8e939c" : quote.change >= 0 ? "#22C55E" : "#F4505E";
    const price = quote.price == null ? "—" : ["USD", "EUR"].includes(quote.currency)
      ? new Intl.NumberFormat(language(), { style: "currency", currency: quote.currency, maximumFractionDigits: quote.price < 1 ? 6 : 2 }).format(quote.price)
      : `${new Intl.NumberFormat(language(), { maximumFractionDigits: 6 }).format(quote.price)} ${quote.currency}`;
    const row = h("div", { class: "int-row crypto-row", title: quote.fetchedAt ? new Date(quote.fetchedAt).toLocaleString(language()) : "" },
      h("b", { class: "int-name", text: quote.symbol }));
    // Beside the symbol, so every row's numbers stay aligned; it shrinks to the room left and its tooltip has it all.
    if (quote.error) row.append(h("span", { class: "crypto-error", title: quote.error, text: quote.error }));
    row.append(h("span", { class: "crypto-price", text: price }),
      h("span", { class: "crypto-change", style: `color:${color}`, text: quote.change == null ? "—" : `${quote.change > 0 ? "+" : ""}${quote.change.toFixed(2)}%` }));
    // Always there, so every row's numbers end at the same place (the Mac's 30 × 12 curve).
    const chart = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    chart.setAttribute("viewBox", "-1 -1 32 14"); chart.setAttribute("width", "32"); chart.setAttribute("height", "14");
    const points = sparklinePoints(quote.history, 30, 12);
    if (points) {
      chart.setAttribute("role", "img"); chart.setAttribute("aria-label", `${quote.symbol} · ${t("History")}`);
      const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
      line.setAttribute("points", points); line.setAttribute("fill", "none"); line.setAttribute("stroke", color); line.setAttribute("stroke-width", "1.2");
      chart.append(line);
    } else chart.setAttribute("aria-hidden", "true");
    row.append(chart);
    rows.append(row);
  }
  if (!rows.childNodes.length) rows.append(h("div", { class: "int-status", text: t("Add coins in Settings → Integrations") }));
  return h("div", { class: "int-card crypto-card" }, h("div", { class: "int-head" }, h("b", { text: "Crypto" }),
    h("span", { text: data.exchange === "okx" ? "OKX" : "Coinbase" })), rows,
    h("div", { class: "int-actions" }, h("button", { class: "link-btn", text: t("Refresh"), onclick: () => void Bridge.refreshIntegration("integration_crypto") }),
      h("button", { class: "link-btn", text: t("Settings…"), onclick: openSettings })));
}
