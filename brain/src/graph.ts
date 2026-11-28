/**
 * brain graph — build a knowledge graph from rawindex + LLM state files.
 *
 * Level 1 (search only): nodes = moi + projects + conversations; edges = moi→proj, proj→conv.
 * Level 2+ (after LLM digestion): also element nodes (decisions, leçons, faits, prefs, people).
 *
 * Capped at 5000 newest nodes (by date).
 */
import fs from "node:fs";
import path from "node:path";
import { expandHome } from "./utils.js";
import type { BrainConfig } from "./config.js";
import { getAllConversations } from "./rawindex.js";
import type { StoredElement } from "./elements.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export type NodeKind =
  | "moi"
  | "projet"
  | "personne"
  | "conv"
  | "decision"
  | "lecon"
  | "fait"
  | "pref";

export interface GraphNode {
  id: string;
  kind: NodeKind;
  label: string;
  date: string | null;
  projet: string | null;
}

export interface GraphEdge {
  from: string;
  to: string;
}

export interface GraphData {
  nodes: GraphNode[];
  edges: GraphEdge[];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function kindOf(elementKind: string): NodeKind {
  const k = elementKind.toLowerCase();
  if (k.includes("décision") || k.includes("decision")) return "decision";
  if (k.includes("leçon") || k.includes("lecon") || k.includes("lesson")) return "lecon";
  if (k.includes("préférence") || k.includes("preference") || k.includes("pref")) return "pref";
  if (k.includes("fait")) return "fait";
  return "fait"; // default for unknown element kinds
}

// ── Main function ─────────────────────────────────────────────────────────────

export function buildGraph(
  config: BrainConfig,
  opts: { limit?: number } = {}
): GraphData {
  const limit = opts.limit ?? 5000;
  const nodes: GraphNode[] = [];
  const edges: GraphEdge[] = [];
  const nodeIds = new Set<string>();

  function addNode(node: GraphNode): void {
    if (!nodeIds.has(node.id)) {
      nodes.push(node);
      nodeIds.add(node.id);
    }
  }

  function addEdge(from: string, to: string): void {
    edges.push({ from, to });
  }

  // ── "Moi" root node ───────────────────────────────────────────────────────
  addNode({ id: "moi", kind: "moi", label: "Moi", date: null, projet: null });

  // ── Conversations from rawindex ───────────────────────────────────────────
  const convs = getAllConversations(config);

  // Collect distinct projects
  const projectFirstDate = new Map<string, string>();
  for (const conv of convs) {
    const proj = conv.project || (conv.source === "desktop" ? "claude.ai" : "sessions");
    if (!projectFirstDate.has(proj) || conv.convDate < projectFirstDate.get(proj)!) {
      projectFirstDate.set(proj, conv.convDate);
    }
  }

  // Add project nodes
  for (const [proj, date] of projectFirstDate) {
    const id = `proj_${proj}`;
    addNode({ id, kind: "projet", label: proj, date, projet: null });
    addEdge("moi", id);
  }

  // Add conversation nodes (capped — keep newest first, up to limit - projects - moi - elements)
  const convLimit = Math.max(0, limit - nodes.length - 500); // reserve 500 for elements
  const convSlice = convs.slice(0, convLimit);
  for (const conv of convSlice) {
    const proj = conv.project || (conv.source === "desktop" ? "claude.ai" : "sessions");
    const projId = `proj_${proj}`;
    const id = `conv_${conv.convId}`;
    const label = conv.convTitle || conv.convId.slice(0, 8);
    addNode({ id, kind: "conv", label, date: conv.convDate, projet: proj });
    addEdge(projId, id);
  }

  // ── LLM digested elements (Level 2+) ────────────────────────────────────
  const stateDir = path.join(expandHome(config.brainPath), ".state", "proj");
  if (fs.existsSync(stateDir) && nodes.length < limit) {
    const files = fs.readdirSync(stateDir).filter((f) => f.endsWith(".json"));

    for (const file of files) {
      if (nodes.length >= limit) break;
      try {
        const raw = fs.readFileSync(path.join(stateDir, file), "utf8");
        const state: { id: string; elements: StoredElement[] } = JSON.parse(raw);
        const projId = state.id; // e.g. "proj_coucou"
        const projLabel = state.id.replace(/^proj_/, "");

        // Ensure the project node exists
        if (!nodeIds.has(projId)) {
          addNode({ id: projId, kind: "projet", label: projLabel, date: null, projet: null });
          addEdge("moi", projId);
        }

        for (const elem of state.elements) {
          if (nodes.length >= limit) break;
          const kind = kindOf(elem.kind);
          const id = elem.id;
          const label = elem.texte.slice(0, 60);
          addNode({ id, kind, label, date: elem.date, projet: projLabel });
          addEdge(projId, id);
        }

        // People from elements
        for (const elem of state.elements) {
          if (nodes.length >= limit) break;
          if (elem.nom) {
            const id = `people_${elem.nom.toLowerCase().replace(/\s+/g, "_")}`;
            if (!nodeIds.has(id)) {
              addNode({ id, kind: "personne", label: elem.nom, date: elem.date, projet: null });
              addEdge("moi", id);
            }
          }
        }
      } catch {
        // skip unreadable state files
      }
    }
  }

  return { nodes, edges };
}
