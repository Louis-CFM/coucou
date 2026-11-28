/**
 * brain graph — build a knowledge graph from rawindex + LLM state files.
 *
 * Galaxy layout: moi = black hole at origin, each project = logarithmic spiral arm,
 * convs placed along arm by age (recent near center r=120, old at edge r=3000).
 * XZ = galaxy disk plane, Y = disk thickness (σ≈20).
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
  x: number;  // galaxy disk plane (XZ), disk thickness (Y)
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

/** Stable hash — same as Swift's stableHash in FlowHubMemory.swift */
function stableHash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (Math.imul(31, h) + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
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

  const ux = ((hx % 1000) + 0.5) / 1001;
  const uy = ((hy % 1000) + 0.5) / 1001;
  const uz = ((hz % 1000) + 0.5) / 1001;

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

/**
 * Galaxy spiral position for a point along a project arm.
 * armAngle: the base angle of this project's arm (0–2π).
 * ageFactor: 0=newest (near center), 1=oldest (far edge).
 * Returns XZ in disk plane, Y = disk thickness.
 */
function galaxyArmPos(
  id: string,
  armAngle: number,
  ageFactor: number
): { x: number; y: number; z: number } {
  const r = 120 + ageFactor * 2880;  // r in [120, 3000]
  const theta = armAngle + 0.35 * Math.log(Math.max(r, 1));

  // Perpendicular Gaussian spread in disk plane (σ=40) + disk thickness (σ=20)
  const off = gaussianOffset(id, 40);
  const thick = gaussianOffset(id + "thick", 20);

  return {
    x: r * Math.cos(theta) + off.x,
    y: thick.x,            // disk thickness, σ≈20
    z: r * Math.sin(theta) + off.y,
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

  // Edge deduplication: key is "smaller|larger"
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

  // ── "Moi" root node — galaxy center / black hole ─────────────────────────
  addNode({ id: "moi", kind: "moi", label: "Moi", date: null, projet: null, x: 0, y: 0, z: 0 });

  // ── Conversations from rawindex ───────────────────────────────────────────
  const convs = getAllConversations(config);

  // Collect distinct projects + date ranges
  const projectFirstDate = new Map<string, string>();  // oldest conv date
  const projectLatestDate = new Map<string, string>(); // newest conv date

  for (const conv of convs) {
    const proj = conv.project || (conv.source === "desktop" ? "claude.ai" : "sessions");
    const d = conv.convDate;
    if (!projectFirstDate.has(proj) || d < projectFirstDate.get(proj)!) {
      projectFirstDate.set(proj, d);
    }
    if (!projectLatestDate.has(proj) || d > projectLatestDate.get(proj)!) {
      projectLatestDate.set(proj, d);
    }
  }

  // ── Project nodes — spiral arm roots ────────────────────────────────────
  const projectList = Array.from(projectFirstDate.keys());
  const totalProjects = projectList.length;

  // arm angle per project: evenly spaced, stable order
  const projArmAngle = new Map<string, number>();

  for (let i = 0; i < projectList.length; i++) {
    const proj = projectList[i];
    const date = projectFirstDate.get(proj)!;
    const id = `proj_${proj}`;
    const armAngle = (i / Math.max(totalProjects, 1)) * 2 * Math.PI;
    projArmAngle.set(proj, armAngle);

    // Project anchor at r=90 on the arm (innermost ring, near black hole)
    const r = 90;
    const theta = armAngle + 0.35 * Math.log(r);
    addNode({
      id, kind: "projet", label: proj, date, projet: null,
      x: r * Math.cos(theta),
      y: 0,
      z: r * Math.sin(theta),
    });
    addEdge("moi", id);
  }

  // ── Conversation nodes — along spiral arms, sorted oldest→outermost ──────
  const convLimit = Math.max(0, limit - nodes.length - 500); // reserve 500 for elements
  const convSlice = convs.slice(0, convLimit);

  // Group convs by project
  const convsByProjRaw = new Map<string, typeof convSlice>();
  for (const conv of convSlice) {
    const proj = conv.project || (conv.source === "desktop" ? "claude.ai" : "sessions");
    if (!convsByProjRaw.has(proj)) convsByProjRaw.set(proj, []);
    convsByProjRaw.get(proj)!.push(conv);
  }

  const convToProj = new Map<string, string>(); // conv node id → proj node id

  for (const [proj, projConvList] of convsByProjRaw) {
    const projId = `proj_${proj}`;
    const armAngle = projArmAngle.get(proj) ?? 0;
    const newestDate = projectLatestDate.get(proj) ?? "2020-01-01";
    const oldestDate = projectFirstDate.get(proj) ?? "2020-01-01";
    const newestMs = new Date(newestDate).getTime();
    const oldestMs = new Date(oldestDate).getTime();
    const dateRange = Math.max(1, newestMs - oldestMs);

    // Sort chronologically oldest→newest (highest age → closest to outer edge)
    const sorted = [...projConvList].sort((a, b) => a.convDate.localeCompare(b.convDate));
    const convIds: string[] = [];

    for (const conv of sorted) {
      const id = `conv_${conv.convId}`;
      const label = conv.convTitle || conv.convId.slice(0, 8);

      // ageFactor: 0 = newest (near center), 1 = oldest (far outer edge)
      const convMs = new Date(conv.convDate).getTime();
      const ageFactor = Math.max(0, Math.min(1, 1 - (convMs - oldestMs) / dateRange));

      const pos = galaxyArmPos(id, armAngle, ageFactor);
      addNode({ id, kind: "conv", label, date: conv.convDate, projet: proj, ...pos });
      addEdge(projId, id);
      convToProj.set(id, projId);
      convIds.push(id);
    }

    // Sequential conv-conv links along the arm (guaranteed density)
    for (let i = 1; i < convIds.length; i++) {
      addEdge(convIds[i - 1], convIds[i]);
    }
  }

  // ── Conv ↔ 2 nearest convs in same project (by title word overlap > 0) ──
  const convsByProj = new Map<string, { id: string; label: string }[]>();
  for (const node of nodes) {
    if (node.kind === "conv") {
      const pid = convToProj.get(node.id) ?? "";
      if (!convsByProj.has(pid)) convsByProj.set(pid, []);
      convsByProj.get(pid)!.push({ id: node.id, label: node.label });
    }
  }

  for (const [, convGroup] of convsByProj) {
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
          const newIdx = projectList.length;
          const armAngle = (newIdx / Math.max(totalProjects + 1, 1)) * 2 * Math.PI;
          const r = 90;
          const theta = armAngle + 0.35 * Math.log(r);
          addNode({
            id: projId, kind: "projet", label: projLabel, date: null, projet: null,
            x: r * Math.cos(theta),
            y: 0,
            z: r * Math.sin(theta),
          });
          addEdge("moi", projId);
          projArmAngle.set(projLabel, armAngle);
          projectList.push(projLabel);
        }

        const projNode = nodes.find((n) => n.id === projId);
        const basePos = projNode ? { x: projNode.x, y: projNode.y, z: projNode.z } : { x: 0, y: 0, z: 0 };
        const elemsByConv = new Map<string, StoredElement[]>();

        for (const elem of state.elements) {
          if (nodes.length >= limit) break;
          const kind = kindOf(elem.kind);
          const id = elem.id;
          const label = elem.texte.slice(0, 60);

          const sourceConvId = elem.sources && elem.sources.length > 0
            ? `conv_${elem.sources[0]}`
            : null;

          // Elements cluster (σ≈10) around their conv, σ≈5 disk thickness
          const convNode = sourceConvId ? nodes.find((x) => x.id === sourceConvId) : null;
          const anchor = convNode
            ? { x: convNode.x, y: convNode.y, z: convNode.z }
            : basePos;
          const off = gaussianOffset(id, 10);
          const thick = gaussianOffset(id + "thick", 5);
          const pos = {
            x: anchor.x + off.x,
            y: anchor.y + thick.x,
            z: anchor.z + off.y,
          };

          addNode({ id, kind, label, date: elem.date, projet: projLabel, ...pos });
          addEdge(projId, id);
          if (sourceConvId && nodeIds.has(sourceConvId)) {
            addEdge(id, sourceConvId);
          }

          const convKey = sourceConvId ?? `__proj_${projId}`;
          if (!elemsByConv.has(convKey)) elemsByConv.set(convKey, []);
          elemsByConv.get(convKey)!.push(elem);

          allElements.push({
            id, kind, projId, convId: sourceConvId, label, kw: keywords(elem.texte),
          });
        }

        // Sequential element → previous element in same conv
        for (const [, group] of elemsByConv) {
          for (let i = 1; i < group.length; i++) {
            addEdge(group[i].id, group[i - 1].id);
          }
        }

        // People nodes — near their project arm (σ=80, flat in disk)
        for (const elem of state.elements) {
          if (nodes.length >= limit) break;
          if (elem.nom) {
            const id = `people_${elem.nom.toLowerCase().replace(/\s+/g, "_")}`;
            if (!nodeIds.has(id)) {
              const off = gaussianOffset(id, 80);
              addNode({
                id, kind: "personne", label: elem.nom, date: elem.date, projet: null,
                x: basePos.x + off.x,
                y: off.y * 0.1, // keep near disk plane
                z: basePos.z + off.z,
              });
              addEdge("moi", id);
            }
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
