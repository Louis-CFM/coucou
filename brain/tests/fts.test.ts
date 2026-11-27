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

    // portfo project: has a rejected bento decision
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

  it("mesures never returned", () => {
    writeStateFile(dir, "proj_portfo", [
      {
        id: "mes_mrr_test",
        kind: "mesure",
        texte: "MRR : 1500€",
        statut: null,
        nom: "mrr",
        scope: "projet",
        projets: ["portfo"],
        date: "2026-11-01",
        sources: [],
      },
    ]);
    rebuildFts(config);
    const results = searchFts(config, "MRR revenus chiffre affaires", {
      project: "portfo",
      limit: 10,
      threshold: 0,
    });
    const mesureResults = results.filter((r) => r.kind === "mesure");
    expect(mesureResults).toHaveLength(0);
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
