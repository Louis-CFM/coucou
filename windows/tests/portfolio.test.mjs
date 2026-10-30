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
