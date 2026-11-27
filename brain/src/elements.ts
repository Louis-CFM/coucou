/**
 * Element types, ID computation, coercion, merge, and rendering.
 * An "element" is a decision, fact, lesson, task, or preference
 * extracted from a Claude Code session.
 */
import { createHash } from "node:crypto";
import { z } from "zod";

// ── Schemas ───────────────────────────────────────────────────────────────────

export const ElementKindSchema = z.enum(["décision", "fait", "leçon", "tâche", "préférence", "mesure"]);
export const SubKindSchema = z.enum(["erreur", "leçon"]).nullable().default(null);
export const ProvenanceSchema = z.enum(["décidé", "proposé", "constaté"]).nullable().default(null);
export const StatutSchema = z.enum(["✅", "❌", "⏳", "⚠️"]).nullable().default(null);

export const LLMElementSchema = z.object({
  kind: ElementKindSchema,
  sub_kind: SubKindSchema,
  provenance: ProvenanceSchema,
  statut: StatutSchema,
  texte: z.string().min(1).max(400),
  nom: z.string().nullable().default(null),
  projets: z.array(z.string()).default([]),
  remplace: z.string().nullable().default(null),
  raison: z.string().nullable().default(null),
  domaine: z.string().nullable().default(null),
  scope: z.enum(["projet", "transverse"]).nullable().default("projet").transform((v) => v ?? "projet"),
  keywords: z.array(z.string()).default([]),
});

export type LLMElement = z.infer<typeof LLMElementSchema>;

// ── StoredElement ─────────────────────────────────────────────────────────────

export interface StoredElement {
  id: string;
  kind: string;
  sub_kind?: string | null;
  provenance?: string | null;
  statut?: string | null;
  texte: string;
  nom?: string | null;
  date: string;
  sources: string[];
  projets: string[];
  remplace?: string | null;
  raison?: string | null;
  domaine?: string | null;
  scope?: "projet" | "transverse";
  keywords?: string[];
}

// ── ID computation ────────────────────────────────────────────────────────────

const KIND_PREFIX: Record<string, string> = {
  décision: "dec",
  fait: "fait",
  leçon: "les",
  tâche: "tach",
  préférence: "pref",
  mesure: "mes",
};

export function computeElementId(kind: string, texte: string, nom?: string | null): string {
  const prefix = KIND_PREFIX[kind] ?? "elem";
  // Measures use nom as the stable dedup key — texte changes with each new value
  const key = kind === "mesure" && nom ? nom : texte;
  const normalized = key.normalize("NFC").trim().toLowerCase().replace(/\s+/g, " ");
  const hash = createHash("sha256").update(normalized).digest("hex").slice(0, 10);
  return `${prefix}_${hash}`;
}

// ── Validation & coercion ─────────────────────────────────────────────────────

/**
 * Coerce invalid provenance+statut combinations.
 * Never drops an element — always produces something valid.
 */
export function coerceElement(elem: LLMElement): LLMElement {
  // Measures have no provenance/statut semantics
  if (elem.kind === "mesure") return elem;
  // proposé ✅ → proposé ⏳
  if (elem.provenance === "proposé" && elem.statut === "✅") {
    return { ...elem, statut: "⏳" };
  }
  // constaté + any statut → constaté null
  if (elem.provenance === "constaté" && elem.statut !== null) {
    return { ...elem, statut: null };
  }
  // erreur + ✅ → erreur ⚠️
  if (elem.sub_kind === "erreur" && elem.statut === "✅") {
    return { ...elem, statut: "⚠️" };
  }
  // ❌ without raison → add placeholder
  if (elem.statut === "❌" && !elem.raison) {
    return { ...elem, raison: "raison non précisée" };
  }
  return elem;
}

// ── Conversion from LLM → StoredElement ──────────────────────────────────────

export function llmToStored(
  elem: LLMElement,
  sessionDate: string,
  recordId: string
): StoredElement {
  const c = coerceElement(elem);
  return {
    id: computeElementId(c.kind, c.texte, c.nom),
    kind: c.kind,
    sub_kind: c.sub_kind ?? null,
    provenance: c.provenance ?? null,
    statut: c.statut ?? null,
    texte: c.texte,
    nom: c.nom ?? null,
    date: sessionDate,
    sources: [recordId],
    projets: c.projets,
    remplace: c.remplace ?? null,
    raison: c.raison ?? null,
    domaine: c.domaine ?? null,
    scope: c.scope ?? "projet",
    keywords: c.keywords ?? [],
  };
}

// ── Merge ─────────────────────────────────────────────────────────────────────

/**
 * Merge new elements into existing ones.
 * - Same ID: merge sources, newer session's statut wins.
 * - remplace: marks the replaced element as ❌.
 */
export function mergeElements(
  existing: StoredElement[],
  newOnes: StoredElement[]
): StoredElement[] {
  const byId = new Map<string, StoredElement>(existing.map((e) => [e.id, e]));

  for (const ne of newOnes) {
    const ex = byId.get(ne.id);
    if (ex) {
      const sources = [...new Set([...ex.sources, ...ne.sources])];
      if (ex.kind === "mesure") {
        // Measures: latest value wins — replace texte with the new value
        byId.set(ne.id, { ...ne, sources });
      } else {
        byId.set(ne.id, {
          ...ex,
          sources,
          statut: ne.statut !== null ? ne.statut : ex.statut,
          date: ne.date,
          raison: ne.raison ?? ex.raison,
        });
      }
    } else {
      byId.set(ne.id, ne);
    }
  }

  // Handle replacements
  for (const elem of byId.values()) {
    if (elem.remplace) {
      const replaced = byId.get(elem.remplace);
      if (replaced && replaced.statut !== "❌") {
        byId.set(elem.remplace, {
          ...replaced,
          statut: "❌",
          raison: elem.raison ?? "remplacé",
        });
      }
    }
  }

  return [...byId.values()];
}

// ── Rendering ─────────────────────────────────────────────────────────────────

/**
 * Render an element as a Markdown list item (without the leading "- ").
 * Format: [provenance] statut texte — raison — date [[source]]
 */
export function renderElement(elem: StoredElement, validIds: Set<string>): string {
  const srcLinks = elem.sources
    .filter((s) => validIds.has(s))
    .map((s) => `[[${s}]]`)
    .join(" ");

  const datePart = ` — ${elem.date}`;
  const srcPart = srcLinks ? ` ${srcLinks}` : "";
  const raisonPart = elem.statut === "❌" && elem.raison ? ` — ${elem.raison}` : "";

  if (elem.kind === "mesure") {
    const dd = elem.date.slice(8, 10);
    const mm = elem.date.slice(5, 7);
    return `${elem.texte} — ${dd}/${mm}${srcPart}`;
  }

  if (elem.kind === "leçon") {
    const prefix = elem.sub_kind ?? "leçon";
    const statut = elem.statut ? ` ${elem.statut}` : "";
    return `[${prefix}]${statut} ${elem.texte}${raisonPart}${datePart}${srcPart}`;
  }

  if (elem.kind === "tâche") {
    return `${elem.texte}${datePart}${srcPart}`;
  }

  if (elem.kind === "fait") {
    return `${elem.texte}${datePart}${srcPart}`;
  }

  if (elem.kind === "préférence") {
    const prov = elem.provenance ? `[${elem.provenance}] ` : "";
    return `${prov}${elem.texte}${datePart}${srcPart}`;
  }

  // décision
  const prov = elem.provenance ? `[${elem.provenance}] ` : "";
  const statut = elem.statut ? `${elem.statut} ` : "";
  return `${prov}${statut}${elem.texte}${raisonPart}${datePart}${srcPart}`;
}

// ── Task closure ─────────────────────────────────────────────────────────────

/**
 * Mark tasks as done (✅) or abandoned (❌) in a stored elements array.
 * - doneIds: tasks that were completed → statut ✅
 * - abandonedItems: tasks explicitly dropped → statut ❌ with raison
 * Pure function — returns a new array.
 */
export function applyTaskClosures(
  elements: StoredElement[],
  doneIds: string[],
  abandonedItems: Array<{ id: string; raison: string }>,
  sessionDate: string,
  recordId: string
): StoredElement[] {
  if (doneIds.length === 0 && abandonedItems.length === 0) return elements;
  const abandonedMap = new Map(abandonedItems.map((a) => [a.id, a.raison]));
  return elements.map((e) => {
    if (doneIds.includes(e.id) && e.statut !== "✅" && e.statut !== "❌") {
      return {
        ...e,
        statut: "✅",
        date: sessionDate,
        sources: [...new Set([...e.sources, recordId])],
      };
    }
    if (abandonedMap.has(e.id) && e.statut !== "❌") {
      return {
        ...e,
        statut: "❌",
        raison: abandonedMap.get(e.id)!,
        date: sessionDate,
        sources: [...new Set([...e.sources, recordId])],
      };
    }
    return e;
  });
}

// ── Decision replacement ──────────────────────────────────────────────────────

/**
 * Mark decisions as replaced (❌) in a stored elements array.
 * - replacements: decisions that have been superseded
 * Pure function — returns a new array.
 */
export function applyDecisionReplacements(
  elements: StoredElement[],
  replacements: Array<{ id: string; par: string | null; raison: string }>,
  sessionDate: string,
  recordId: string
): StoredElement[] {
  if (replacements.length === 0) return elements;
  const replacementMap = new Map(replacements.map((r) => [r.id, r]));
  return elements.map((e) => {
    const replacement = replacementMap.get(e.id);
    if (replacement && e.statut !== "❌") {
      const raison = replacement.par
        ? `Remplacé par ${replacement.par} : ${replacement.raison}`
        : replacement.raison;
      return {
        ...e,
        statut: "❌",
        raison,
        date: sessionDate,
        sources: [...new Set([...e.sources, recordId])],
      };
    }
    return e;
  });
}

// ── Open element hint (passed to digest prompt) ───────────────────────────────

/** Minimal representation of an open task/decision passed to the LLM digest */
export interface OpenElementHint {
  id: string;
  kind: string;
  texte: string;
  statut: string | null;
  projets: string[];
}

// ── Link validation ────────────────────────────────────────────────────────────

/**
 * Fix [[xxx]] links in Markdown content.
 * - Valid links → kept as [[xxx]]
 * - Invalid links → plain text xxx (never erased)
 * - Content inside code blocks/spans → not touched
 */
export function validateLinks(content: string, validIds: Set<string>): string {
  const CODE_BLOCK = /```[\s\S]*?```/g;
  const INLINE_CODE = /`[^`\n]+`/g;

  // Collect code regions
  const codeRegions: Array<[number, number]> = [];
  for (const pattern of [CODE_BLOCK, INLINE_CODE]) {
    let m: RegExpExecArray | null;
    pattern.lastIndex = 0;
    while ((m = pattern.exec(content)) !== null) {
      codeRegions.push([m.index, m.index + m[0].length]);
    }
  }
  codeRegions.sort((a, b) => a[0] - b[0]);

  // Build non-overlapping segments
  const segments: Array<{ text: string; isCode: boolean }> = [];
  let last = 0;
  for (const [start, end] of codeRegions) {
    if (start > last) {
      segments.push({ text: content.slice(last, start), isCode: false });
    }
    segments.push({ text: content.slice(start, end), isCode: true });
    last = end;
  }
  if (last < content.length) {
    segments.push({ text: content.slice(last), isCode: false });
  }

  return segments
    .map(({ text, isCode }) => {
      if (isCode) return text;
      return text.replace(/\[\[([^\]]+)\]\]/g, (match, id) =>
        validIds.has(id) ? match : id
      );
    })
    .join("");
}
