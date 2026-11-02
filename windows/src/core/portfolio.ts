export interface PortfolioWallet { kind: string; address: string; label: string }
export interface PortfolioSettings { wallets: PortfolioWallet[]; exchanges: Record<string, boolean>; networks: Record<string, string> }
export interface PortfolioCredentials { key: string; secret: string; passphrase: string }
export interface Holding { symbol: string; amount: number; priceUsd: number | null; change: number | null; history: number[] }
export interface PortfolioAccount { id: string; label: string; network: string; holdings: Holding[]; fetchedAt: number; error: string | null }
export interface PortfolioSnapshot { accounts: PortfolioAccount[]; totalUsd: number | null; unpriced: number; failed: number; complete: boolean; priceError: string | null }

export const EXCHANGE_NAMES: Record<string, string> = { binance: "Binance", okx: "OKX", bybit: "Bybit", kraken: "Kraken", coinbase: "Coinbase" };

const finite = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);

export function readPortfolio(data: Record<string, unknown>): PortfolioSnapshot {
  const accounts: PortfolioAccount[] = [];
  let malformed = 0;
  for (const a of Array.isArray(data.accounts) ? data.accounts : []) {
    if (!a || typeof a.id !== "string" || typeof a.label !== "string" || typeof a.network !== "string") { malformed++; continue; }
    const holdings: Holding[] = [];
    for (const raw of Array.isArray(a.holdings) ? a.holdings : []) {
      if (!raw || typeof raw.symbol !== "string" || !finite(raw.amount)) { malformed++; continue; }
      holdings.push({ symbol: raw.symbol, amount: raw.amount,
        priceUsd: finite(raw.priceUsd) && raw.priceUsd > 0 ? raw.priceUsd : null,
        change: finite(raw.change) ? raw.change : null,
        history: Array.isArray(raw.history) ? raw.history.filter((n: unknown) => finite(n) && n > 0).slice(-7) : [] });
    }
    accounts.push({ id: a.id, label: a.label, network: a.network, holdings, fetchedAt: finite(a.fetchedAt) ? a.fetchedAt : 0, error: typeof a.error === "string" ? a.error : null });
  }
  return { accounts, totalUsd: finite(data.totalUsd) ? data.totalUsd : null,
    unpriced: finite(data.unpriced) ? Math.max(0, data.unpriced) + malformed : malformed,
    failed: finite(data.failed) ? Math.max(0, data.failed) : 0,
    complete: data.complete === true && malformed === 0,
    priceError: typeof data.priceError === "string" ? data.priceError : null };
}

export function accountValue(account: PortfolioAccount): { value: number | null; complete: boolean } {
  if (account.error) return { value: null, complete: false };
  let value = 0, priced = 0, missing = 0;
  for (const holding of account.holdings.filter((h) => h.amount !== 0)) {
    const amount = holding.priceUsd == null ? NaN : holding.priceUsd * holding.amount;
    if (Number.isFinite(amount)) { value += amount; priced++; } else missing++;
  }
  return { value: Number.isFinite(value) && (priced > 0 || missing === 0) ? value : null, complete: missing === 0 && Number.isFinite(value) };
}
