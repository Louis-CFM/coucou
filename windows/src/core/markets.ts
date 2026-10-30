export interface MarketPrefs {
  exchange: "coinbase" | "okx";
  currency: "EUR" | "USD";
  coins: string[];
  alerts: boolean;
  alertPercent: number;
}

export interface Quote {
  symbol: string;
  currency: string;
  price: number | null;
  change: number | null;
  history: number[];
  fetchedAt: number;
  error: string | null;
}

const finite = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n);

export function readQuotes(data: Record<string, unknown>): Quote[] {
  if (!Array.isArray(data.quotes)) return [];
  return data.quotes.flatMap((raw) => {
    if (!raw || typeof raw !== "object" || typeof raw.symbol !== "string" || typeof raw.currency !== "string") return [];
    return [{ symbol: raw.symbol, currency: raw.currency,
      price: finite(raw.price) && raw.price > 0 ? raw.price : null,
      change: finite(raw.change) ? raw.change : null,
      history: Array.isArray(raw.history) ? raw.history.filter((n: unknown) => finite(n) && n > 0).slice(-24) : [],
      fetchedAt: finite(raw.fetchedAt) ? raw.fetchedAt : 0,
      error: typeof raw.error === "string" ? raw.error : null }];
  });
}

export function sparklinePoints(values: number[], width = 72, height = 24): string {
  if (values.length < 2 || values.some((v) => !Number.isFinite(v))) return "";
  const min = Math.min(...values), range = Math.max(...values) - min;
  return values.map((v, i) => `${(i * width / (values.length - 1)).toFixed(1)},${(range ? height - (v - min) / range * height : height / 2).toFixed(1)}`).join(" ");
}
