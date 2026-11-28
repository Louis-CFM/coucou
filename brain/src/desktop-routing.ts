/**
 * Domain routing for Claude Desktop export conversations.
 *
 * Rules:
 * - LLM picks projects from validProjects list (known slugs + fixed domains)
 * - People slugs (people/X, people-X) → extraPeople, NOT project pages
 * - Anything not in knownSlugs ∪ FIXED_DOMAINS → discarded
 * - Fallback when nothing survives → "perso"
 */
import fs from "node:fs";
import path from "node:path";
import { expandHome, toSlug } from "./utils.js";

export type FixedDomain =
  | "perso"
  | "admin-et-argent"
  | "achats"
  | "contenu-et-reseaux"
  | "freelance"
  | "apprentissage";

export const FIXED_DOMAINS: FixedDomain[] = [
  "perso",
  "admin-et-argent",
  "achats",
  "contenu-et-reseaux",
  "freelance",
  "apprentissage",
];

/**
 * Load the set of existing project slugs from .state/proj/proj_*.json filenames.
 * Example: "proj_portfo.json" → "portfo"
 */
export function getKnownProjectSlugs(brainPath: string): Set<string> {
  const stateDir = path.join(expandHome(brainPath), ".state", "proj");
  if (!fs.existsSync(stateDir)) return new Set();
  return new Set(
    fs.readdirSync(stateDir)
      .filter((f) => f.startsWith("proj_") && f.endsWith(".json"))
      .map((f) => f.slice(5, -5)) // "proj_portfo.json" → "portfo"
  );
}

/**
 * Remap LLM-assigned project names for a desktop conversation.
 *
 * The LLM was given the validProjects list (knownSlugs + FIXED_DOMAINS) in its prompt,
 * so it should stay within that list. This function enforces that constraint:
 * - People slugs (people/X, people-X) → extraPeople (handled by updatePeople, not project pages)
 * - Known project slug OR fixed domain → kept as-is
 * - Anything else → discarded
 * - If nothing survives → fallback to "perso"
 *
 * Always returns at least one entry in `projects`.
 */
export function remapDesktopProjects(
  llmProjects: string[],
  knownSlugs: Set<string>,
  _convName: string,
  _messages: Array<{ text: string }>
): { projects: string[]; extraPeople: string[] } {
  const validSlugs = new Set<string>([...knownSlugs, ...FIXED_DOMAINS]);
  const projects: string[] = [];
  const extraPeople: string[] = [];

  for (const proj of llmProjects) {
    const slug = toSlug(proj);
    // People slug: "people/enya", "people-enya", "People/Enya"
    if (/^[Pp]eople[/-]/i.test(proj) || slug.startsWith("people-")) {
      const personName = proj.replace(/^[Pp]eople[/-]/i, "").replace(/^people-/, "");
      if (personName) extraPeople.push(personName);
      continue;
    }
    // Keep if it's a known project OR a fixed domain
    if (validSlugs.has(slug)) {
      projects.push(proj);
    }
    // Otherwise discard — the LLM went off-list
  }

  // Fallback: LLM assigned nothing valid → "perso"
  if (projects.length === 0) {
    projects.push("perso");
  }

  return { projects, extraPeople };
}
