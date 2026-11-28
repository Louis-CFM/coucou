/**
 * brain recurrences — detect recurring patterns in conversation history.
 *
 * (a) Conversation groups: conversations with similar normalized title, count ≥ 5.
 *     Includes avg frequency in days + 10-week histogram.
 *
 * (b) Repeated errors: ❌/⚠️ lessons from LLM state files that appear ≥ 2 times.
 *
 * (c) Artifact counts: element counts by kind from LLM state files.
 *
 * No LLM. Pure data aggregation from rawindex + state files.
 */
import fs from "node:fs";
import path from "node:path";
import { expandHome } from "./utils.js";
import type { BrainConfig } from "./config.js";
import { getAllConversations } from "./rawindex.js";
import type { StoredElement } from "./elements.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface RecurrenceGroupe {
  titre: string;
  count: number;
  /** Average days between occurrences (null if only 1 date) */
  freqJours: number | null;
  /** Count per week for the last 10 weeks (index 0 = oldest, 9 = current) */
  histogram: number[];
}

export interface RecurrenceErreur {
  texte: string;
  statut: "❌" | "⚠️";
  count: number;
  derniereDate: string;
}

export interface RecurrencesData {
  groupes: RecurrenceGroupe[];
  erreurs: RecurrenceErreur[];
  artifacts: { kind: string; count: number }[];
}

// ── Title normalization ────────────────────────────────────────────────────────

function normalizeTitle(title: string): string {
  return title
    .toLowerCase()
    // Remove common Claude auto-generated prefixes
    .replace(/^(help me |aide.?moi |how to |comment |fix |debug |why |why does |créer |create |build |implement |add )/i, "")
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 60);
}

// ── Histogram ─────────────────────────────────────────────────────────────────

function computeHistogram(dates: string[], weeks = 10): number[] {
  const histogram = new Array<number>(weeks).fill(0);
  const now = Date.now();
  const weekMs = 7 * 24 * 60 * 60 * 1000;

  for (const date of dates) {
    const ms = new Date(date).getTime();
    if (isNaN(ms)) continue;
    const weeksAgo = Math.floor((now - ms) / weekMs);
    if (weeksAgo >= 0 && weeksAgo < weeks) {
      histogram[weeks - 1 - weeksAgo]++;
    }
  }

  return histogram;
}

// ── Main function ─────────────────────────────────────────────────────────────

export function computeRecurrences(config: BrainConfig): RecurrencesData {
  // ── (a) Conversation groups ───────────────────────────────────────────────
  const convs = getAllConversations(config);

  // Group by normalized title
  const byTitle = new Map<string, { original: string; dates: string[] }>();
  for (const conv of convs) {
    const norm = normalizeTitle(conv.convTitle);
    if (!norm || norm.length < 5) continue; // skip empty / very short titles
    const existing = byTitle.get(norm);
    if (existing) {
      existing.dates.push(conv.convDate);
    } else {
      byTitle.set(norm, { original: conv.convTitle, dates: [conv.convDate] });
    }
  }

  const groupes: RecurrenceGroupe[] = [];
  for (const [, group] of byTitle) {
    if (group.dates.length < 5) continue;

    const sorted = [...group.dates].sort();
    const count = sorted.length;

    let freqJours: number | null = null;
    if (count >= 2) {
      const firstMs = new Date(sorted[0]!).getTime();
      const lastMs = new Date(sorted[count - 1]!).getTime();
      const rangeMs = lastMs - firstMs;
      if (rangeMs > 0) {
        freqJours = rangeMs / (1000 * 60 * 60 * 24) / (count - 1);
      }
    }

    groupes.push({
      titre: group.original,
      count,
      freqJours: freqJours !== null ? Math.round(freqJours * 10) / 10 : null,
      histogram: computeHistogram(group.dates),
    });
  }

  // Sort by count descending
  groupes.sort((a, b) => b.count - a.count);

  // ── (b) Repeated errors + (c) Artifact counts ─────────────────────────────
  const stateDir = path.join(expandHome(config.brainPath), ".state", "proj");
  const erreurs: RecurrenceErreur[] = [];
  const artifactCounts = new Map<string, number>();

  if (fs.existsSync(stateDir)) {
    // Collect all ❌/⚠️ elements across all projects
    const errorMap = new Map<
      string,
      { texte: string; statut: "❌" | "⚠️"; count: number; derniereDate: string }
    >();

    for (const file of fs.readdirSync(stateDir)) {
      if (!file.endsWith(".json")) continue;
      try {
        const raw = fs.readFileSync(path.join(stateDir, file), "utf8");
        const state: { elements: StoredElement[] } = JSON.parse(raw);

        for (const elem of state.elements) {
          // Count artifacts by kind
          artifactCounts.set(elem.kind, (artifactCounts.get(elem.kind) ?? 0) + 1);

          // Collect errors
          if (elem.statut === "❌" || elem.statut === "⚠️") {
            const key = elem.texte.slice(0, 80).toLowerCase().trim();
            const existing = errorMap.get(key);
            if (existing) {
              existing.count++;
              if (elem.date > existing.derniereDate) {
                existing.derniereDate = elem.date;
              }
            } else {
              errorMap.set(key, {
                texte: elem.texte,
                statut: elem.statut as "❌" | "⚠️",
                count: 1,
                derniereDate: elem.date,
              });
            }
          }
        }
      } catch {
        // skip unreadable state files
      }
    }

    // Keep only errors seen ≥ 2 times
    for (const err of errorMap.values()) {
      if (err.count >= 2) {
        erreurs.push(err);
      }
    }
    erreurs.sort((a, b) => b.count - a.count);
  }

  const artifacts = [...artifactCounts.entries()]
    .map(([kind, count]) => ({ kind, count }))
    .sort((a, b) => b.count - a.count);

  return { groupes, erreurs, artifacts };
}
