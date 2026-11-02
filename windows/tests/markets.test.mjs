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

test("each coin stays one line in a list that scrolls above the card's actions", () => {
  const card = cryptoCard({ quotes: [
    { symbol: "BTC", currency: "USD", price: 78000, change: 0.6, history: [77000, 78000] },
    { symbol: "ETH", currency: "USD", price: 2270, change: 0.5, history: [2260, 2270], error: "History: HTTP 503" },
    { symbol: "ZZZQX", currency: "USD", price: null, error: "HTTP 404" },
  ] }, () => {});
  const rows = card.querySelector(".crypto-rows");
  assert.ok(rows, "the coins have their own scrolling list");
  assert.equal(card.querySelector(".int-actions").parentNode, card, "Refresh and Settings… stay outside the list");
  assert.equal(rows.find(".int-actions").length, 0);
  const coins = rows.children;
  assert.deepEqual(coins.map((row) => row.querySelector(".int-name").textContent), ["BTC", "ETH", "ZZZQX"]);
  for (const row of coins) {
    assert.ok(row.classList.contains("crypto-row"));
    const kids = row.children;
    const at = (cls) => kids.findIndex((el) => el.classList.contains(cls));
    assert.equal(at("int-name"), 0, "the symbol starts the row");
    assert.ok(at("crypto-price") > 0 && at("crypto-change") === at("crypto-price") + 1, "then the price and the change");
    assert.equal(kids.at(-1).tagName, "SVG", "the sparkline sits at the end of the row");
    for (const el of [row, ...row.walk()]) assert.doesNotMatch(el.getAttribute("style") ?? "", /flex-wrap|flex-basis/);
  }
  const error = coins[2].querySelector(".crypto-error");
  assert.equal(error.textContent, "HTTP 404");
  assert.equal(error.getAttribute("title"), "HTTP 404");
  assert.equal(coins[1].querySelector(".crypto-change").textContent, "+0.50%", "a history failure keeps the change");
  assert.equal(coins[1].querySelector(".crypto-error").textContent, "History: HTTP 503");
});
