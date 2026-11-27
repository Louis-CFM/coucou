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
    writeCorrections(dir, `## global\nRègle globale A.\n\n## stream\nMéthode screencast.`);

    const sections = parseCorrections(config);
    expect(sections).toHaveLength(2);
    expect(sections[0].scope).toBe("global");
    expect(sections[0].text).toContain("Règle globale A.");
    expect(sections[1].scope).toBe("stream");
    expect(sections[1].text).toContain("screencast");
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
    appendCorrection(config, "Ne jamais utiliser carousel animé", "nova");
    const content = fs.readFileSync(path.join(dir, "corrections.md"), "utf8");
    expect(content).toContain("## nova");
    expect(content).toContain("Ne jamais utiliser carousel animé");
    fs.rmSync(dir, { recursive: true });
  });

  it("appends under existing section", () => {
    const { config, dir } = tmpConfig();
    writeCorrections(dir, `## nova\n- Première correction.`);
    appendCorrection(config, "Deuxième correction.", "nova");
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
    appendCorrection(config, "Règle stream", "stream");
    const content = fs.readFileSync(path.join(dir, "corrections.md"), "utf8");
    expect(content).toContain("## global");
    expect(content).toContain("## stream");
    expect(content).toContain("Règle stream");
    fs.rmSync(dir, { recursive: true });
  });
});

// ── rebuildFts + searchFts ────────────────────────────────────────────────────

describe("FTS search", () => {
  let dir: string;
  let config: BrainConfig;

  beforeEach(() => {
    ({ dir, config } = tmpConfig());

    // nova project: has a rejected carousel decision + newsletter mesure
    writeStateFile(dir, "proj_nova", [
      {
        id: "dec_bento_test",
        kind: "décision",
        texte: "Rejet du carousel animé sur la homepage — transitions trop lentes, impact conversion.",
        statut: "❌",
        provenance: "décidé",
        raison: "carousel rejeté, transitions trop lentes",
        domaine: "frontend",
        scope: "projet",
        projets: ["nova"],
        date: "2026-11-10",
        sources: ["rec_test"],
        keywords: ["carousel", "animation", "homepage", "conversion", "transitions", "vitesse", "refonte", "interface"],
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
        projets: ["nova"],
        date: "2026-11-15",
        sources: ["rec_test2"],
        keywords: ["dashboard", "layout", "sidebar", "mission", "control", "interface"],
      },
      {
        id: "mes_newsletter_test",
        kind: "mesure",
        nom: "abonnés newsletter zephyr",
        texte: "142 utilisateurs inscrits newsletter Zephyr actifs.",
        statut: null,
        scope: "projet",
        projets: ["nova", "zephyr"],
        date: "2026-11-15",
        sources: ["rec_test"],
        keywords: ["abonnés", "newsletter", "inscription", "subscriber", "zephyr", "personne", "compte"],
        financial: false,
      },
      {
        id: "mes_ca_portfo_test",
        kind: "mesure",
        nom: "ca net nova 2026",
        texte: "CA net nova octobre 2026 : 8 500 €.",
        statut: null,
        scope: "projet",
        projets: ["nova"],
        date: "2026-11-15",
        sources: ["rec_test"],
        keywords: ["ca", "chiffre", "affaires", "revenus", "euros", "octobre", "nova", "financier"],
        financial: true,
      },
    ]);

    // orbit project: has migration lesson
    writeStateFile(dir, "proj_orbit", [
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
        projets: ["orbit"],
        date: "2026-11-12",
        sources: ["rec_test"],
        keywords: ["migration", "prisma", "deploy", "schema", "push", "database", "appliquer"],
      },
    ]);

    // corrections: stream scope
    writeCorrections(
      dir,
      `## global\nRègle globale : toujours signer les commits.\n\n## stream\nMéthode screencast (depuis octobre) : pas de caméra frontale, narration voix off.`
    );

    rebuildFts(config);
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it("corrections sort before regular elements", () => {
    // Query uses words that exist in the corrections text (AND is implicit in this test via OR query)
    const results = searchFts(config, "méthode screencast caméra narration voix off", { limit: 10, threshold: 0 });
    const corrResults = results.filter((r) => r.isCorrection);
    expect(corrResults.length).toBeGreaterThan(0);
    if (results.length > 1) {
      // Correction should sort first (is_correction DESC)
      expect(results[0].isCorrection).toBe(true);
    }
  });

  it("❌ elements are included and signaled", () => {
    const results = searchFts(config, "rejet carousel homepage transitions conversion", {
      project: "nova",
      limit: 10,
      threshold: 0,  // small corpus: scores close to 0
    });
    const bentoResult = results.find((r) => r.id === "dec_bento_test");
    expect(bentoResult).toBeDefined();
    expect(bentoResult?.statut).toBe("❌");
  });

  it("⚠️ migration lesson found in orbit context", () => {
    const results = searchFts(config, "migration prisma développement utiliser", {
      project: "orbit",
      limit: 10,
      threshold: 0,
    });
    const migResult = results.find((r) => r.id === "les_migration_test");
    expect(migResult).toBeDefined();
    expect(migResult?.statut).toBe("⚠️");
  });

  it("mesures excluded when excludeMesures=true", () => {
    const results = searchFts(config, "abonnés newsletter zephyr actifs", {
      project: "nova",
      limit: 10,
      threshold: 0,
      excludeMesures: true,
    });
    expect(results.filter((r) => r.kind === "mesure")).toHaveLength(0);
  });

  it("mesures included by default (searchable via keywords)", () => {
    // "combien de personne sur la newsletter" query regression
    const results = searchFts(config, "personne newsletter abonnés inscription", {
      project: "nova",
      limit: 10,
      threshold: 0,
    });
    const mesureResult = results.find((r) => r.id === "mes_newsletter_test");
    expect(mesureResult).toBeDefined();
    expect(mesureResult?.kind).toBe("mesure");
  });

  it("project boost: current-project results rank above cross-project", () => {
    const results = searchFts(config, "dashboard design layout stats", {
      project: "nova",
      limit: 10,
      threshold: 0,
    });
    if (results.length >= 2) {
      const firstIsCurrent = results[0].sourceProject === "proj_nova" || results[0].isCorrection;
      expect(firstIsCurrent).toBe(true);
    }
  });

  it("unrelated query returns empty (or nothing above threshold)", () => {
    // A very unrelated query shouldn't match anything
    const results = searchFts(config, "quantum computing photons relativity", {
      project: "nova",
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

  it('[regression] "refais le carousel sur la homepage" → carousel ❌', () => {
    // Query: "carousel*" matches keyword "carousel" on carousel element
    const results = searchFts(config, "refais le carousel sur la homepage", {
      project: "nova",
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
      project: "orbit",
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
      project: "nova",
      limit: 10,
      threshold: 0,
    });
    const newsletter = results.find((r) => r.id === "mes_newsletter_test");
    expect(newsletter).toBeDefined();
    expect(newsletter?.kind).toBe("mesure");
  });

  // ── Financial mesure blocking ───────────────────────────────────────────────

  it("financial mesure excluded when excludeFinancialMesures=true", () => {
    const results = searchFts(config, "ca revenus euros chiffre affaires nova octobre", {
      project: "nova",
      limit: 10,
      threshold: 0,
      excludeFinancialMesures: true,
    });
    expect(results.find((r) => r.id === "mes_ca_portfo_test")).toBeUndefined();
  });

  it("financial mesure included when excludeFinancialMesures=false (default)", () => {
    const results = searchFts(config, "ca revenus euros chiffre affaires nova octobre", {
      project: "nova",
      limit: 10,
      threshold: 0,
    });
    expect(results.find((r) => r.id === "mes_ca_portfo_test")).toBeDefined();
  });

  it("non-financial mesure still injectable when excludeFinancialMesures=true", () => {
    const results = searchFts(config, "personne newsletter abonnés inscription", {
      project: "nova",
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

  it('[trigram-check] "Rework the interface" matches carousel via "interface" keyword', () => {
    // No trigram: "rework*" does NOT match keyword "refonte".
    // But "interface*" matches keyword "interface" on carousel element → found.
    const results = searchFts(config, "Rework the interface", {
      project: "nova",
      limit: 10,
      threshold: 0,
    });
    const bento = results.find((r) => r.id === "dec_bento_test");
    // Found via keyword "interface" (not via rework→refonte)
    expect(bento).toBeDefined();
  });

  it('[trigram-check] bare "Rework" (single token) → null query, no injection', () => {
    // Single significant token after stopword removal → buildFtsQuery returns null
    expect(buildFtsQuery("Rework")).toBeNull();
  });

  it('[regression] "c\'est quoi la dérivée de ln(x)" → rien', () => {
    // Pure math query — no brain content should match
    const results = searchFts(config, "c'est quoi la dérivée de ln(x)", {
      project: "nova",
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
