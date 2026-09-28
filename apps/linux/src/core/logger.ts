export type LogCategory = "hook" | "socket" | "window" | "error";

const RATE_LIMIT_MS = 2000;
const lastLogged = new Map<string, number>();

function isDev(): boolean {
  const meta = import.meta as { env?: { DEV?: boolean } };
  return meta.env?.DEV === true;
}

function shouldLog(key: string): boolean {
  const now = Date.now();
  const prev = lastLogged.get(key);
  if (prev !== undefined && now - prev < RATE_LIMIT_MS) {
    return false;
  }
  lastLogged.set(key, now);
  return true;
}

function prefix(category: LogCategory): string {
  return `[coucou:${category}]`;
}

export const logger = {
  hook(message: string, ...args: unknown[]): void {
    if (!isDev()) return;
    const key = `hook:${message}`;
    if (!shouldLog(key)) return;
    console.debug(prefix("hook"), message, ...args);
  },

  socket(message: string, ...args: unknown[]): void {
    if (!isDev()) return;
    const key = `socket:${message}`;
    if (!shouldLog(key)) return;
    console.debug(prefix("socket"), message, ...args);
  },

  window(message: string, ...args: unknown[]): void {
    if (!isDev()) return;
    const key = `window:${message}`;
    if (!shouldLog(key)) return;
    console.debug(prefix("window"), message, ...args);
  },

  error(message: string, ...args: unknown[]): void {
    if (!isDev()) return;
    console.error(prefix("error"), message, ...args);
  },

  /** Log once per unique key regardless of rate window (errors worth repeating). */
  errorOnce(key: string, message: string, ...args: unknown[]): void {
    if (!isDev()) return;
    const full = `error-once:${key}`;
    if (!shouldLog(full)) return;
    console.error(prefix("error"), message, ...args);
  },
};
