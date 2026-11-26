/**
 * LLM digest — calls `claude -p` from the brain's digestion directory.
 * Never called in --dry-run mode.
 */
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { z } from "zod";
import { digestionDir } from "./config.js";
import { chunkMessages, messagesToText, type Chunk } from "./chunk.js";
import type { SessionCondensed, RepoCondensed } from "./collect.js";
import type { BrainConfig } from "./config.js";

// ── Zod schema for session digest ────────────────────────────────────────────

const ProvenanceSchema = z.enum(["décidé", "proposé", "constaté"]);
const StatusSchema = z.enum(["✅", "❌", "⚠️"]);

const DecisionSchema = z.object({
  content: z.string(),
  provenance: ProvenanceSchema,
  status: StatusSchema,
  replaces: z.string().nullable().default(null),
});

const LessonSchema = z.object({
  content: z.string(),
  type: z.enum(["erreur", "leçon"]),
  status: StatusSchema,
});

export const SessionDigestSchema = z.object({
  summary: z.string().min(1),
  projects: z.array(z.string()).min(1),
  decisions: z.array(DecisionSchema).default([]),
  facts: z.array(z.string()).default([]),
  errors_and_lessons: z.array(LessonSchema).default([]),
  open_tasks: z.array(z.string()).default([]),
  files_touched: z.array(z.string()).default([]),
});

export type SessionDigest = z.infer<typeof SessionDigestSchema>;

// ── Claude runner ─────────────────────────────────────────────────────────────

function runClaude(
  prompt: string,
  model: string,
  cwd: string,
  timeoutMs = 180_000
): string {
  const result = spawnSync(
    "claude",
    ["--print", "--output-format", "json", "--model", model],
    {
      input: prompt,
      cwd,
      timeout: timeoutMs,
      maxBuffer: 20 * 1024 * 1024,
      encoding: "utf8",
    }
  );

  if (result.error) throw new Error(`claude spawn error: ${result.error.message}`);
  if (result.status !== 0) {
    const stderr = result.stderr?.toString().slice(0, 500) ?? "";
    throw new Error(`claude exited ${result.status}: ${stderr}`);
  }

  // --output-format json wraps the response in a JSON envelope
  // The actual text content is in the "result" field
  try {
    const envelope = JSON.parse(result.stdout);
    return envelope.result ?? result.stdout;
  } catch {
    return result.stdout;
  }
}

/** Ensure the digestion directory exists and return its path */
function ensureDigestionDir(config: BrainConfig): string {
  const dir = digestionDir(config);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// ── Session chunk summarizer ──────────────────────────────────────────────────

function buildChunkSummaryPrompt(chunk: Chunk, sessionDate: string, projectHint: string): string {
  return `Tu résumes un morceau d'une session Claude Code (${chunk.index + 1}/${chunk.total}).
Date de la session : ${sessionDate}. Projet supposé : ${projectHint}.

Résume ce morceau en 300 à 500 mots en français. Inclus : ce qui a été fait, les décisions prises, les problèmes rencontrés, les fichiers importants mentionnés. Sois factuel et précis. Ne déduis rien qui n'est pas dans le texte.

MORCEAU :
${chunk.text}

Résumé :`;
}

function buildFinalDigestPrompt(
  summaries: string[],
  sessionDate: string,
  projectHint: string
): string {
  const summaryBlock = summaries
    .map((s, i) => `### Morceau ${i + 1}\n${s}`)
    .join("\n\n");

  return buildDigestPromptFromText(summaryBlock, sessionDate, projectHint);
}

function buildDigestPromptFromText(text: string, sessionDate: string, projectHint: string): string {
  return `Tu analyses une session Claude Code du ${sessionDate} (projet supposé : ${projectHint}).

RÈGLES DE PROVENANCE STRICTES :
- "décidé" = Louis (l'utilisateur) l'a décidé ou validé explicitement par un message de confirmation
- "proposé" = Claude l'a suggéré, mais Louis n'a pas dit "oui", "ok", "vas-y" ou équivalent
- "constaté" = fait observé (build OK, bug reproduit, test passé, erreur affichée...)
⚠️ Une suggestion de Claude ne devient JAMAIS "décidé" parce que Louis n'a pas dit non.

RÈGLES DE STATUT :
- ✅ = décision validée et encore en vigueur
- ❌ = décision abandonnée ou remplacée (ajoute la raison)
- ⚠️ = erreur ou piège à ne pas reproduire

SESSION :
${text}

Réponds UNIQUEMENT avec le JSON ci-dessous, sans markdown, sans commentaire, sans texte avant ou après :
{
  "summary": "3 à 5 phrases décrivant ce qui s'est passé",
  "projects": ["slug-du-projet"],
  "decisions": [
    {"content": "...", "provenance": "décidé|proposé|constaté", "status": "✅|❌|⚠️", "replaces": null}
  ],
  "facts": ["prix, versions, noms, chemins, comptes de service importants..."],
  "errors_and_lessons": [
    {"content": "...", "type": "erreur|leçon", "status": "✅|❌|⚠️"}
  ],
  "open_tasks": ["tâche laissée en cours ou à faire..."],
  "files_touched": ["chemin/du/fichier.ts"]
}`;
}

// ── Main session digest ────────────────────────────────────────────────────────

export async function digestSession(
  session: SessionCondensed,
  config: BrainConfig
): Promise<SessionDigest> {
  const cwd = ensureDigestionDir(config);
  const chunks = chunkMessages(session.messages, config.maxChunkTokens);

  let digestText: string;

  if (chunks.length === 1) {
    // Single call
    const prompt = buildDigestPromptFromText(
      chunks[0]!.text,
      session.date,
      session.projectNameHint
    );
    digestText = runClaude(prompt, config.mergeModel, cwd);
  } else {
    // Multi-chunk: summarize each, then synthesize
    console.log(`  Session longue : ${chunks.length} morceaux`);
    const summaries: string[] = [];
    for (const chunk of chunks) {
      console.log(`    Morceau ${chunk.index + 1}/${chunk.total} (~${chunk.estimatedTokens} tokens)…`);
      const prompt = buildChunkSummaryPrompt(chunk, session.date, session.projectNameHint);
      const summary = runClaude(prompt, config.chunkModel, cwd);
      summaries.push(summary);
    }
    const finalPrompt = buildFinalDigestPrompt(summaries, session.date, session.projectNameHint);
    digestText = runClaude(finalPrompt, config.mergeModel, cwd);
  }

  // Parse and validate
  return parseDigest(digestText);
}

function parseDigest(raw: string): SessionDigest {
  // Strip any accidental markdown fences
  const cleaned = raw.replace(/^```(?:json)?\s*/m, "").replace(/\s*```\s*$/m, "").trim();

  let parsed: unknown;
  try {
    parsed = JSON.parse(cleaned);
  } catch (e) {
    throw new Error(`JSON invalide dans la réponse du modèle: ${(e as Error).message}\n${cleaned.slice(0, 300)}`);
  }

  const result = SessionDigestSchema.safeParse(parsed);
  if (!result.success) {
    throw new Error(`Schéma invalide: ${result.error.message}\n${JSON.stringify(parsed, null, 2).slice(0, 500)}`);
  }

  return result.data;
}

/** Retry wrapper — one retry on parse failure */
export async function digestSessionWithRetry(
  session: SessionCondensed,
  config: BrainConfig
): Promise<SessionDigest> {
  try {
    return await digestSession(session, config);
  } catch (firstError) {
    console.warn(`  Retry après erreur: ${(firstError as Error).message.slice(0, 100)}`);
    try {
      return await digestSession(session, config);
    } catch (secondError) {
      throw new Error(
        `Digest échoué après 2 tentatives pour ${session.id}: ${(secondError as Error).message}`
      );
    }
  }
}

// ── Repo digest (simpler — just project page generation) ────────────────────

export interface RepoDigest {
  slug: string;
  name: string;
  goal: string;
  stack: string;
  remote: string | null;
  recentActivity: string;
}

export async function digestRepo(
  repo: RepoCondensed,
  config: BrainConfig
): Promise<RepoDigest> {
  const cwd = ensureDigestionDir(config);

  const prompt = `Tu analyses un repo git pour créer sa fiche de projet.

Repo : ${repo.name}
Remote : ${repo.remote ?? "aucun"}
Commits récents (50 derniers) :
${repo.recentCommits}

README :
${repo.readme.slice(0, 2000)}

${repo.claudeMd ? `CLAUDE.md :\n${repo.claudeMd.slice(0, 1500)}` : ""}

${repo.stack ? `Stack (package.json/Package.swift) :\n${repo.stack.slice(0, 500)}` : ""}

Réponds UNIQUEMENT avec ce JSON :
{
  "slug": "nom-du-projet-en-kebab-case",
  "name": "Nom lisible du projet",
  "goal": "1-2 phrases décrivant le but du projet",
  "stack": "technos principales séparées par des virgules",
  "remote": "URL du remote git ou null",
  "recentActivity": "2-3 phrases décrivant l'activité récente d'après les commits"
}`;

  const raw = runClaude(prompt, config.chunkModel, cwd);
  const cleaned = raw.replace(/^```(?:json)?\s*/m, "").replace(/\s*```\s*$/m, "").trim();

  try {
    return JSON.parse(cleaned) as RepoDigest;
  } catch {
    // Fallback: build basic info from what we have
    return {
      slug: repo.name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
      name: repo.name,
      goal: repo.readme.split("\n").find((l) => l.trim() && !l.startsWith("#")) ?? "Projet sans description",
      stack: repo.stack?.split("\n")[0] ?? "inconnu",
      remote: repo.remote,
      recentActivity: repo.recentCommits.split("\n").slice(0, 5).join("; "),
    };
  }
}
