/**
 * CoucouBrain MCP server — read-only access to ~/CoucouBrain/ memory.
 *
 * Tools:
 *   brain_index     — INDEX.md
 *   brain_search    — FTS5 search over elements
 *   brain_project   — a project page
 *   brain_rules     — corrections + louis prefs + project active decisions + ⚠️ lessons
 *   brain_get       — a specific page or element by id
 *   brain_correct   — append to corrections.md (ONLY when explicitly asked)
 *
 * Start: `brain mcp`  (stdio transport, registered via `claude mcp add --scope user`)
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import { loadConfig } from "../config.js";
import { expandHome } from "../utils.js";
import { searchFts, parseCorrections, appendCorrection, renderSearchResult } from "../fts.js";
import type { StoredElement } from "../elements.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function brainBase(): string {
  const config = loadConfig();
  return expandHome(config.brainPath);
}

function readPage(filePath: string): string | null {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
}

function findPageById(id: string, base: string): string | null {
  const dirs = [
    base,
    path.join(base, "projects"),
    path.join(base, "records"),
    path.join(base, "people"),
  ];
  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith(".md")) continue;
      try {
        const full = path.join(dir, f);
        const raw = fs.readFileSync(full, "utf8");
        const { data } = matter(raw);
        if (data.id === id) return raw;
      } catch {}
    }
  }
  return null;
}

function loadProjectState(slug: string, base: string): {
  elements: StoredElement[];
  title: string;
  etatActuel: string;
  goal: string;
} | null {
  const projectId = slug.startsWith("proj_") ? slug : `proj_${slug.replace(/\s+/g, "-").toLowerCase()}`;
  const stateFile = path.join(base, ".state", "proj", `${projectId}.json`);
  if (!fs.existsSync(stateFile)) return null;
  try {
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch {
    return null;
  }
}

function loadGlobalState(id: string, base: string): { elements: StoredElement[] } | null {
  const stateFile = path.join(base, ".state", "proj", `${id}.json`);
  if (!fs.existsSync(stateFile)) return null;
  try {
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch {
    return null;
  }
}

function renderElement(e: StoredElement): string {
  const warn = e.statut === "❌" || e.statut === "⚠️" ? ` ${e.statut}` : "";
  const stat = e.statut && !warn ? ` ${e.statut}` : "";
  const raison = e.statut === "❌" && e.raison ? ` ← ${e.raison}` : "";
  return `- [${e.kind}${stat}${warn}] ${e.texte}${raison}  _(${e.date})_`;
}

function ok(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

function err(msg: string) {
  return { content: [{ type: "text" as const, text: `❌ ${msg}` }], isError: true };
}

// ── Server ────────────────────────────────────────────────────────────────────

export async function startMcpServer(): Promise<void> {
  const server = new McpServer(
    { name: "coucou-brain", version: "0.1.0" },
    { capabilities: { tools: {} } }
  );

  // ── brain_index ─────────────────────────────────────────────────────────────
  server.tool(
    "brain_index",
    "Retourne INDEX.md — liste des projets, fiches récentes, pages clés. Lire en premier pour orienter les autres appels.",
    async () => {
      const base = brainBase();
      const indexPath = path.join(base, "INDEX.md");
      const content = readPage(indexPath);
      if (!content) return err("INDEX.md introuvable. Lancez `brain ingest` d'abord.");
      return ok(content);
    }
  );

  // ── brain_search ────────────────────────────────────────────────────────────
  server.tool(
    "brain_search",
    "Recherche plein texte (FTS5) dans la mémoire. Les corrections passent en tête. Les éléments ❌/⚠️ sont inclus et signalés — c'est intentionnel, ils disent ce qu'il ne faut pas refaire. Les mesures financières (CA, montants) ne sont jamais retournées.",
    {
      query: z.string().min(2).describe("Texte libre à rechercher"),
      project: z.string().optional().describe("Slug du projet pour booster les résultats (ex: portfo, sbe-hub)"),
      kinds: z.array(z.enum(["décision", "fait", "leçon", "tâche", "préférence", "correction"])).optional().describe("Filtrer par kind"),
      limit: z.number().int().min(1).max(20).default(8).optional().describe("Nombre max de résultats"),
    },
    async ({ query, project, kinds, limit }) => {
      const config = loadConfig();
      const results = searchFts(config, query, {
        project,
        kinds,
        limit: limit ?? 8,
        threshold: -0.1,  // MCP tool uses a laxer threshold than hooks
        excludeMesures: true,
      });

      if (results.length === 0) {
        return ok("Aucun résultat pour cette recherche.");
      }

      const lines = results.map((r, i) => {
        const marker = r.statut === "❌" ? " ⛔ NE PAS REFAIRE" : r.statut === "⚠️" ? " ⚠️ PIÈGE" : "";
        const proj = r.sourceProject.replace(/^proj_/, "").replace(/^corrections:/, "CORRECTION:");
        const header = r.isCorrection ? `**[CORRECTION:${proj}]**` : `[${r.kind}] [${proj}]`;
        return `${i + 1}. ${header}${marker}\n   ${r.texte}${r.date ? `  _(${r.date})_` : ""}`;
      });

      return ok(`## Résultats (${results.length})\n\n${lines.join("\n\n")}`);
    }
  );

  // ── brain_project ───────────────────────────────────────────────────────────
  server.tool(
    "brain_project",
    "Retourne la page complète d'un projet (décisions, faits, tâches, mesures, fiches liées).",
    {
      slug: z.string().describe("Slug du projet, ex: portfo, sbe-hub, coucou"),
    },
    async ({ slug }) => {
      const base = brainBase();
      const cleanSlug = slug.replace(/^proj_/, "").toLowerCase().replace(/\s+/g, "-");
      const filePath = path.join(base, "projects", `${cleanSlug}.md`);
      const content = readPage(filePath);
      if (!content) return err(`Projet introuvable : ${slug}. Vérifiez brain_index() pour la liste des projets.`);
      return ok(content);
    }
  );

  // ── brain_rules ─────────────────────────────────────────────────────────────
  server.tool(
    "brain_rules",
    "Retourne les règles actives : corrections (priorité max) + préférences globales de Louis + décisions structurantes du projet + leçons ⚠️ pertinentes. À appeler avant de commencer toute tâche non triviale.",
    {
      project: z.string().optional().describe("Slug du projet pour inclure ses règles spécifiques"),
    },
    async ({ project }) => {
      const config = loadConfig();
      const base = expandHome(config.brainPath);
      const sections: string[] = [];

      // ── 1. Corrections (toujours en premier) ───────────────────────────────
      const corrections = parseCorrections(config);
      if (corrections.length > 0) {
        const corrParts: string[] = [];
        for (const sec of corrections) {
          if (sec.scope === "global" || !project || sec.scope === project ||
              sec.scope === project.replace(/^proj_/, "")) {
            corrParts.push(`### ${sec.scope}\n${sec.text}`);
          }
        }
        if (corrParts.length > 0) {
          sections.push(`## ⚠️ Corrections (priorité maximale — toujours respecter)\n\n${corrParts.join("\n\n")}`);
        }
      }

      // ── 2. Préférences globales de Louis ──────────────────────────────────
      const louisState = loadGlobalState("louis", base);
      if (louisState && louisState.elements.length > 0) {
        const globalPrefs = louisState.elements
          .filter((e) => e.statut !== "❌" && (!e.projets || e.projets.length === 0))
          .slice(0, 15);
        if (globalPrefs.length > 0) {
          sections.push(
            `## Préférences globales de Louis\n\n${globalPrefs.map(renderElement).join("\n")}`
          );
        }
      }

      // ── 3. Règles du projet ───────────────────────────────────────────────
      if (project) {
        const slug = project.replace(/^proj_/, "");
        const state = loadProjectState(slug, base);
        if (state) {
          const projectParts: string[] = [];

          // État actuel
          if (state.etatActuel) {
            projectParts.push(`### État actuel\n${state.etatActuel}`);
          }

          // Décisions actives (non ❌)
          const activeDecs = state.elements.filter(
            (e) => e.kind === "décision" && e.statut !== "❌"
          );
          if (activeDecs.length > 0) {
            projectParts.push(`### Décisions structurantes\n${activeDecs.map(renderElement).join("\n")}`);
          }

          // Leçons ⚠️ et ❌
          const dangerLessons = state.elements.filter(
            (e) => e.kind === "leçon" && (e.statut === "⚠️" || e.sub_kind === "erreur")
          );
          if (dangerLessons.length > 0) {
            projectParts.push(`### Leçons et pièges\n${dangerLessons.map(renderElement).join("\n")}`);
          }

          // Tâches ouvertes
          const openTasks = state.elements.filter(
            (e) => e.kind === "tâche" && e.statut !== "❌" && e.statut !== "✅"
          );
          if (openTasks.length > 0) {
            projectParts.push(`### Tâches ouvertes\n${openTasks.map(renderElement).join("\n")}`);
          }

          if (projectParts.length > 0) {
            sections.push(`## Projet : ${state.title ?? slug}\n\n${projectParts.join("\n\n")}`);
          }
        }

        // Préférences de Louis spécifiques au projet
        if (louisState) {
          const projectPrefs = louisState.elements.filter(
            (e) => e.statut !== "❌" && e.projets?.some((p) => p.includes(slug))
          );
          if (projectPrefs.length > 0) {
            sections.push(`## Préférences de Louis pour ${slug}\n\n${projectPrefs.map(renderElement).join("\n")}`);
          }
        }
      }

      // ── 4. Leçons transverses ⚠️ ─────────────────────────────────────────
      const lessonsState = loadGlobalState("lessons", base);
      if (lessonsState && lessonsState.elements.length > 0) {
        const dangerLessons = lessonsState.elements.filter(
          (e) => e.statut === "⚠️" || e.sub_kind === "erreur"
        ).slice(0, 10);
        if (dangerLessons.length > 0) {
          sections.push(`## Leçons transverses ⚠️\n\n${dangerLessons.map(renderElement).join("\n")}`);
        }
      }

      if (sections.length === 0) {
        return ok("Aucune règle trouvée. Lancez `brain ingest` pour construire la mémoire.");
      }

      return ok(
        `# Règles CoucouBrain${project ? ` — ${project}` : ""}\n\n` +
        sections.join("\n\n---\n\n")
      );
    }
  );

  // ── brain_get ───────────────────────────────────────────────────────────────
  server.tool(
    "brain_get",
    "Retourne une page ou un élément précis par son id (ex: proj_portfo, rec_20261112_sbe-hub_d16c739b, les_6d05c932c7).",
    {
      id: z.string().describe("ID de la page ou de l'élément"),
    },
    async ({ id }) => {
      const config = loadConfig();
      const base = expandHome(config.brainPath);

      // Check if it's a page id
      const page = findPageById(id, base);
      if (page) return ok(page);

      // Check if it's an element id across all project states
      const stateDir = path.join(base, ".state", "proj");
      if (fs.existsSync(stateDir)) {
        for (const f of fs.readdirSync(stateDir)) {
          if (!f.endsWith(".json")) continue;
          try {
            const state = JSON.parse(
              fs.readFileSync(path.join(stateDir, f), "utf8")
            ) as { id: string; elements: StoredElement[] };
            const elem = state.elements.find((e) => e.id === id);
            if (elem) {
              return ok(
                `**[${elem.kind}]** ${elem.statut ?? ""} ${elem.texte}\n` +
                `- Projet : ${state.id}\n` +
                `- Date : ${elem.date}\n` +
                (elem.raison ? `- Raison : ${elem.raison}\n` : "") +
                (elem.domaine ? `- Domaine : ${elem.domaine}\n` : "")
              );
            }
          } catch {}
        }
      }

      return err(`Introuvable : ${id}`);
    }
  );

  // ── brain_correct ───────────────────────────────────────────────────────────
  server.tool(
    "brain_correct",
    [
      "Ajoute une correction manuelle à corrections.md.",
      "⛔ À n'utiliser QUE si Louis le demande EXPLICITEMENT avec les mots",
      "\"brain correct\", \"ajoute une correction\" ou \"corrige ça dans brain\".",
      "Ne JAMAIS appeler cet outil de manière autonome, même si une correction semble utile.",
    ].join(" "),
    {
      texte: z.string().min(5).describe("Texte de la correction"),
      scope: z.string().default("global").describe("Portée : 'global' ou slug de projet (ex: reels, sbe-hub)"),
    },
    async ({ texte, scope }) => {
      try {
        const config = loadConfig();
        appendCorrection(config, texte, scope);
        return ok(`✅ Correction ajoutée sous §${scope} dans corrections.md`);
      } catch (e) {
        return err(`Impossible d'écrire corrections.md : ${(e as Error).message}`);
      }
    }
  );

  // ── Connect ─────────────────────────────────────────────────────────────────
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
