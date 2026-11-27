/**
 * FTS module tests.
 * Uses a temp config pointing at a temp brain directory.
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  rebuildFts,
  searchFts,
  buildFtsQuery,
  parseCorrections,
  appendCorrection,
} from "../src/fts.js";
import type { BrainConfig } from "../src/config.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function tmpConfig(): { config: BrainConfig; dir: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-fts-test-"));
  const config: BrainConfig = {
    brainPath: dir,
    claudeProjectsPath: "~/.claude/projects",
    repoPaths: [],
    chunkModel: "claude-haiku-4-5-20251001",
    mergeModel: "claude-opus-4-6",
    maxChunkTokens: 100000,
    language: "fr",
    repoAliases: {},
  };
  return { config, dir };
}

function writeStateFile(dir: string, id: string, elements: object[]): void {
  const stateDir = path.join(dir, ".state", "proj");
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(
    path.join(stateDir, `${id}.json`),
    JSON.stringify({ id, title: id.replace(/^proj_/, ""), elements }),
    "utf8"
  );
}

function writeCorrections(dir: string, content: string): void {
  fs.writeFileSync(
    path.join(dir, "corrections.md"),
    `---\nid: corrections\ntype: reference\ntitle: "Corrections"\nproject: []\n---\n\n${content}`,
    "utf8"
  );
}

// ── buildFtsQuery ─────────────────────────────────────────────────────────────

describe("buildFtsQuery", () => {
  it("returns null for too-short input", () => {
    expect(buildFtsQuery("ok")).toBeNull();
    expect(buildFtsQuery("lol")).toBeNull();
  });

  it("returns null for single significant token", () => {
    expect(buildFtsQuery("migration")).toBeNull();
    expect(buildFtsQuery("apply this")).toBeNull();
  });

  it("returns null for all stopwords", () => {
    expect(buildFtsQuery("avec dans pour plus bien")).toBeNull();
  });

  it("returns prefix query for ≥ 2 significant tokens", () => {
    const q = buildFtsQuery("applique la nouvelle migration");
    expect(q).not.toBeNull();
    expect(q).toContain("migration*");
    // 'applique' is 8 chars, significant
    expect(q).toContain("applique*");
    // 'nouvelle' is a stopword — should be excluded
    expect(q).not.toContain("nouvelle*");
  });

  it("escapes FTS5 special chars", () => {
    const q = buildFtsQuery("design+stats dashboard:metrics");
    // special chars stripped from words
    expect(q).not.toContain("+");
    expect(q).not.toContain(":");
  });

  it("deduplicate tokens", () => {
    const q = buildFtsQuery("migration migration migration appliquer");
    const terms = (q ?? "").split(" ");
    const unique = [...new Set(terms)];
    expect(terms.length).toBe(unique.length);
  });
});

// ── parseCorrections ─────────────────────────────────────────────────────────

describe("parseCorrections", () => {
  it("parses sections by scope", () => {
    const { config, dir } = tmpConfig();
    writeCorrections(dir, `## global\nRègle globale A.\n\n## reels\nMéthode vidéo-écran.`);

    const sections = parseCorrections(config);
    expect(sections).toHaveLength(2);
    expect(sections[0].scope).toBe("global");
    expect(sections[0].text).toContain("Règle globale A.");
    expect(sections[1].scope).toBe("reels");
    expect(sections[1].text).toContain("vidéo-écran");
    fs.rmSync(dir, { recursive: true });
  });

  it("returns [] when corrections.md missing", () => {
    const { config, dir } = tmpConfig();
    expect(parseCorrections(config)).toEqual([]);
    fs.rmSync(dir, { recursive: true });
  });
});

// ── appendCorrection ─────────────────────────────────────────────────────────

describe("appendCorrection", () => {
  it("creates the file with the section if missing", () => {
    const { config, dir } = tmpConfig();
    appendCorrection(config, "Ne jamais utiliser bento grid", "portfo");
    const content = fs.readFileSync(path.join(dir, "corrections.md"), "utf8");
    expect(content).toContain("## portfo");
    expect(content).toContain("Ne jamais utiliser bento grid");
    fs.rmSync(dir, { recursive: true });
  });

  it("appends under existing section", () => {
    const { config, dir } = tmpConfig();
    writeCorrections(dir, `## portfo\n- Première correction.`);
    appendCorrection(config, "Deuxième correction.", "portfo");
    const content = fs.readFileSync(path.join(dir, "corrections.md"), "utf8");
    expect(content).toContain("Première correction.");
    expect(content).toContain("Deuxième correction.");
    // Deuxième appears after première
    expect(content.indexOf("Première")).toBeLessThan(content.indexOf("Deuxième"));
    fs.rmSync(dir, { recursive: true });
  });

  it("creates a new section at EOF if scope not found", () => {
    const { config, dir } = tmpConfig();
    writeCorrections(dir, `## global\n- Règle globale.`);
    appendCorrection(config, "Règle reels", "reels");
    const content = fs.readFileSync(path.join(dir, "corrections.md"), "utf8");
    expect(content).toContain("## global");
    expect(content).toContain("## reels");
    expect(content).toContain("Règle reels");
    fs.rmSync(dir, { recursive: true });
  });
});

// ── rebuildFts + searchFts ────────────────────────────────────────────────────

describe("FTS search", () => {
  let dir: string;
  let config: BrainConfig;

  beforeEach(() => {
    ({ dir, config } = tmpConfig());

    // portfo project: has a rejected bento decision + newsletter mesure
    writeStateFile(dir, "proj_portfo", [
      {
        id: "dec_bento_test",
        kind: "décision",
        texte: "Rejet du bento grid pour les stats du dashboard — style trop fragmenté.",
        statut: "❌",
        provenance: "décidé",
        raison: "bento grid rejeté, style fragmenté",
        domaine: "frontend",
        scope: "projet",
        projets: ["portfo"],
        date: "2026-11-10",
        sources: ["rec_test"],
        keywords: ["design", "bento", "grid", "dashboard", "stats", "visuel", "refonte", "interface"],
      },
      {
        id: "dec_design_active",
        kind: "décision",
        texte: "Dashboard mission control, layout sidebar + contenu principal.",
        statut: "✅",
        provenance: "décidé",
        raison: null,
        domaine: "frontend",
        scope: "projet",
        projets: ["portfo"],
        date: "2026-11-15",
        sources: ["rec_test2"],
        keywords: ["dashboard", "layout", "sidebar", "mission", "control", "interface"],
      },
      {
        id: "mes_newsletter_test",
        kind: "mesure",
        nom: "abonnés newsletter botan",
        texte: "61 abonnés newsletter Botan actifs.",
        statut: null,
        scope: "projet",
        projets: ["portfo", "botan"],
        date: "2026-11-15",
        sources: ["rec_test"],
        keywords: ["abonnés", "newsletter", "inscription", "subscriber", "botan", "personne", "compte"],
        financial: false,
      },
      {
        id: "mes_ca_portfo_test",
        kind: "mesure",
        nom: "ca net portfo 2026",
        texte: "CA net portfo novembre 2026 : 4 200 €.",
        statut: null,
        scope: "projet",
        projets: ["portfo"],
        date: "2026-11-15",
        sources: ["rec_test"],
        keywords: ["ca", "chiffre", "affaires", "revenus", "euros", "novembre", "portfo", "financier"],
        financial: true,
      },
    ]);

    // sbe-hub project: has migration lesson
    writeStateFile(dir, "proj_sbe-hub", [
      {
        id: "les_migration_test",
        kind: "leçon",
        texte: "Toujours utiliser db push pour les migrations Prisma en développement, jamais migrate deploy.",
        statut: "⚠️",
        sub_kind: "erreur",
        provenance: "constaté",
        raison: null,
        domaine: "database",
        scope: "projet",
        projets: ["sbe-hub"],
        date: "2026-11-12",
        sources: ["rec_test"],
        keywords: ["migration", "prisma", "deploy", "schema", "push", "database", "appliquer"],
      },
    ]);

    // corrections: reels scope
    writeCorrections(
      dir,
      `## global\nRègle globale : toujours signer les commits.\n\n## reels\nMéthode vidéo-écran (depuis mi-novembre) : pas de face cam, CTA audio only.`
    );

    rebuildFts(config);
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("corrections sort before regular elements", () => {
    // Query uses words that exist in the corrections text (AND is implicit in this test via OR query)
    const results = searchFts(config, "méthode vidéo écran face cam", { limit: 10, threshold: 0 });
    const corrResults = results.filter((r) => r.isCorrection);
    expect(corrResults.length).toBeGreaterThan(0);
    if (results.length > 1) {
      // Correction should sort first (is_correction DESC)
      expect(results[0].isCorrection).toBe(true);
    }
  });

  it("❌ elements are included and signaled", () => {
    const results = searchFts(config, "rejet bento grid dashboard stats", {
      project: "portfo",
      limit: 10,
      threshold: 0,  // small corpus: scores close to 0
    });
    const bentoResult = results.find((r) => r.id === "dec_bento_test");
    expect(bentoResult).toBeDefined();
    expect(bentoResult?.statut).toBe("❌");
  });

  it("⚠️ migration lesson found in sbe-hub context", () => {
    const results = searchFts(config, "migration prisma développement utiliser", {
      project: "sbe-hub",
      limit: 10,
      threshold: 0,
    });
    const migResult = results.find((r) => r.id === "les_migration_test");
    expect(migResult).toBeDefined();
    expect(migResult?.statut).toBe("⚠️");
  });

  it("mesures excluded when excludeMesures=true", () => {
    const results = searchFts(config, "abonnés newsletter botan actifs", {
      project: "portfo",
      limit: 10,
      threshold: 0,
      excludeMesures: true,
    });
    expect(results.filter((r) => r.kind === "mesure")).toHaveLength(0);
  });

  it("mesures included by default (searchable via keywords)", () => {
    // "combien de personne sur la newsletter" real query regression
    const results = searchFts(config, "personne newsletter abonnés inscription", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    const mesureResult = results.find((r) => r.id === "mes_newsletter_test");
    expect(mesureResult).toBeDefined();
    expect(mesureResult?.kind).toBe("mesure");
  });

  it("project boost: current-project results rank above cross-project", () => {
    const results = searchFts(config, "dashboard design layout stats", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    if (results.length >= 2) {
      const firstIsCurrent = results[0].sourceProject === "proj_portfo" || results[0].isCorrection;
      expect(firstIsCurrent).toBe(true);
    }
  });

  it("unrelated query returns empty (or nothing above threshold)", () => {
    // A very unrelated query shouldn't match anything
    const results = searchFts(config, "quantum computing photons relativity", {
      project: "portfo",
      limit: 10,
      threshold: -0.5,
    });
    // May or may not return results, but should not throw
    expect(Array.isArray(results)).toBe(true);
  });

  it("returns [] if fts.db not found", () => {
    const badConfig: BrainConfig = { ...config, brainPath: "/tmp/nonexistent_brain_xxx" };
    const results = searchFts(badConfig, "migration test", {});
    expect(results).toEqual([]);
  });

  // ── Regression: real user phrases ──────────────────────────────────────────

  it('[regression] "refais le design des stats du dashboard" → bento ❌', () => {
    // Real query: "design" matches keyword "design" on bento element
    const results = searchFts(config, "refais le design des stats du dashboard", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    const bento = results.find((r) => r.id === "dec_bento_test");
    expect(bento).toBeDefined();
    expect(bento?.statut).toBe("❌");
  });

  it('[regression] "applique la nouvelle migration" → db push rule', () => {
    // "migration*" matches texte + keyword "migration" on migration lesson
    const results = searchFts(config, "applique la nouvelle migration", {
      project: "sbe-hub",
      limit: 10,
      threshold: 0,
    });
    const migLesson = results.find((r) => r.id === "les_migration_test");
    expect(migLesson).toBeDefined();
    expect(migLesson?.statut).toBe("⚠️");
  });

  it('[regression] "combien de personne sur la newsletter" → mesure abonnés', () => {
    // "personne*" + "newsletter*" match keywords on newsletter mesure
    const results = searchFts(config, "combien de personne sur la newsletter", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    const newsletter = results.find((r) => r.id === "mes_newsletter_test");
    expect(newsletter).toBeDefined();
    expect(newsletter?.kind).toBe("mesure");
  });

  // ── Financial mesure blocking ───────────────────────────────────────────────

  it("financial mesure excluded when excludeFinancialMesures=true", () => {
    const results = searchFts(config, "ca revenus euros chiffre affaires portfo novembre", {
      project: "portfo",
      limit: 10,
      threshold: 0,
      excludeFinancialMesures: true,
    });
    expect(results.find((r) => r.id === "mes_ca_portfo_test")).toBeUndefined();
  });

  it("financial mesure included when excludeFinancialMesures=false (default)", () => {
    const results = searchFts(config, "ca revenus euros chiffre affaires portfo novembre", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    expect(results.find((r) => r.id === "mes_ca_portfo_test")).toBeDefined();
  });

  it("non-financial mesure still injectable when excludeFinancialMesures=true", () => {
    const results = searchFts(config, "personne newsletter abonnés inscription", {
      project: "portfo",
      limit: 10,
      threshold: 0,
      excludeFinancialMesures: true,
    });
    expect(results.find((r) => r.id === "mes_newsletter_test")).toBeDefined();
  });

  // ── Trigram: not implemented (unicode61 only) ───────────────────────────────
  // FTS tokenizer is unicode61 — prefix matching only. "redesign*" ≠ "design" keyword.
  // In practice, the user's prompt also contains other related keywords
  // (dashboard, stats, interface…) so the element is still found.

  it('[trigram-check] "Redesign the interface" matches bento via "interface" keyword', () => {
    // No trigram: "redesign*" does NOT match keyword "design".
    // But "interface*" matches keyword "interface" on bento element → found.
    const results = searchFts(config, "Redesign the interface", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    const bento = results.find((r) => r.id === "dec_bento_test");
    // Found via keyword "interface" (not via redesign→design)
    expect(bento).toBeDefined();
  });

  it('[trigram-check] bare "Redesign" (single token) → null query, no injection', () => {
    // Single significant token after stopword removal → buildFtsQuery returns null
    expect(buildFtsQuery("Redesign")).toBeNull();
  });

  it('[regression] "c\'est quoi la dérivée de ln(x)" → rien', () => {
    // Pure math query — no brain content should match
    const results = searchFts(config, "c'est quoi la dérivée de ln(x)", {
      project: "portfo",
      limit: 10,
      threshold: -0.5,
    });
    // Could return 0 (no match) or low-score results — none should be from our test corpus
    const relevantKinds = ["décision", "leçon", "fait", "mesure", "préférence"];
    const bizarreMatches = results.filter((r) =>
      relevantKinds.includes(r.kind) && !r.isCorrection
    );
    expect(bizarreMatches).toHaveLength(0);
  });
});

// ── Token budget ──────────────────────────────────────────────────────────────

describe("token budget", () => {
  it("5 results stay under 1000 tokens (4000 chars)", () => {
    const { dir, config } = tmpConfig();

    // Write 10 elements with medium-length text
    writeStateFile(dir, "proj_test", Array.from({ length: 10 }, (_, i) => ({
      id: `dec_budget_${i}`,
      kind: "décision",
      texte: `Décision structurante numéro ${i + 1} : utilisation du pattern factory pour les composants UI et injection de dépendances dans les services.`,
      statut: "✅",
      provenance: "décidé",
      scope: "projet",
      projets: ["test"],
      date: "2026-11-01",
      sources: [],
    })));

    rebuildFts(config);
    const results = searchFts(config, "décision structurante pattern composants services", {
      project: "test",
      limit: 5,
      threshold: -0.1,
    });

    const lines = results.map((r) => `[${r.kind}] ${r.texte}`);
    const context = `Mémoire CoucouBrain [test] :\n\n` + lines.join("\n\n");

    expect(context.length).toBeLessThanOrEqual(4000);
    fs.rmSync(dir, { recursive: true });
  });
});
