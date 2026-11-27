/**
 * Tests for element merge logic, coercion rules, and ID stability.
 */
import { describe, it, expect } from "vitest";
import {
  computeElementId,
  coerceElement,
  llmToStored,
  mergeElements,
  applyTaskClosures,
  applyDecisionReplacements,
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

// ── Task closure (taches_faites / taches_abandonnees) ─────────────────────────

describe("applyTaskClosures", () => {
  const openTask: StoredElement = {
    id: "tach_abc123",
    kind: "tâche",
    statut: null,
    texte: "Implémenter le module brain/",
    date: "2026-11-01",
    sources: ["rec_old"],
    projets: ["coucou"],
  };

  it("done task → statut ✅", () => {
    const result = applyTaskClosures([openTask], ["tach_abc123"], [], "2026-11-26", "rec_new");
    expect(result[0]!.statut).toBe("✅");
  });

  it("done task adds record to sources", () => {
    const result = applyTaskClosures([openTask], ["tach_abc123"], [], "2026-11-26", "rec_new");
    expect(result[0]!.sources).toContain("rec_old");
    expect(result[0]!.sources).toContain("rec_new");
  });

  it("done task updates date to session date", () => {
    const result = applyTaskClosures([openTask], ["tach_abc123"], [], "2026-11-26", "rec_new");
    expect(result[0]!.date).toBe("2026-11-26");
  });

  it("abandoned task → statut ❌ with raison", () => {
    const result = applyTaskClosures(
      [openTask],
      [],
      [{ id: "tach_abc123", raison: "plus nécessaire" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.statut).toBe("❌");
    expect(result[0]!.raison).toBe("plus nécessaire");
  });

  it("unknown ID → no change", () => {
    const result = applyTaskClosures([openTask], ["tach_unknown"], [], "2026-11-26", "rec_new");
    expect(result[0]!.statut).toBeNull();
  });

  it("already ✅ task → not changed by doneIds", () => {
    const doneTask = { ...openTask, statut: "✅" as const };
    const result = applyTaskClosures([doneTask], ["tach_abc123"], [], "2026-11-26", "rec_new");
    expect(result[0]!.statut).toBe("✅");
    // sources and date not updated again
    expect(result[0]!.sources).toHaveLength(1);
  });

  it("already ❌ task → not changed by abandonedItems", () => {
    const abandonedTask = { ...openTask, statut: "❌" as const, raison: "abandonné" };
    const result = applyTaskClosures(
      [abandonedTask],
      [],
      [{ id: "tach_abc123", raison: "nouvelle raison" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.raison).toBe("abandonné"); // unchanged
  });

  it("empty arrays → returns elements unchanged", () => {
    const result = applyTaskClosures([openTask], [], [], "2026-11-26", "rec_new");
    expect(result[0]!.statut).toBeNull();
    expect(result[0]!.sources).toHaveLength(1);
  });

  it("done + abandoned in same call — correct statut on each", () => {
    const task2: StoredElement = { ...openTask, id: "tach_other", texte: "Autre tâche" };
    const result = applyTaskClosures(
      [openTask, task2],
      ["tach_abc123"],
      [{ id: "tach_other", raison: "déprioritisé" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result.find((e) => e.id === "tach_abc123")!.statut).toBe("✅");
    expect(result.find((e) => e.id === "tach_other")!.statut).toBe("❌");
    expect(result.find((e) => e.id === "tach_other")!.raison).toBe("déprioritisé");
  });

  it("multiple elements — only matching one changed", () => {
    const other: StoredElement = { ...openTask, id: "tach_other", texte: "Autre tâche" };
    const result = applyTaskClosures([openTask, other], ["tach_abc123"], [], "2026-11-26", "rec_new");
    expect(result.find((e) => e.id === "tach_abc123")!.statut).toBe("✅");
    expect(result.find((e) => e.id === "tach_other")!.statut).toBeNull();
  });
});

// ── Decision replacement ──────────────────────────────────────────────────────

describe("applyDecisionReplacements", () => {
  const activeDec: StoredElement = {
    id: "dec_abc123",
    kind: "décision",
    statut: "✅",
    texte: "Utiliser l'ancienne approche",
    date: "2026-11-01",
    sources: ["rec_old"],
    projets: ["coucou"],
  };

  it("replaced decision → statut ❌, raison includes 'Remplacé par'", () => {
    const result = applyDecisionReplacements(
      [activeDec],
      [{ id: "dec_abc123", par: "dec_new456", raison: "meilleure approche" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.statut).toBe("❌");
    expect(result[0]!.raison).toContain("Remplacé par");
    expect(result[0]!.raison).toContain("dec_new456");
    expect(result[0]!.raison).toContain("meilleure approche");
  });

  it("replacement with par=null → statut ❌, raison = raw raison", () => {
    const result = applyDecisionReplacements(
      [activeDec],
      [{ id: "dec_abc123", par: null, raison: "abandonnée" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.statut).toBe("❌");
    expect(result[0]!.raison).toBe("abandonnée");
  });

  it("already ❌ decision → not changed", () => {
    const alreadyReplaced = { ...activeDec, statut: "❌" as const, raison: "ancienne raison" };
    const result = applyDecisionReplacements(
      [alreadyReplaced],
      [{ id: "dec_abc123", par: null, raison: "nouvelle raison" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.raison).toBe("ancienne raison"); // unchanged
  });

  it("ID not found → no change to any element", () => {
    const result = applyDecisionReplacements(
      [activeDec],
      [{ id: "dec_unknown", par: null, raison: "raison" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.statut).toBe("✅"); // unchanged
  });

  it("unrelated decision (not in replacements) → unchanged", () => {
    const unrelated: StoredElement = { ...activeDec, id: "dec_unrelated", texte: "Autre décision" };
    const result = applyDecisionReplacements(
      [activeDec, unrelated],
      [{ id: "dec_abc123", par: null, raison: "raison" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result.find((e) => e.id === "dec_unrelated")!.statut).toBe("✅"); // unchanged
  });

  it("adds record to sources on replacement", () => {
    const result = applyDecisionReplacements(
      [activeDec],
      [{ id: "dec_abc123", par: null, raison: "abandonnée" }],
      "2026-11-26",
      "rec_new"
    );
    expect(result[0]!.sources).toContain("rec_old");
    expect(result[0]!.sources).toContain("rec_new");
  });
});

// ── Dedup ─────────────────────────────────────────────────────────────────────

import { dedupElements, jaccardSimilarity } from "../src/elements.js";

describe("jaccardSimilarity", () => {
  it("identical texts → 1.0", () => {
    expect(jaccardSimilarity("redesign dashboard bento grid", "redesign dashboard bento grid")).toBe(1);
  });

  it("completely different texts → 0", () => {
    expect(jaccardSimilarity("deploy stripe webhook", "redesign bento grid")).toBe(0);
  });

  it("two similar bento decisions → above 0.6", () => {
    const a = "Redesign bento grid du dashboard analytics : KPI tiles gradient colorées, fiscal hero tile sombre, MoM revenue bars. Implémenté, déployé, puis git revert.";
    const b = "Redesign bento grid du dashboard analytics (KPI tiles gradient, fiscal hero tile, MoM bars style FinanceBento/Web3Bento). Revert après un commit.";
    expect(jaccardSimilarity(a, b)).toBeGreaterThanOrEqual(0.5);
  });

  it("different-kind elements with low overlap → below 0.6", () => {
    const a = "Utiliser TypeScript strict mode pour brain/";
    const b = "Migrate Stripe webhooks vers le nouveau format v3";
    expect(jaccardSimilarity(a, b)).toBeLessThan(0.6);
  });
});

describe("dedupElements", () => {
  it("merges near-duplicate decisions, keeps the one with more keywords", () => {
    const a: StoredElement = stored({
      id: "dec_aaa",
      texte: "Redesign bento grid du dashboard analytics : KPI tiles gradient colorées, fiscal hero tile sombre, MoM revenue bars. Implémenté, déployé, puis git revert.",
      keywords: ["redesign", "dashboard", "bento", "grid", "analytics", "KPI", "tiles", "gradient", "revert", "design"],
      sources: ["rec_1"],
    });
    const b: StoredElement = stored({
      id: "dec_bbb",
      texte: "Redesign bento grid du dashboard analytics (KPI tiles gradient, fiscal hero tile, MoM bars style FinanceBento/Web3Bento). Revert après un commit.",
      keywords: ["redesign", "design", "bento grid", "dashboard", "KPI"],
      sources: ["rec_2"],
    });

    // threshold=0.5 to match these two (Jaccard ~0.54)
    const { elements, merged } = dedupElements([a, b], 0.5);
    expect(merged).toBe(1);
    expect(elements).toHaveLength(1);
    expect(elements[0]!.sources).toContain("rec_1");
    expect(elements[0]!.sources).toContain("rec_2");
    expect((elements[0]!.keywords?.length ?? 0)).toBeGreaterThanOrEqual(5);
  });

  it("does not merge elements of different kinds", () => {
    const a: StoredElement = stored({ id: "dec_aaa", kind: "décision", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient" });
    const b: StoredElement = stored({ id: "fait_bbb", kind: "fait", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient" });
    const { elements, merged } = dedupElements([a, b], 0.5);
    expect(merged).toBe(0);
    expect(elements).toHaveLength(2);
  });

  it("does not merge ❌ with active element of same kind", () => {
    const a: StoredElement = stored({ id: "dec_aaa", statut: "❌", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient revert", projets: ["portfo"] });
    const b: StoredElement = stored({ id: "dec_bbb", statut: "✅", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient revert", projets: ["portfo"] });
    const { elements, merged } = dedupElements([a, b], 0.5);
    expect(merged).toBe(0);
    expect(elements).toHaveLength(2);
  });

  it("does not merge elements from different projects", () => {
    const a: StoredElement = stored({ id: "dec_aaa", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient revert", projets: ["portfo"] });
    const b: StoredElement = stored({ id: "dec_bbb", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient revert", projets: ["botan"] });
    const { elements, merged } = dedupElements([a, b], 0.5);
    expect(merged).toBe(0);
    expect(elements).toHaveLength(2);
  });

  it("merges global elements (projets=[]) regardless of project", () => {
    const a: StoredElement = stored({ id: "dec_aaa", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient revert", projets: [] });
    const b: StoredElement = stored({ id: "dec_bbb", texte: "Redesign bento grid du dashboard analytics KPI tiles gradient revert similaire", projets: [] });
    const { elements, merged } = dedupElements([a, b], 0.5);
    expect(merged).toBe(1);
    expect(elements).toHaveLength(1);
  });

  it("does not merge dissimilar elements of same kind", () => {
    const a: StoredElement = stored({ id: "dec_aaa", texte: "Utiliser TypeScript strict pour brain/" });
    const b: StoredElement = stored({ id: "dec_bbb", texte: "Migrer Stripe webhooks vers format v3" });
    const { elements, merged } = dedupElements([a, b], 0.5);
    expect(merged).toBe(0);
    expect(elements).toHaveLength(2);
  });

  it("is idempotent: running twice on result gives 0 merges", () => {
    const a: StoredElement = stored({
      id: "dec_aaa",
      texte: "Redesign bento grid du dashboard analytics : KPI tiles gradient colorées, fiscal hero tile sombre. Git revert.",
      keywords: ["redesign", "dashboard", "bento", "grid", "KPI"],
      sources: ["rec_1"],
      projets: ["portfo"],
    });
    const b: StoredElement = stored({
      id: "dec_bbb",
      texte: "Redesign bento grid du dashboard analytics (KPI tiles gradient, fiscal hero tile). Revert après un commit.",
      keywords: ["redesign", "dashboard", "bento"],
      sources: ["rec_2"],
      projets: ["portfo"],
    });
    const first = dedupElements([a, b], 0.5);
    const second = dedupElements(first.elements, 0.5);
    expect(second.merged).toBe(0);
  });

  it("journal records from/into/similarity", () => {
    const a: StoredElement = stored({
      id: "dec_aaa",
      texte: "Redesign bento grid du dashboard analytics : KPI tiles gradient colorées, fiscal hero tile sombre. Git revert.",
      keywords: ["redesign", "dashboard", "bento", "grid", "KPI"],
      sources: ["rec_1"],
      projets: ["portfo"],
    });
    const b: StoredElement = stored({
      id: "dec_bbb",
      texte: "Redesign bento grid du dashboard analytics (KPI tiles gradient, fiscal hero tile). Revert après un commit.",
      keywords: ["redesign", "dashboard", "bento"],
      sources: ["rec_2"],
      projets: ["portfo"],
    });
    const { journal } = dedupElements([a, b], 0.5);
    expect(journal).toHaveLength(1);
    expect(journal[0]!.similarity).toBeGreaterThan(0.5);
    expect([journal[0]!.from, journal[0]!.into]).toContain("dec_aaa");
    expect([journal[0]!.from, journal[0]!.into]).toContain("dec_bbb");
  });
});
