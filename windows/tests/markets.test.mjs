import test from "node:test";
import assert from "node:assert/strict";
import { readQuotes, sparklinePoints } from "../src/core/markets.ts";
import { cryptoCard } from "../src/views/markets.ts";
import { installFakeDom } from "./fakedom.mjs";

installFakeDom();

test("missing or invalid prices stay unknown instead of appearing as zero", () => {
  const quotes = readQuotes({ quotes: [
    { symbol: "BTC", currency: "USD", price: NaN, change: Infinity, history: [1, NaN, 2, -1], error: "HTTP 503" },
    { symbol: "ETH", currency: "EUR", price: 25, change: -1, history: [] },
    null,
  ] });
  assert.equal(quotes[0].price, null);
  assert.equal(quotes[0].change, null);
  assert.equal(quotes[0].error, "HTTP 503");
  assert.deepEqual(quotes[0].history, [1, 2]);
  assert.equal(quotes[1].price, 25);
});

test("flat and rising histories produce finite chart coordinates", () => {
  assert.equal(sparklinePoints([5, 5]), "0.0,12.0 72.0,12.0");
  assert.equal(sparklinePoints([1, 2, 3]), "0.0,24.0 36.0,12.0 72.0,0.0");
  assert.equal(sparklinePoints([1]), "");
  assert.equal(sparklinePoints([1, NaN]), "");
});

test("the card identifies Tether quotes and preserves source failures", () => {
  const card = cryptoCard({ exchange: "okx", quotes: [
    { symbol: "BTC", currency: "USDT", price: 100, change: 5, history: [95, 100] },
    { symbol: "BAD", currency: "USDT", price: null, error: "HTTP 404" },
  ] }, () => {});
  assert.match(card.textContent, /USDT/);
  assert.match(card.textContent, /HTTP 404/);
  assert.match(card.textContent, /OKX/);
  assert.doesNotMatch(card.textContent, /NaN|undefined/);
});
