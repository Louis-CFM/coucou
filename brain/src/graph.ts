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
  x: number;  // pre-computed sphere position (stable across runs)
  y: number;
  z: number;
}

export interface GraphEdge {
  from: string;
  to: string;
}

export interface GraphData {
  nodes: GraphNode[];
  edges: GraphEdge[];
}

// ── Position helpers ─────────────────────────────────────────────────────────

/** Stable djb2-style hash — matches Swift's stableHash in FlowHubMemory.swift */
function stableHash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

/**
 * Fibonacci sphere layout — evenly distributes `total` points on a sphere of `radius`.
 * Returns the position for point at `index`.
 */
function fibonacciSpherePos(
  index: number,
  total: number,
  radius: number
): { x: number; y: number; z: number } {
  const golden = (1 + Math.sqrt(5)) / 2;
  const theta = (2 * Math.PI * index) / golden;
  const cosPhiRaw = 1 - 2 * (index + 0.5) / Math.max(total, 1);
  const cosPhi = Math.max(-1, Math.min(1, cosPhiRaw));
  const phi = Math.acos(cosPhi);
  return {
    x: radius * Math.sin(phi) * Math.cos(theta),
    y: radius * Math.cos(phi),
    z: radius * Math.sin(phi) * Math.sin(theta),
  };
}

/**
 * Gaussian offset using seeded Box-Muller transform.
 * Uses three separate stableHash seeds for x, y, z.
 */
function gaussianOffset(
  id: string,
  sigma: number
): { x: number; y: number; z: number } {
  const hx = stableHash(id);
  const hy = stableHash(id + "y");
  const hz = stableHash(id + "z");

  // Box-Muller: map hash to (0,1) then to Gaussian
  const ux = ((hx % 1000) + 0.5) / 1001;
  const uy = ((hy % 1000) + 0.5) / 1001;
  const uz = ((hz % 1000) + 0.5) / 1001;

  // Use paired Box-Muller: (ux, uy) → two normals, (uz, ux) → one more
  const r1 = sigma * Math.sqrt(-2 * Math.log(ux + 1e-9));
  const r2 = sigma * Math.sqrt(-2 * Math.log(uy + 1e-9));
  const r3 = sigma * Math.sqrt(-2 * Math.log(uz + 1e-9));

  const angle1 = (2 * Math.PI * uy);
  const angle2 = (2 * Math.PI * ux);

  return {
    x: r1 * Math.cos(angle1),
    y: r2 * Math.sin(angle1),
    z: r3 * Math.cos(angle2),
  };
}

/** Save graph.json to .state/ for instant Coucou reads (no process spawn needed). */
export function saveGraphJson(config: BrainConfig, data: GraphData): void {
  const stateDir = path.join(expandHome(config.brainPath), ".state");
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(path.join(stateDir, "graph.json"), JSON.stringify(data), "utf8");
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

/** Extract simple keywords from a string (lowercase words ≥ 4 chars). */
function keywords(text: string): Set<string> {
  const words = text.toLowerCase().match(/[a-zàáâãäåæçèéêëìíîïðñòóôõöùúûüýþÿœ]{4,}/g) ?? [];
  return new Set(words);
}

/** Count keyword overlap between two sets. */
function keywordOverlap(a: Set<string>, b: Set<string>): number {
  let count = 0;
  for (const w of a) if (b.has(w)) count++;
  return count;
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

  // Edge deduplication: key is "smaller|larger" to treat edges as undirected for dedup
  const edgeSet = new Set<string>();

  function addNode(node: GraphNode): void {
    if (!nodeIds.has(node.id)) {
      nodes.push(node);
      nodeIds.add(node.id);
    }
  }

  function addEdge(from: string, to: string): void {
    const key = from < to ? `${from}|${to}` : `${to}|${from}`;
    if (!edgeSet.has(key)) {
      edgeSet.add(key);
      edges.push({ from, to });
    }
  }

  // ── "Moi" root node ───────────────────────────────────────────────────────
  addNode({ id: "moi", kind: "moi", label: "Moi", date: null, projet: null, x: 0, y: 0, z: 0 });

  // ── Conversations from rawindex ───────────────────────────────────────────
  const convs = getAllConversations(config);

  // Collect distinct projects (preserving insertion order = first-seen)
  const projectFirstDate = new Map<string, string>();
  for (const conv of convs) {
    const proj = conv.project || (conv.source === "desktop" ? "claude.ai" : "sessions");
    if (!projectFirstDate.has(proj) || conv.convDate < projectFirstDate.get(proj)!) {
      projectFirstDate.set(proj, conv.convDate);
    }
  }

  // Add project nodes using Fibonacci sphere at radius 290
  const projectList = Array.from(projectFirstDate.keys());
  const totalProjects = projectList.length;
  for (let i = 0; i < projectList.length; i++) {
    const proj = projectList[i];
    const date = projectFirstDate.get(proj)!;
    const id = `proj_${proj}`;
    const pos = fibonacciSpherePos(i, totalProjects, 290);
    addNode({ id, kind: "projet", label: proj, date, projet: null, ...pos });
    addEdge("moi", id);
  }

  // Build a map of projId → Fibonacci sphere position for clustering children
  const projPos = new Map<string, { x: number; y: number; z: number }>();
  for (const node of nodes) {
    if (node.kind === "projet") {
      projPos.set(node.id, { x: node.x, y: node.y, z: node.z });
    }
  }

  // Add conversation nodes (capped — keep newest first, up to limit - projects - moi - elements)
  const convLimit = Math.max(0, limit - nodes.length - 500); // reserve 500 for elements
  const convSlice = convs.slice(0, convLimit);

  // Map convId → projId for later use
  const convToProj = new Map<string, string>();

  for (const conv of convSlice) {
    const proj = conv.project || (conv.source === "desktop" ? "claude.ai" : "sessions");
    const projId = `proj_${proj}`;
    const id = `conv_${conv.convId}`;
    const label = conv.convTitle || conv.convId.slice(0, 8);

    // Gaussian cluster (σ≈60) around project position
    const base = projPos.get(projId) ?? { x: 0, y: 0, z: 0 };
    const offset = gaussianOffset(id, 60);
    const pos = { x: base.x + offset.x, y: base.y + offset.y, z: base.z + offset.z };

    addNode({ id, kind: "conv", label, date: conv.convDate, projet: proj, ...pos });
    addEdge(projId, id);
    convToProj.set(id, projId);
  }

  // ── Conv ↔ 2 nearest convs in same project (by title word overlap > 0) ──
  // Group convs by project
  const convsByProj = new Map<string, { id: string; label: string }[]>();
  for (const node of nodes) {
    if (node.kind === "conv") {
      const pid = convToProj.get(node.id) ?? "";
      if (!convsByProj.has(pid)) convsByProj.set(pid, []);
      convsByProj.get(pid)!.push({ id: node.id, label: node.label });
    }
  }

  for (const [, convGroup] of convsByProj) {
    // For each conv, find up to 2 others in same project with overlap > 0
    for (let i = 0; i < convGroup.length; i++) {
      const a = convGroup[i];
      const aKw = keywords(a.label);
      const candidates: { id: string; overlap: number }[] = [];
      for (let j = 0; j < convGroup.length; j++) {
        if (i === j) continue;
        const b = convGroup[j];
        const overlap = keywordOverlap(aKw, keywords(b.label));
        if (overlap > 0) candidates.push({ id: b.id, overlap });
      }
      // Sort by overlap descending, take top 2
      candidates.sort((x, y) => y.overlap - x.overlap);
      for (const c of candidates.slice(0, 2)) {
        addEdge(a.id, c.id);
      }
    }
  }

  // ── LLM digested elements (Level 2+) ────────────────────────────────────
  const stateDir = path.join(expandHome(config.brainPath), ".state", "proj");
  if (fs.existsSync(stateDir) && nodes.length < limit) {
    const files = fs.readdirSync(stateDir).filter((f) => f.endsWith(".json"));

    // Collect all elements across all projects for cross-element edges
    const allElements: {
      id: string;
      kind: NodeKind;
      projId: string;
      convId: string | null;
      label: string;
      kw: Set<string>;
    }[] = [];

    for (const file of files) {
      if (nodes.length >= limit) break;
      try {
        const raw = fs.readFileSync(path.join(stateDir, file), "utf8");
        const state: { id: string; elements: StoredElement[] } = JSON.parse(raw);
        const projId = state.id; // e.g. "proj_coucou"
        const projLabel = state.id.replace(/^proj_/, "");

        // Ensure the project node exists (projects from state files not in rawindex)
        if (!nodeIds.has(projId)) {
          // Find an index for this new project (append to end of fibonacci sphere)
          const newIndex = projectList.length;
          const pos = fibonacciSpherePos(newIndex, Math.max(totalProjects, newIndex + 1), 290);
          addNode({ id: projId, kind: "projet", label: projLabel, date: null, projet: null, ...pos });
          addEdge("moi", projId);
          projPos.set(projId, pos);
          projectList.push(projLabel);
        }

        const basePos = projPos.get(projId) ?? { x: 0, y: 0, z: 0 };

        // Group elements by their source conv for sequential linking
        const elemsByConv = new Map<string, StoredElement[]>();

        for (const elem of state.elements) {
          if (nodes.length >= limit) break;
          const kind = kindOf(elem.kind);
          const id = elem.id;
          const label = elem.texte.slice(0, 60);

          // Determine conversation anchor
          const sourceConvId = elem.sources && elem.sources.length > 0
            ? `conv_${elem.sources[0]}`
            : null;

          // Position: Gaussian cluster (σ≈15) around conv position (or project if no conv)
          const anchor = sourceConvId && nodeIds.has(sourceConvId)
            ? (() => {
                const n = nodes.find((x) => x.id === sourceConvId);
                return n ? { x: n.x, y: n.y, z: n.z } : basePos;
              })()
            : basePos;
          const offset = gaussianOffset(id, 15);
          const pos = { x: anchor.x + offset.x, y: anchor.y + offset.y, z: anchor.z + offset.z };

          addNode({ id, kind, label, date: elem.date, projet: projLabel, ...pos });

          // proj → element edge
          addEdge(projId, id);

          // element → its conversation
          if (sourceConvId && nodeIds.has(sourceConvId)) {
            addEdge(id, sourceConvId);
          }

          // Track for sequential within-conv linking
          const convKey = sourceConvId ?? `__proj_${projId}`;
          if (!elemsByConv.has(convKey)) elemsByConv.set(convKey, []);
          elemsByConv.get(convKey)!.push(elem);

          // Collect for cross-element edges
          allElements.push({
            id,
            kind,
            projId,
            convId: sourceConvId,
            label,
            kw: keywords(elem.texte),
          });
        }

        // Element → previous element in same conv (sequential)
        for (const [, group] of elemsByConv) {
          for (let i = 1; i < group.length; i++) {
            addEdge(group[i].id, group[i - 1].id);
          }
        }

        // People from elements
        for (const elem of state.elements) {
          if (nodes.length >= limit) break;
          if (elem.nom) {
            const id = `people_${elem.nom.toLowerCase().replace(/\s+/g, "_")}`;
            if (!nodeIds.has(id)) {
              // People: Gaussian offset (σ≈80) from project position
              const offset = gaussianOffset(id, 80);
              const pos = {
                x: basePos.x + offset.x,
                y: basePos.y + offset.y,
                z: basePos.z + offset.z,
              };
              addNode({ id, kind: "personne", label: elem.nom, date: elem.date, projet: null, ...pos });
              addEdge("moi", id);
            }
            // Person → their project
            addEdge(id, projId);
          }
        }
      } catch {
        // skip unreadable state files
      }
    }

    // ── Elements of same kind with keyword overlap ≥ 1 (max 3 new edges per element) ──
    for (let i = 0; i < allElements.length; i++) {
      const a = allElements[i];
      const candidates: { id: string; overlap: number }[] = [];
      for (let j = 0; j < allElements.length; j++) {
        if (i === j) continue;
        const b = allElements[j];
        if (a.kind !== b.kind) continue;
        const overlap = keywordOverlap(a.kw, b.kw);
        if (overlap >= 1) candidates.push({ id: b.id, overlap });
      }
      candidates.sort((x, y) => y.overlap - x.overlap);
      for (const c of candidates.slice(0, 3)) {
        addEdge(a.id, c.id);
      }
    }
  }

  return { nodes, edges };
}
