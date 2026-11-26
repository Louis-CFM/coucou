/**
 * Tests for element merge logic, coercion rules, and ID stability.
 */
import { describe, it, expect } from "vitest";
import {
  computeElementId,
  coerceElement,
  llmToStored,
  mergeElements,
  renderElement,
  validateLinks,
  type LLMElement,
  type StoredElement,
} from "../src/elements.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function dec(overrides: Partial<LLMElement> = {}): LLMElement {
  return {
    kind: "décision",
    sub_kind: null,
    provenance: "décidé",
    statut: "✅",
    texte: "Utiliser TypeScript pour brain/",
    projets: ["coucou"],
    remplace: null,
    raison: null,
    domaine: null,
    scope: "projet",
    ...overrides,
  };
}

function stored(overrides: Partial<StoredElement> = {}): StoredElement {
  return {
    id: "dec_abc123",
    kind: "décision",
    provenance: "décidé",
    statut: "✅",
    texte: "Utiliser TypeScript pour brain/",
    date: "2026-11-01",
    sources: ["rec_xxx"],
    projets: ["coucou"],
    ...overrides,
  };
}

const NO_IDS = new Set<string>();
const SOME_IDS = new Set(["rec_abc", "rec_xyz", "proj_coucou"]);

// ── ID stability ──────────────────────────────────────────────────────────────

describe("computeElementId", () => {
  it("produces same id for same text", () => {
    const id1 = computeElementId("décision", "Utiliser TypeScript");
    const id2 = computeElementId("décision", "Utiliser TypeScript");
    expect(id1).toBe(id2);
  });

  it("produces same id despite whitespace variation", () => {
    const id1 = computeElementId("décision", "  Utiliser TypeScript  ");
    const id2 = computeElementId("décision", "Utiliser  TypeScript");
    expect(id1).toBe(id2);
  });

  it("different kind → different id for same text", () => {
    const id1 = computeElementId("décision", "Utiliser TypeScript");
    const id2 = computeElementId("leçon", "Utiliser TypeScript");
    expect(id1).not.toBe(id2);
  });

  it("prefixes match kind", () => {
    expect(computeElementId("décision", "foo")).toMatch(/^dec_/);
    expect(computeElementId("leçon", "foo")).toMatch(/^les_/);
    expect(computeElementId("tâche", "foo")).toMatch(/^tach_/);
    expect(computeElementId("fait", "foo")).toMatch(/^fait_/);
    expect(computeElementId("préférence", "foo")).toMatch(/^pref_/);
  });
});

// ── Coercion rules ────────────────────────────────────────────────────────────

describe("coerceElement", () => {
  it("proposé ✅ → proposé ⏳", () => {
    const e = coerceElement(dec({ provenance: "proposé", statut: "✅" }));
    expect(e.statut).toBe("⏳");
  });

  it("constaté + ✅ → constaté null", () => {
    const e = coerceElement(dec({ provenance: "constaté", statut: "✅" }));
    expect(e.statut).toBeNull();
  });

  it("constaté + ⚠️ → constaté null", () => {
    const e = coerceElement(dec({ provenance: "constaté", statut: "⚠️" }));
    expect(e.statut).toBeNull();
  });

  it("erreur + ✅ → erreur ⚠️", () => {
    const e = coerceElement(
      dec({ kind: "leçon", sub_kind: "erreur", provenance: null, statut: "✅" })
    );
    expect(e.statut).toBe("⚠️");
  });

  it("❌ without raison → adds placeholder raison", () => {
    const e = coerceElement(dec({ statut: "❌", raison: null }));
    expect(e.raison).toBeTruthy();
  });

  it("valid combinations unchanged", () => {
    const cases: Array<[Partial<LLMElement>, string | null]> = [
      [{ provenance: "décidé", statut: "✅" }, "✅"],
      [{ provenance: "décidé", statut: "❌", raison: "abandonné" }, "❌"],
      [{ provenance: "proposé", statut: "⏳" }, "⏳"],
      [{ provenance: "proposé", statut: "❌", raison: "rejeté" }, "❌"],
      [{ kind: "leçon", sub_kind: "leçon", provenance: null, statut: "✅" }, "✅"],
      [{ kind: "leçon", sub_kind: "erreur", provenance: null, statut: "⚠️" }, "⚠️"],
    ];
    for (const [input, expectedStatut] of cases) {
      const e = coerceElement(dec(input));
      expect(e.statut).toBe(expectedStatut);
    }
  });
});

// ── Deduplication ─────────────────────────────────────────────────────────────

describe("mergeElements", () => {
  it("same ID → merges sources", () => {
    const id = computeElementId("décision", "Utiliser TypeScript pour brain/");
    const a = stored({ id, sources: ["rec_1"] });
    const b = stored({ id, sources: ["rec_2"] });
    const result = mergeElements([a], [b]);
    expect(result).toHaveLength(1);
    expect(result[0]!.sources).toContain("rec_1");
    expect(result[0]!.sources).toContain("rec_2");
  });

  it("same ID → no duplicate sources", () => {
    const id = computeElementId("décision", "Utiliser TypeScript pour brain/");
    const a = stored({ id, sources: ["rec_1"] });
    const result = mergeElements([a], [stored({ id, sources: ["rec_1"] })]);
    expect(result[0]!.sources).toHaveLength(1);
  });

  it("different IDs → both kept", () => {
    const a = stored({ id: "dec_aaa", texte: "decision A", sources: ["rec_1"] });
    const b = stored({ id: "dec_bbb", texte: "decision B", sources: ["rec_2"] });
    const result = mergeElements([a], [b]);
    expect(result).toHaveLength(2);
  });

  it("newer statut wins on same ID", () => {
    const id = computeElementId("décision", "Utiliser TypeScript pour brain/");
    const old = stored({ id, statut: "✅" });
    const newer = stored({ id, statut: "❌", raison: "abandonné", date: "2026-12-01" });
    const result = mergeElements([old], [newer]);
    expect(result[0]!.statut).toBe("❌");
  });

  it("remplace → marks replaced element as ❌", () => {
    const replacedId = computeElementId("décision", "Ancienne décision");
    const replaced = stored({ id: replacedId, statut: "✅", texte: "Ancienne décision" });
    const newer = stored({
      id: "dec_new",
      texte: "Nouvelle décision",
      remplace: replacedId,
      raison: "meilleure approche",
    });
    const result = mergeElements([replaced], [newer]);
    const replacedResult = result.find((e) => e.id === replacedId);
    expect(replacedResult?.statut).toBe("❌");
  });

  it("empty existing → all new elements kept", () => {
    const elems = [stored({ id: "dec_1" }), stored({ id: "dec_2" })];
    const result = mergeElements([], elems);
    expect(result).toHaveLength(2);
  });
});

// ── Rendering ─────────────────────────────────────────────────────────────────

describe("renderElement", () => {
  it("décision ✅ format", () => {
    const e = stored({ provenance: "décidé", statut: "✅", texte: "Choix A" });
    const r = renderElement(e, NO_IDS);
    expect(r).toMatch(/^\[décidé\] ✅ Choix A/);
  });

  it("includes date", () => {
    const e = stored({ date: "2026-11-26", texte: "X" });
    expect(renderElement(e, NO_IDS)).toContain("2026-11-26");
  });

  it("valid sources → included as [[id]]", () => {
    const e = stored({ sources: ["rec_abc"] });
    const r = renderElement(e, new Set(["rec_abc"]));
    expect(r).toContain("[[rec_abc]]");
  });

  it("invalid sources → not included", () => {
    const e = stored({ sources: ["rec_missing"] });
    const r = renderElement(e, NO_IDS);
    expect(r).not.toContain("[[rec_missing]]");
  });

  it("❌ includes raison", () => {
    const e = stored({ statut: "❌", raison: "trop complexe" });
    expect(renderElement(e, NO_IDS)).toContain("trop complexe");
  });

  it("leçon erreur format", () => {
    const e = stored({
      kind: "leçon",
      sub_kind: "erreur",
      provenance: null,
      statut: "⚠️",
      texte: "Ne pas utiliser X",
    });
    const r = renderElement(e, NO_IDS);
    expect(r).toMatch(/^\[erreur\] ⚠️ Ne pas utiliser X/);
  });

  it("constaté has no statut in output", () => {
    const e = stored({ provenance: "constaté", statut: null, texte: "Fait observé" });
    const r = renderElement(e, NO_IDS);
    expect(r).toMatch(/^\[constaté\] Fait observé/);
  });

  it("tâche — no provenance prefix", () => {
    const e = stored({ kind: "tâche", provenance: null, statut: null, texte: "Faire X" });
    const r = renderElement(e, NO_IDS);
    expect(r).toMatch(/^Faire X/);
  });
});

// ── Link validation ───────────────────────────────────────────────────────────

describe("validateLinks", () => {
  it("valid links kept as [[id]]", () => {
    const result = validateLinks("see [[proj_coucou]]", SOME_IDS);
    expect(result).toContain("[[proj_coucou]]");
  });

  it("invalid links → plain text (not erased)", () => {
    const result = validateLinks("see [[proj_missing]]", SOME_IDS);
    expect(result).not.toContain("[[proj_missing]]");
    expect(result).toContain("proj_missing");
  });

  it("content inside code blocks not touched", () => {
    const content = "text ```[[invalid]]``` end";
    const result = validateLinks(content, NO_IDS);
    expect(result).toContain("[[invalid]]");
  });

  it("content inside inline code not touched", () => {
    const content = "use `[[invalid]]` here";
    const result = validateLinks(content, NO_IDS);
    expect(result).toContain("[[invalid]]");
  });

  it("mixed valid and invalid", () => {
    const content = "[[proj_coucou]] and [[proj_missing]] both";
    const result = validateLinks(content, SOME_IDS);
    expect(result).toContain("[[proj_coucou]]");
    expect(result).not.toContain("[[proj_missing]]");
    expect(result).toContain("proj_missing");
  });

  it("empty content unchanged", () => {
    expect(validateLinks("", NO_IDS)).toBe("");
  });
});

// ── Date from session, not ingestion date ─────────────────────────────────────

describe("llmToStored — date provenance", () => {
  it("stored date = session date, not today", () => {
    const elem = dec({ texte: "Décision historique" });
    const stored = llmToStored(elem, "2026-10-15", "rec_old");
    expect(stored.date).toBe("2026-10-15");
  });
});
