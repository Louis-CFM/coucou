// The Portfolio pill on the page: what src-tauri/src/portfolio.rs reports, and
// the formatting rules of PortfolioController.swift.

export const PORTFOLIO_ID = "integration_portfolio";
export const PORTFOLIO_GOLD = "#FFD700";

export type ExchangeKind = "binance" | "okx" | "bybit" | "kraken" | "coinbase";
export type WalletKind =
  | "bitcoin" | "dogecoin" | "litecoin"
  | "ethereum" | "polygon" | "bnbChain" | "avalanche" | "arbitrum" | "optimism" | "base"
  | "solana" | "tron" | "xrp" | "cardano" | "cosmos" | "near";

export const EXCHANGES: { id: ExchangeKind; name: string; passphrase: boolean }[] = [
  { id: "binance", name: "Binance", passphrase: false },
  { id: "okx", name: "OKX", passphrase: true },
  { id: "bybit", name: "Bybit", passphrase: false },
  { id: "kraken", name: "Kraken", passphrase: false },
  { id: "coinbase", name: "Coinbase", passphrase: false },
];

export const WALLETS: { id: WalletKind; name: string; placeholder: string }[] = [
  { id: "bitcoin", name: "Bitcoin", placeholder: "bc1q… / 1… / 3…" },
  { id: "dogecoin", name: "Dogecoin", placeholder: "D…" },
  { id: "litecoin", name: "Litecoin", placeholder: "ltc1… / L… / M…" },
  { id: "ethereum", name: "Ethereum", placeholder: "0x…" },
  { id: "polygon", name: "Polygon", placeholder: "0x…" },
  { id: "bnbChain", name: "BNB Chain", placeholder: "0x…" },
  { id: "avalanche", name: "Avalanche", placeholder: "0x…" },
  { id: "arbitrum", name: "Arbitrum", placeholder: "0x…" },
  { id: "optimism", name: "Optimism", placeholder: "0x…" },
  { id: "base", name: "Base", placeholder: "0x…" },
  { id: "solana", name: "Solana", placeholder: "base58" },
  { id: "tron", name: "TRON", placeholder: "T…" },
  { id: "xrp", name: "XRP Ledger", placeholder: "r…" },
  { id: "cardano", name: "Cardano", placeholder: "addr1…" },
  { id: "cosmos", name: "Cosmos", placeholder: "cosmos1…" },
  { id: "near", name: "NEAR", placeholder: "alice.near" },
];

export interface Holding {
  symbol: string;
  amount: number;
  /** USD. */
  price: number;
  change24h: number | null;
  /** 7 daily closes, oldest first. */
  priceHistory: number[];
}

export interface Wallet {
  kind: WalletKind;
  address: string;
  label: string;
}

export type AccountSource =
  | { kind: "exchange"; exchange: ExchangeKind; name: string }
  | { kind: "wallet"; wallet: Wallet; network: string };

export interface Account {
  id: string;
  source: AccountSource;
  holdings: Holding[];
  fetchError: string | null;
}

export interface PortfolioState {
  accounts: Account[];
  loaded: boolean;
  exchanges: ExchangeKind[];
  wallets: Wallet[];
}

export const Portfolio = {
  state: { accounts: [], loaded: false, exchanges: [], wallets: [] } as PortfolioState,
};

export function accountValue(a: Account): number {
  return a.holdings.reduce((n, h) => n + h.amount * h.price, 0);
}

export function accountLabel(a: Account): string {
  return a.source.kind === "exchange" ? a.source.name : a.source.wallet.label;
}

/** "$62,140", "$3,120.55", "$0.4312". */
export function formatValue(usd: number, lang?: string): string {
  const max = usd >= 1000 ? 0 : usd >= 1 ? 2 : 4;
  try {
    return new Intl.NumberFormat(lang ?? "en-US", { style: "currency", currency: "USD", minimumFractionDigits: 0, maximumFractionDigits: max }).format(usd);
  } catch {
    return `$${usd.toFixed(2)}`;
  }
}

/** "0", "1250", "0.4312", "0.00012345". */
export function formatAmount(amount: number): string {
  if (amount === 0) return "0";
  if (amount >= 1000) return amount.toFixed(0);
  if (amount >= 1) return amount.toFixed(4);
  return amount.toFixed(8);
}

/** "+2.1%", "-0.4%". */
export function formatChange(pct: number): string {
  return `${pct >= 0 ? "+" : ""}${pct.toFixed(1)}%`;
}

/** "bc1qar0s…zwf5mdq": long addresses cut in the middle. */
export function shortAddress(a: string): string {
  return a.length > 16 ? `${a.slice(0, 8)}…${a.slice(-6)}` : a;
}

/** Sparkline path in a w×h box (SparklineView). */
export function historyPath(prices: number[], w: number, h: number): string {
  if (prices.length < 2) return "";
  const mn = Math.min(...prices);
  const mx = Math.max(...prices);
  const range = mx - mn === 0 ? 1 : mx - mn;
  return prices
    .map((p, i) => `${i === 0 ? "M" : "L"}${((w * i) / (prices.length - 1)).toFixed(2)} ${(h - (h * (p - mn)) / range).toFixed(2)}`)
    .join(" ");
}
