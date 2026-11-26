/**
 * Stats — computes brain metrics from .md files only (no DB needed).
 * Used by `brain stats` command and later by the Swift UI.
 */
import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import { expandHome } from "./utils.js";
import type { BrainConfig } from "./config.js";

export interface BrainStats {
  pages: number;
  ideas: number;
  links: number;
  groups: Record<string, number>;
  types: Record<string, number>;
  updates_per_day: Record<string, number>;
  top_connected: { id: string; title: string; links: number }[];
  broken_links: string[];
}

// Sections that contribute "ideas" (list items in these sections)
const IDEA_SECTIONS = new Set([
  "Décisions",
  "Faits importants",
  "Faits",
  "Erreurs & leçons",
  "Tâches ouvertes",
]);

function extractLinks(content: string): string[] {
  const matches = content.matchAll(/\[\[([^\]]+)\]\]/g);
  return [...matches].map((m) => m[1]!);
}

function countIdeasInContent(content: string): number {
  let count = 0;
  let inIdea = false;

  for (const line of content.split("\n")) {
    const trimmed = line.trim();

    // Check if we're entering an idea section
    if (trimmed.startsWith("## ")) {
      const heading = trimmed.slice(3).trim();
      inIdea = IDEA_SECTIONS.has(heading);
      continue;
    }

    // Count list items in idea sections
    if (inIdea && (trimmed.startsWith("- ") || trimmed.startsWith("* "))) {
      count++;
    }
  }

  return count;
}

interface PageInfo {
  id: string;
  title: string;
  group: string;
  type: string;
  updated: string;
  links: string[];
  ideas: number;
}

function readAllPages(brainPath: string): PageInfo[] {
  const pages: PageInfo[] = [];
  const dirs = [
    path.join(brainPath, "records"),
    path.join(brainPath, "projects"),
    brainPath, // for lessons.md, INDEX.md at root
  ];

  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    const files = fs.readdirSync(dir).filter((f) => f.endsWith(".md"));
    for (const f of files) {
      const full = path.join(dir, f);
      // Skip .state/ and subdirs
      if (fs.statSync(full).isDirectory()) continue;

      try {
        const raw = fs.readFileSync(full, "utf8");
        const { data, content } = matter(raw);
        pages.push({
          id: data.id ?? f,
          title: data.title ?? f,
          group: data.group ?? "Reference",
          type: data.type ?? "unknown",
          updated: data.updated ?? "",
          links: extractLinks(content),
          ideas: countIdeasInContent(content),
        });
      } catch {
        // Malformed frontmatter — skip
      }
    }
  }

  return pages;
}

export function computeStats(config: BrainConfig): BrainStats {
  const brainPath = expandHome(config.brainPath);
  const pages = readAllPages(brainPath);

  const knownIds = new Set(pages.map((p) => p.id));

  // Groups
  const groups: Record<string, number> = {};
  for (const p of pages) {
    groups[p.group] = (groups[p.group] ?? 0) + 1;
  }

  // Types
  const types: Record<string, number> = {};
  for (const p of pages) {
    types[p.type] = (types[p.type] ?? 0) + 1;
  }

  // Ideas
  const ideas = pages.reduce((sum, p) => sum + p.ideas, 0);

  // Links (total outgoing)
  const totalLinks = pages.reduce((sum, p) => sum + p.links.length, 0);

  // Updates per day
  const updates_per_day: Record<string, number> = {};
  for (const p of pages) {
    if (p.updated) {
      updates_per_day[p.updated] = (updates_per_day[p.updated] ?? 0) + 1;
    }
  }

  // Top connected (most incoming links)
  const incomingLinks: Record<string, number> = {};
  for (const p of pages) {
    for (const link of p.links) {
      incomingLinks[link] = (incomingLinks[link] ?? 0) + 1;
    }
  }

  const idToPage = new Map(pages.map((p) => [p.id, p]));
  const top_connected = Object.entries(incomingLinks)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 20)
    .map(([id, count]) => ({
      id,
      title: idToPage.get(id)?.title ?? id,
      links: count,
    }));

  // Broken links (references to non-existent IDs)
  const broken_links: string[] = [];
  for (const p of pages) {
    for (const link of p.links) {
      if (!knownIds.has(link)) {
        broken_links.push(`${p.id} → [[${link}]]`);
      }
    }
  }

  return {
    pages: pages.length,
    ideas,
    links: totalLinks,
    groups,
    types,
    updates_per_day,
    top_connected,
    broken_links,
  };
}
