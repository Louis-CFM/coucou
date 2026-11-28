/**
 * Tests for Claude Desktop export ingestion:
 * - collectClaudeExport (JSON file, directory)
 * - formatConversationAsSessionCondensed (message mapping, masking, token estimation)
 * - sourceType propagation through llmToStored + FTS round-trip
 * - domain routing: remapDesktopProjects, getKnownProjectSlugs
 * - --limit regression: sort newest→oldest + slice
 */
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import {
  collectClaudeExport,
  formatConversationAsSessionCondensed,
  type DesktopConversation,
} from "../src/collect.js";
import { llmToStored, type LLMElement } from "../src/elements.js";
import { rebuildFts } from "../src/fts.js";
import {
  getKnownProjectSlugs,
  remapDesktopProjects,
  FIXED_DOMAINS,
} from "../src/desktop-routing.js";
import { Manifest } from "../src/manifest.js";
import type { BrainConfig } from "../src/config.js";
import type { StoredElement } from "../src/elements.js";

// ── Fixtures ──────────────────────────────────────────────────────────────────

const sampleConversation: DesktopConversation = {
  uuid: "conv-1234-abcd-efgh",
  name: "Architecture décision auth",
  created_at: "2026-01-15T10:00:00.000Z",
  updated_at: "2026-01-15T14:30:00.000Z",
  chat_messages: [
    {
      uuid: "msg-1",
      text: "Comment est-ce qu'on gère l'authentification dans ce projet ?",
      sender: "human",
      created_at: "2026-01-15T10:00:00.000Z",
      updated_at: "2026-01-15T10:00:00.000Z",
    },
    {
      uuid: "msg-2",
      text: "On utilise JWT avec refresh tokens. Les secrets sont dans le Keychain, jamais sur disque.",
      sender: "assistant",
      created_at: "2026-01-15T10:01:00.000Z",
      updated_at: "2026-01-15T10:01:00.000Z",
    },
    {
      uuid: "msg-3",
      text: "Et pour les tests ?",
      sender: "human",
      created_at: "2026-01-15T10:02:00.000Z",
      updated_at: "2026-01-15T10:02:00.000Z",
    },
    {
      uuid: "msg-4",
      text: "On mock le Keychain via un protocole injecté en test, pas de secret en dur.",
      sender: "assistant",
      created_at: "2026-01-15T10:03:00.000Z",
      updated_at: "2026-01-15T10:03:00.000Z",
    },
  ],
};

const emptyConversation: DesktopConversation = {
  uuid: "conv-empty",
  name: "Vide",
  created_at: "2026-01-16T10:00:00.000Z",
  updated_at: "2026-01-16T10:00:00.000Z",
  chat_messages: [],
};

// ── collectClaudeExport ───────────────────────────────────────────────────────

describe("collectClaudeExport — JSON file", () => {
  let tmpDir: string;
  let jsonPath: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-desktop-test-"));
    jsonPath = path.join(tmpDir, "conversations.json");
    fs.writeFileSync(
      jsonPath,
      JSON.stringify([sampleConversation, emptyConversation]),
      "utf8"
    );
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("reads conversations from a JSON file", () => {
    const convs = collectClaudeExport(jsonPath);
    expect(convs).toHaveLength(1); // emptyConversation filtered out
    expect(convs[0].uuid).toBe("conv-1234-abcd-efgh");
    expect(convs[0].name).toBe("Architecture décision auth");
  });

  it("filters out conversations with no messages", () => {
    const convs = collectClaudeExport(jsonPath);
    expect(convs.every((c) => c.chat_messages.length > 0)).toBe(true);
  });

  it("reads from a directory containing conversations.json", () => {
    const convs = collectClaudeExport(tmpDir);
    expect(convs).toHaveLength(1);
  });

  it("throws if conversations.json not found in directory", () => {
    const emptyDir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-empty-"));
    try {
      expect(() => collectClaudeExport(emptyDir)).toThrow("conversations.json not found");
    } finally {
      fs.rmSync(emptyDir, { recursive: true, force: true });
    }
  });

  it("handles single-object JSON (not array)", () => {
    fs.writeFileSync(jsonPath, JSON.stringify(sampleConversation), "utf8");
    const convs = collectClaudeExport(jsonPath);
    expect(convs).toHaveLength(1);
    expect(convs[0].uuid).toBe("conv-1234-abcd-efgh");
  });
});

// ── formatConversationAsSessionCondensed ──────────────────────────────────────

describe("formatConversationAsSessionCondensed", () => {
  it("maps sender:human → role:human, sender:assistant → role:claude", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.messages[0].role).toBe("human");
    expect(condensed.messages[1].role).toBe("claude");
    expect(condensed.messages[2].role).toBe("human");
    expect(condensed.messages[3].role).toBe("claude");
  });

  it("sets id to conversation uuid", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.id).toBe("conv-1234-abcd-efgh");
  });

  it("extracts date from updated_at", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.date).toBe("2026-01-15");
  });

  it("sets projectNameHint from conversation name", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.projectNameHint).toBe("Architecture décision auth");
  });

  it("produces a stable hash based on uuid+updated_at", () => {
    const c1 = formatConversationAsSessionCondensed(sampleConversation);
    const c2 = formatConversationAsSessionCondensed(sampleConversation);
    expect(c1.hash).toBe(c2.hash);
  });

  it("changes hash when updated_at changes", () => {
    const modified = { ...sampleConversation, updated_at: "2026-02-01T12:00:00.000Z" };
    const c1 = formatConversationAsSessionCondensed(sampleConversation);
    const c2 = formatConversationAsSessionCondensed(modified);
    expect(c1.hash).not.toBe(c2.hash);
  });

  it("estimates tokens from message content", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.estimatedTokens).toBeGreaterThan(0);
  });

  it("sets filesModified to empty array", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.filesModified).toEqual([]);
  });

  it("sets projectPath to 'desktop'", () => {
    const condensed = formatConversationAsSessionCondensed(sampleConversation);
    expect(condensed.projectPath).toBe("desktop");
  });

  it("masks secrets in messages", () => {
    const convWithSecret: DesktopConversation = {
      ...sampleConversation,
      uuid: "conv-secret",
      chat_messages: [
        {
          uuid: "msg-s",
          text: "STRIPE_KEY=" + "sk_" + "live_" + "x".repeat(24),
          sender: "human",
          created_at: "2026-01-15T10:00:00.000Z",
          updated_at: "2026-01-15T10:00:00.000Z",
        },
      ],
    };
    const condensed = formatConversationAsSessionCondensed(convWithSecret);
    expect(condensed.messages[0].text).not.toContain("sk_live_");
    expect(condensed.masked.length).toBeGreaterThan(0);
  });

  it("skips empty messages", () => {
    const convWithEmpty: DesktopConversation = {
      ...sampleConversation,
      uuid: "conv-empty-msgs",
      chat_messages: [
        {
          uuid: "msg-empty",
          text: "",
          sender: "human",
          created_at: "2026-01-15T10:00:00.000Z",
          updated_at: "2026-01-15T10:00:00.000Z",
        },
        {
          uuid: "msg-real",
          text: "Bonjour monde",
          sender: "assistant",
          created_at: "2026-01-15T10:01:00.000Z",
          updated_at: "2026-01-15T10:01:00.000Z",
        },
      ],
    };
    const condensed = formatConversationAsSessionCondensed(convWithEmpty);
    expect(condensed.messages).toHaveLength(1);
    expect(condensed.messages[0].role).toBe("claude");
  });
});

// ── sourceType in StoredElement ───────────────────────────────────────────────

describe("llmToStored — sourceType", () => {
  const baseElem: LLMElement = {
    kind: "décision",
    sub_kind: null,
    provenance: "décidé",
    statut: "✅",
    texte: "JWT avec refresh tokens pour l'authentification",
    nom: null,
    projets: ["nova"],
    remplace: null,
    raison: null,
    domaine: null,
    scope: "projet",
    keywords: ["jwt", "auth"],
    financial: false,
  };

  it("stored element has no sourceType by default", () => {
    const stored = llmToStored(baseElem, "2026-01-15", "rec_123");
    expect(stored.sourceType).toBeUndefined();
  });

  it("stored element has sourceType=desktop when specified", () => {
    const stored = llmToStored(baseElem, "2026-01-15", "rec_123", "desktop");
    expect(stored.sourceType).toBe("desktop");
  });

  it("stored element has sourceType=code when specified", () => {
    const stored = llmToStored(baseElem, "2026-01-15", "rec_123", "code");
    expect(stored.sourceType).toBe("code");
  });
});

// ── FTS sourceType column ─────────────────────────────────────────────────────

describe("FTS — source_type column", () => {
  let tmpDir: string;
  let brainPath: string;
  let config: BrainConfig;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-fts-desktop-"));
    brainPath = path.join(tmpDir, "CoucouBrain");
    fs.mkdirSync(path.join(brainPath, ".state", "proj"), { recursive: true });
    config = {
      brainPath,
      claudeProjectsPath: "~/.claude/projects",
      repoPaths: [],
      repoAliases: {},
      model: "claude-opus-4-5",
      language: "fr",
    } as unknown as BrainConfig;
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  function writeProjectState(id: string, elements: StoredElement[]): void {
    const stateDir = path.join(brainPath, ".state", "proj");
    fs.writeFileSync(
      path.join(stateDir, `${id}.json`),
      JSON.stringify({ id, elements }),
      "utf8"
    );
  }

  it("populates source_type from StoredElement.sourceType", () => {
    const codeElem: StoredElement = {
      id: "dec_code1",
      kind: "décision",
      texte: "Authentication utilise JWT tokens expirables",
      date: "2026-01-15",
      sources: ["rec_001"],
      projets: ["nova"],
      scope: "projet",
      keywords: ["jwt", "authentication", "tokens"],
    };
    const desktopElem: StoredElement = {
      id: "dec_desk1",
      kind: "décision",
      texte: "Deployment pipeline passes automated checks validation",
      date: "2026-01-15",
      sources: ["rec_002"],
      projets: ["nova"],
      scope: "projet",
      keywords: ["deployment", "pipeline", "checks"],
      sourceType: "desktop",
    };

    writeProjectState("proj_nova", [codeElem, desktopElem]);
    const { elements } = rebuildFts(config);
    expect(elements).toBe(2);

    // Query the FTS DB directly to check source_type values
    const Database = require("better-sqlite3");
    const db = new Database(path.join(brainPath, ".state", "fts.db"), { readonly: true });
    const rows = db.prepare(
      "SELECT elem_id, source_type FROM fts_elements ORDER BY elem_id"
    ).all() as Array<{ elem_id: string; source_type: string }>;
    db.close();

    const codeRow = rows.find((r) => r.elem_id === "dec_code1");
    const desktopRow = rows.find((r) => r.elem_id === "dec_desk1");

    expect(codeRow?.source_type).toBe("");      // undefined → stored as ""
    expect(desktopRow?.source_type).toBe("desktop");
  });
});

// ── remapDesktopProjects ──────────────────────────────────────────────────────

describe("remapDesktopProjects", () => {
  const known = new Set(["coucou", "portfo", "sbe-hub"]);
  const noMessages: Array<{ text: string }> = [];

  it("keeps known project slugs", () => {
    const { projects } = remapDesktopProjects(["coucou"], known, "test", noMessages);
    expect(projects).toContain("coucou");
  });

  it("keeps fixed domain slugs assigned by LLM", () => {
    // LLM picks "apprentissage" for a learning conversation
    const { projects } = remapDesktopProjects(["apprentissage"], known, "NVIDIA certs", noMessages);
    expect(projects).toContain("apprentissage");
  });

  it("keeps admin-et-argent domain assigned by LLM", () => {
    const { projects } = remapDesktopProjects(["admin-et-argent"], known, "salary", noMessages);
    expect(projects).toContain("admin-et-argent");
  });

  it("extracts people/X into extraPeople, not project page", () => {
    const { projects, extraPeople } = remapDesktopProjects(["people/enya"], known, "test", noMessages);
    expect(extraPeople).toContain("enya");
    expect(projects.some((p) => p.includes("enya"))).toBe(false);
  });

  it("extracts people-X slug into extraPeople", () => {
    const { extraPeople } = remapDesktopProjects(["people-frederic"], known, "test", noMessages);
    expect(extraPeople).toContain("frederic");
  });

  it("falls back to perso when LLM assigns unknown slug", () => {
    const { projects } = remapDesktopProjects(["certifications-nvidia"], known, "", noMessages);
    expect(projects[0]).toBe("perso");
  });

  it("always returns at least one project even with empty input", () => {
    const { projects } = remapDesktopProjects([], known, "test", noMessages);
    expect(projects).toEqual(["perso"]);
  });

  it("discards unknown projects off-list, keeps known ones", () => {
    const { projects } = remapDesktopProjects(["portfo", "some-random-thing"], known, "", noMessages);
    expect(projects).toContain("portfo");
    expect(projects).not.toContain("some-random-thing");
  });

  it("LLM can mix known project + fixed domain", () => {
    const { projects } = remapDesktopProjects(["coucou", "apprentissage"], known, "", noMessages);
    expect(projects).toContain("coucou");
    expect(projects).toContain("apprentissage");
  });

  it("FIXED_DOMAINS has 6 domains", () => {
    expect(FIXED_DOMAINS).toHaveLength(6);
    expect(FIXED_DOMAINS).toContain("perso");
    expect(FIXED_DOMAINS).toContain("admin-et-argent");
    expect(FIXED_DOMAINS).toContain("achats");
    expect(FIXED_DOMAINS).toContain("contenu-et-reseaux");
    expect(FIXED_DOMAINS).toContain("freelance");
    expect(FIXED_DOMAINS).toContain("apprentissage");
  });
});

// ── getKnownProjectSlugs ──────────────────────────────────────────────────────

describe("getKnownProjectSlugs", () => {
  let tmpDir: string;
  let brainPath: string;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-slugs-"));
    brainPath = path.join(tmpDir, "CoucouBrain");
    fs.mkdirSync(path.join(brainPath, ".state", "proj"), { recursive: true });
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("reads slug from proj_*.json filenames", () => {
    const stateDir = path.join(brainPath, ".state", "proj");
    fs.writeFileSync(path.join(stateDir, "proj_portfo.json"), "{}", "utf8");
    fs.writeFileSync(path.join(stateDir, "proj_sbe-hub.json"), "{}", "utf8");
    const slugs = getKnownProjectSlugs(brainPath);
    expect(slugs).toContain("portfo");
    expect(slugs).toContain("sbe-hub");
  });

  it("ignores non-proj_ files (lessons.json, louis.json)", () => {
    const stateDir = path.join(brainPath, ".state", "proj");
    fs.writeFileSync(path.join(stateDir, "lessons.json"), "{}", "utf8");
    fs.writeFileSync(path.join(stateDir, "louis.json"), "{}", "utf8");
    const slugs = getKnownProjectSlugs(brainPath);
    expect(slugs).not.toContain("lessons");
    expect(slugs).not.toContain("louis");
  });

  it("returns empty set when stateDir missing", () => {
    const slugs = getKnownProjectSlugs(path.join(tmpDir, "nonexistent"));
    expect(slugs.size).toBe(0);
  });
});

// ── --limit regression ────────────────────────────────────────────────────────

describe("--limit regression — desktop conversations", () => {
  let tmpDir: string;
  let brainPath: string;
  let config: BrainConfig;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-limit-"));
    brainPath = path.join(tmpDir, "CoucouBrain");
    fs.mkdirSync(path.join(brainPath, ".state", "proj"), { recursive: true });
    config = {
      brainPath,
      claudeProjectsPath: "~/.claude/projects",
      repoPaths: [],
      repoAliases: {},
      model: "claude-sonnet-4-6",
      language: "fr",
    } as unknown as BrainConfig;
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("slice(0, limit) gives correct count after sort", () => {
    const manifest = new Manifest(brainPath);

    // Upsert 8 conversations with different timestamps
    for (let i = 1; i <= 8; i++) {
      manifest.upsertDesktopConversation({
        uuid: `uuid-${i}`,
        updated_at: `2026-0${i < 10 ? i : i}-01T00:00:00.000Z`.replace("0100", "10"),
      });
    }

    const all = manifest.getPendingDesktopConversations()
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at)); // newest first

    expect(all.length).toBe(8);

    const limited = all.slice(0, 5);
    expect(limited.length).toBe(5);

    // Most recent should come first
    expect(limited[0]!.updated_at > limited[4]!.updated_at).toBe(true);

    manifest.close();
  });

  it("limit larger than total returns all", () => {
    const manifest = new Manifest(brainPath);
    for (let i = 1; i <= 3; i++) {
      manifest.upsertDesktopConversation({
        uuid: `uuid-${i}`,
        updated_at: `2026-01-0${i}T00:00:00.000Z`,
      });
    }
    const pending = manifest.getPendingDesktopConversations()
      .sort((a, b) => b.updated_at.localeCompare(a.updated_at));
    const limited = 10 ? pending.slice(0, 10) : pending; // limit=10 > total=3
    expect(limited.length).toBe(3);
    manifest.close();
  });
});
