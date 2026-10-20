// The Crypto pill on the page: what src-tauri/src/crypto.rs reports, and the
// formatting rules of CryptoController.swift.

import { language } from "../i18n/i18n";

export const CRYPTO_ID = "integration_crypto";
export const CRYPTO_ORANGE = "#F7931A";

export type CryptoExchange = "coinbase" | "okx";

export interface CryptoPrefs {
  exchange: CryptoExchange;
  /** "EUR" or "USD". */
  currency: string;
  /** As typed: "BTC, ETH, SOL". */
  coins: string;
  alertEnabled: boolean;
  alertPercent: number;
}

export interface CryptoQuote {
  symbol: string;
  price: number;
  open24h: number;
  /** Hourly closes over the last 24 h, oldest first. */
  spark: number[];
}

export interface CryptoState {
  prefs: CryptoPrefs;
  exchangeName: string;
  quotes: CryptoQuote[];
  missing: string[];
  loaded: boolean;
  alertSymbol: string | null;
}

export const IDLE_CRYPTO: CryptoState = {
  prefs: { exchange: "coinbase", currency: "EUR", coins: "BTC, ETH, SOL", alertEnabled: false, alertPercent: 5 },
  exchangeName: "Coinbase",
  quotes: [],
  missing: [],
  loaded: false,
  alertSymbol: null,
};

export const Crypto = {
  state: { ...IDLE_CRYPTO } as CryptoState,
};

/** "btc, Eth;sol" → ["BTC", "ETH", "SOL"] (CryptoSettings.parseCoins). */
export function parseCoins(raw: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const w of raw.toUpperCase().split(/[^\p{L}\p{N}]+/u)) {
    if (!w || Array.from(w).length > 10 || seen.has(w)) continue;
    seen.add(w);
    out.push(w);
    if (out.length === 8) break;
  }
  return out;
}

/** Change over 24 h, in percent. */
export function change(q: CryptoQuote): number {
  return q.open24h > 0 ? ((q.price - q.open24h) / q.open24h) * 100 : 0;
}

/** "62 140 €", "3 120,55 €", "0,4312 $" in the user's language. */
export function formatPrice(value: number, currency: string, lang: string = language()): string {
  const digits = value >= 1000 ? 0 : value >= 1 ? 2 : 4;
  try {
    return new Intl.NumberFormat(lang, {
      style: "currency", currency, minimumFractionDigits: digits, maximumFractionDigits: digits,
    }).format(value);
  } catch {
    return value.toFixed(2);
  }
}

/** "+1.23 %", "−0.40 %". */
export function formatChange(pct: number): string {
  return `${pct >= 0 ? "+" : "−"}${Math.abs(pct).toFixed(2)} %`;
}

/** The coin of the last alert first, then the others in their order. */
export function ordered(s: CryptoState): CryptoQuote[] {
  const i = s.alertSymbol ? s.quotes.findIndex((q) => q.symbol === s.alertSymbol) : -1;
  if (i <= 0) return s.quotes;
  const q = [...s.quotes];
  q.unshift(...q.splice(i, 1));
  return q;
}

/** The sparkline's SVG path in a w×h box (CryptoSparkline). Empty below two points. */
export function sparkPath(values: number[], w: number, h: number): string {
  if (values.length < 2) return "";
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  const span = Math.max(hi - lo, hi * 0.0001);
  return values
    .map((v, i) => {
      const x = (w * i) / (values.length - 1);
      const y = h * (1 - (v - lo) / span);
      return `${i === 0 ? "M" : "L"}${x.toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(" ");
}
