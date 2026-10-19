// How the computer is doing, as Rust reports it (src-tauri/src/vitals.rs) —
// the page's half of MachineVitals.swift and VitalsHoverLine.swift: the mood
// handed to Mochi's engines, and the line shown under the island while the
// pointer is on him ("CPU 94 % · node, Google Chrome").

import { t } from "../i18n/i18n";
import { CALM, type MochiMood } from "../mochi/mood";

export interface VitalsReport {
  busy: number;
  hot: number;
  full: number;
  tired: number;
  asleep: boolean;
  cpu: number;
  top: string[];
  battery: { percent: number; onPower: boolean } | null;
  woke: boolean;
}

export function moodOf(r: VitalsReport | null): MochiMood {
  if (!r) return CALM;
  return { busy: r.busy, hot: r.hot, full: r.full, tired: r.tired, asleep: r.asleep };
}

/** The words under the island, the most telling first (MachineVitals.describe). */
export function describeVitals(r: VitalsReport | null): string | null {
  if (!r) return null;
  const parts: string[] = [];
  if (r.busy > 0) {
    const pct = Math.round(r.cpu * 100);
    parts.push(r.top.length ? `CPU ${pct} % · ${r.top.slice(0, 2).join(", ")}` : `CPU ${pct} %`);
  }
  if (r.hot >= 0.8) parts.push(t("Your computer is hot"));
  else if (r.hot > 0) parts.push(t("Your computer is warm"));
  if (r.full >= 1) parts.push(t("Memory is full"));
  else if (r.full > 0) parts.push(t("Memory is short"));
  if (r.battery && (r.tired > 0 || r.asleep)) parts.push(t("Battery {0} %", { 0: r.battery.percent }));
  return parts.length ? parts.slice(0, 2).join(" · ") : null;
}

/** The dot's colour in the hover line: what matters most. */
export function vitalsDot(r: VitalsReport): string {
  if (r.hot > 0) return "#FF6B4A";
  if (r.busy > 0) return "#3B9EFF";
  if (r.full > 0) return "#A78BFA";
  return "#F5A524";
}
