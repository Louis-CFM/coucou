import test from "node:test";
import assert from "node:assert/strict";
import { accountValue, readPortfolio } from "../src/core/portfolio.ts";
import { portfolioCard } from "../src/views/portfolio.ts";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

test("unknown prices and account failures cannot be presented as a complete balance", () => {
  const a = { id: "a", label: "a", network: "Ethereum", error: null, holdings: [
    { symbol: "ETH", amount: 2, priceUsd: null },
    { symbol: "BTC", amount: 1, priceUsd: 100 },
  ] };
  assert.deepEqual(accountValue(a), { value: 100, complete: false });
  assert.deepEqual(accountValue({ ...a, error: "HTTP 503" }), { value: null, complete: false });
  assert.deepEqual(accountValue({ ...a, holdings: [{ symbol: "ETH", amount: 2, priceUsd: null }] }), { value: null, complete: false });
  assert.deepEqual(accountValue({ ...a, holdings: [{ symbol: "USD", amount: -2, priceUsd: 1 }] }), { value: -2, complete: true });
  assert.deepEqual(accountValue({ ...a, holdings: [] }), { value: 0, complete: true });
});

test("malformed values make the snapshot partial and finite histories stay bounded", () => {
  const p = readPortfolio({ complete: true, totalUsd: Infinity, accounts: [
    { id: "a", label: "Account", network: "Base", holdings: [{ symbol: "ETH", amount: NaN }] },
  ] });
  assert.equal(p.complete, false);
  assert.equal(p.totalUsd, null);
  assert.equal(p.unpriced, 1);
});

test("the detail view names incomplete totals and shows the failing source", () => {
  const card = portfolioCard({ totalUsd: 100, complete: false, unpriced: 1, failed: 1, accounts: [
    { id: "binance", label: "binance", network: "binance", holdings: [{ symbol: "BTC", amount: 1, priceUsd: 100, history: [90, 100] }] },
    { id: "bad", label: "USB wallet", network: "Ethereum", error: "HTTP 503", holdings: [] },
  ] }, true, () => {}, () => {});
  assert.match(card.textContent, /Partial total/);
  assert.match(card.textContent, /Unpriced assets: 1/);
  assert.match(card.textContent, /Failed accounts: 1/);
  assert.match(card.textContent, /HTTP 503/);
  assert.match(card.textContent, /Binance/);
  assert.doesNotMatch(card.textContent, /NaN|undefined|Infinity/);
});

test("each account and asset stays one line in a list that scrolls between the total and the actions", () => {
  const data = { totalUsd: 100, complete: false, unpriced: 1, failed: 1, accounts: [
    { id: "binance", label: "binance", network: "binance", holdings: [
      { symbol: "BTC", amount: 1, priceUsd: 100, change: 2, history: [90, 100] },
      { symbol: "XYZ", amount: 5, priceUsd: null },
    ] },
    { id: "bad", label: "USB wallet", network: "Ethereum", error: "HTTP 503", holdings: [] },
  ] };
  for (const detail of [false, true]) {
    const card = portfolioCard(data, detail, () => {}, () => {});
    const rows = card.querySelector(".portfolio-rows");
    assert.ok(rows, "the rows have their own scrolling list");
    assert.equal(rows.getAttribute("style"), null, "the card bounds the list, not an inline height");
    const summary = card.children.find((el) => el.classList.contains("int-status") && /Partial total/.test(el.textContent));
    assert.ok(summary, "the partial total stays outside the list");
    assert.equal(card.querySelector(".int-actions").parentNode, card, "Details, Refresh and Settings… stay outside the list");
    const status = rows.children.at(-1);
    assert.ok(status.classList.contains("int-status"));
    assert.match(status.textContent, /Unpriced assets: 1/);
    assert.match(status.textContent, /Failed accounts: 1/);
    const lines = rows.children.slice(0, -1);
    assert.ok(lines.every((row) => row.classList.contains("portfolio-row")), "an account's error is on its row, not a line of its own");
    const failed = lines.find((row) => row.querySelector(".portfolio-error"));
    assert.equal(failed.querySelector(".portfolio-error").textContent, "HTTP 503");
    assert.equal(failed.querySelector(".portfolio-error").getAttribute("title"), "HTTP 503");
    assert.equal(failed.children.at(-1).classList.contains("portfolio-value"), true);
    const holdings = lines.filter((row) => row.querySelector(".portfolio-amount"));
    assert.equal(holdings.length, detail ? 2 : 0);
    for (const row of holdings) assert.equal(row.children.at(-1).tagName, "SVG", "the sparkline sits at the end of the row");
    if (detail) assert.equal(holdings[1].querySelector(".portfolio-value").textContent, "—", "an unpriced asset stays unknown");
  }
});
