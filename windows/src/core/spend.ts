// What each model takes of the Claude plan — the ledger behind the "By model"
// rows of the plan card (views/usage.ts). No DOM, so it can be tested on its own.
//
// Claude Code's status line carries, with every update, the session's model
// and `cost.total_cost_usd`: its own running estimate of the session at list
// price, since the session started, back to $0 after /clear. The relay forwards
// both (`model`, `cost_usd`). The plan limits themselves are not split by
// model, so this is the share each model takes, not a limit: the deltas of
// every session's total are added to the day, under the model the session was
// on when the total moved.

export interface SpendEntry {
  /** The model's id, e.g. `claude-opus-5-5`. */
  id: string;
  /** Its display name as Claude Code gives it, e.g. `Opus`; the id without one. */
  name: string;
  usd: number;
}

export interface SpendLedger {
  /** Local day (`YYYY-MM-DD`) → model id → dollars added that day. */
  days: Record<string, Record<string, number>>;
  /** Model id → display name last seen. */
  names: Record<string, string>;
  /** Session id → the last total seen, the model then, and when (epoch ms). */
  sessions: Record<string, { model: string; total: number; at: number }>;
}

/** Days kept: today and the six before make the week; one more absorbs midnight. */
const KEEP_DAYS = 8;
/** A session not heard from for this long is forgotten (its total would start over anyway). */
const SESSION_TTL_MS = 24 * 3_600_000;
const MAX_SESSIONS = 200;

export function emptyLedger(): SpendLedger {
  return { days: {}, names: {}, sessions: {} };
}

/** `YYYY-MM-DD` in local time. */
export function dayKey(now: number): string {
  const d = new Date(now);
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return `${d.getFullYear()}-${mm}-${dd}`;
}

/**
 * A status line update: the session's model and its running total. Returns
 * true when the ledger changed. A total below the last one seen is a session
 * started over (/clear), counted from zero; a session seen for the first time
 * brings its whole total, which is right after a restart of Claude Code and
 * slightly generous when Coucou itself was restarted mid-session.
 */
export function noteSpend(
  ledger: SpendLedger,
  sessionId: string,
  modelId: string,
  modelName: string | undefined,
  totalUsd: number,
  now = Date.now(),
): boolean {
  if (!sessionId || !modelId || !Number.isFinite(totalUsd) || totalUsd < 0) return false;
  const last = ledger.sessions[sessionId];
  // Kept to a hundredth of a cent: the totals are sums of many small deltas.
  const delta = cents(last && totalUsd >= last.total ? totalUsd - last.total : totalUsd);
  let changed = false;
  if (delta > 0) {
    const day = dayKey(now);
    const models = (ledger.days[day] ??= {});
    models[modelId] = cents((models[modelId] ?? 0) + delta);
    changed = true;
  }
  const name = modelName?.trim() || modelId;
  if (ledger.names[modelId] !== name) {
    ledger.names[modelId] = name;
    changed = true;
  }
  ledger.sessions[sessionId] = { model: modelId, total: totalUsd, at: now };
  prune(ledger, now);
  return changed;
}

/** Rounded to a hundredth of a cent, so sums of deltas stay exact dollars. */
function cents(usd: number): number {
  return Math.round(usd * 10_000) / 10_000;
}

function prune(ledger: SpendLedger, now: number) {
  const oldest = dayKey(now - (KEEP_DAYS - 1) * 86_400_000);
  for (const day of Object.keys(ledger.days)) {
    if (day < oldest) delete ledger.days[day];
  }
  const sessions = Object.entries(ledger.sessions).filter(([, s]) => now - s.at < SESSION_TTL_MS);
  sessions.sort((a, b) => b[1].at - a[1].at);
  ledger.sessions = Object.fromEntries(sessions.slice(0, MAX_SESSIONS));
}

/** Dollars per model over the last `days` local days, today included, biggest first. */
export function spendOver(ledger: SpendLedger, days: number, now = Date.now()): SpendEntry[] {
  const keys = new Set<string>();
  for (let i = 0; i < days; i++) keys.add(dayKey(now - i * 86_400_000));
  const totals: Record<string, number> = {};
  for (const [day, models] of Object.entries(ledger.days)) {
    if (!keys.has(day)) continue;
    for (const [id, usd] of Object.entries(models)) totals[id] = (totals[id] ?? 0) + usd;
  }
  return Object.entries(totals)
    .filter(([, usd]) => usd > 0)
    .map(([id, usd]) => ({ id, name: ledger.names[id] ?? id, usd: cents(usd) }))
    .sort((a, b) => b.usd - a.usd);
}

/** A stored ledger, if it still looks like one; empty otherwise. */
export function restoreLedger(raw: string | null): SpendLedger {
  const ledger = emptyLedger();
  if (!raw) return ledger;
  try {
    const v = JSON.parse(raw) as Partial<SpendLedger> | null;
    if (!v || typeof v !== "object") return ledger;
    for (const [day, models] of Object.entries(v.days ?? {})) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || !models || typeof models !== "object") continue;
      const clean: Record<string, number> = {};
      for (const [id, usd] of Object.entries(models)) {
        if (typeof usd === "number" && Number.isFinite(usd) && usd >= 0) clean[id] = usd;
      }
      ledger.days[day] = clean;
    }
    for (const [id, name] of Object.entries(v.names ?? {})) {
      if (typeof name === "string" && name) ledger.names[id] = name;
    }
    for (const [sid, s] of Object.entries(v.sessions ?? {})) {
      if (s && typeof s.model === "string" && Number.isFinite(s.total) && Number.isFinite(s.at)) {
        ledger.sessions[sid] = { model: s.model, total: s.total, at: s.at };
      }
    }
  } catch {
    // Not ours, or damaged: start again.
  }
  return ledger;
}
