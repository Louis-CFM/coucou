/**
 * LLM digest — calls `claude -p` from the brain's digestion directory.
 * Never called in --dry-run mode.
 *
 * Security: --tools "" disables ALL tools in the subprocess.
 * Session content may come from web pages or external sources and could
 * contain prompt injection. With no tools available, the LLM can only
 * output text — no file reads, writes, or commands possible.
 */
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import { z } from "zod";
import { digestionDir } from "./config.js";
import { chunkMessages, messagesToText, type Chunk } from "./chunk.js";
import type { SessionCondensed, RepoCondensed } from "./collect.js";
import type { BrainConfig } from "./config.js";
import { LLMElementSchema } from "./elements.js";

// ── Session digest schema (what the LLM returns) ──────────────────────────────

export const SessionDigestSchema = z.object({
  title: z.string().min(1).max(80).transform((s) => s.slice(0, 60)),
  summary: z.string().min(1),
  projects: z.array(z.string()).min(1),
  elements: z.array(LLMElementSchema).default([]),
  project_states: z
    .array(z.object({ project: z.string(), etat_actuel: z.string() }))
    .default([]),
  files_touched: z.array(z.string()).default([]),
  people: z.array(z.string()).default([]),
});

export type SessionDigest = z.infer<typeof SessionDigestSchema>;

// ── Claude runner ─────────────────────────────────────────────────────────────

function runClaude(
  prompt: string,
  model: string,
  cwd: string,
  timeoutMs = 360_000
): string {
  const result = spawnSync(
    "claude",
    [
      "--print",
      "--output-format", "json",
      "--model", model,
      "--allowedTools", "",    // disable ALL tools — no prompt injection risk
    ],
    {
      input: prompt,
      cwd,
      timeout: timeoutMs,
      maxBuffer: 20 * 1024 * 1024,
      encoding: "utf8",
    }
  );

  if (result.error) throw new Error(`claude spawn: ${result.error.message}`);
  if (result.status !== 0) {
    const stderr = result.stderr?.toString().slice(0, 500) ?? "";
    throw new Error(`claude exited ${result.status}: ${stderr}`);
  }

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

// ── Prompts ───────────────────────────────────────────────────────────────────

function buildChunkSummaryPrompt(
  chunk: Chunk,
  sessionDate: string,
  projectHint: string
): string {
  return `Tu résumes un morceau d'une session Claude Code (${chunk.index + 1}/${chunk.total}).
Date de la session : ${sessionDate}. Projet supposé : ${projectHint}.

Résume ce morceau en 300 à 500 mots en français. Inclus : ce qui a été fait, les décisions prises, les problèmes rencontrés, les fichiers importants mentionnés. Sois factuel et précis.

MORCEAU :
${chunk.text}

Résumé :`;
}

function buildDigestPrompt(text: string, sessionDate: string, projectHint: string): string {
  return `Tu analyses une session Claude Code du ${sessionDate} (projet supposé : ${projectHint}).

TITRE : génère un titre en 60 caractères maximum, précis et informatif. Exemples de BONS titres : "brain/ module TypeScript : pipeline sessions + repos", "404 CRT, WebP, panel entreprise, analytics". Mauvais titre : les 60 premiers caractères du résumé coupés au milieu.

PROJETS : identifie tous les slugs de projet touchés (ex: "coucou", "portfo", "sbe-hub"). Sous-projets : "coucou-brain" pour le module brain/ de Coucou. Pages personne : "people/enya" ou "people/nom".

ÉLÉMENTS : pour chaque décision, fait notable, leçon, tâche ou préférence de Louis, génère un élément.
Champs :
- kind : "décision" | "fait" | "leçon" | "tâche" | "préférence"
  • décision : choix technique ou de product pris ou rejeté
  • fait : information factuelle stable (version, URL, compte, nombre clé)
  • leçon : enseignement ou erreur à retenir
  • tâche : action à faire ou déjà faite (statut ❌)
  • préférence : goût ou règle de travail de Louis
- sub_kind : pour leçon uniquement : "erreur" (bug, mauvaise approche) | "leçon" (bonne pratique)
- provenance :
  • "décidé" = Louis l'a dit ou confirmé explicitement
  • "proposé" = Claude a suggéré, Louis n'a pas dit oui
  • "constaté" = fait observé, ce que Claude a implémenté sans validation explicite
- statut : "✅" (en vigueur) | "❌" (abandonné/terminé) | "⏳" (en attente) | "⚠️" (piège)
- texte : contenu en 1-2 phrases max (jamais plus de 400 chars)
- projets : slugs des projets concernés
- remplace : id d'un élément précédent si cette décision l'annule (null sinon)
- raison : explication si statut ❌ (obligatoire dans ce cas)
- domaine : pour leçon uniquement : "shell" | "git" | "macos" | "nextjs" | "vercel" | "swift" | "claude-code" | "general"
- scope : "transverse" (leçon valable hors du projet) | "projet" (propre au projet)

COMBINAISONS AUTORISÉES :
- [décidé] ✅ : Louis a décidé ou validé
- [décidé] ❌ : Louis est revenu dessus (remplace + raison obligatoires)
- [proposé] ❌ : Louis a rejeté (raison obligatoire)
- [proposé] ⏳ : proposition en attente
- [constaté] : sans statut (jamais de statut sur [constaté])
- [proposé] ✅ N'EXISTE PAS → utilise ⏳ à la place
- leçon sub_kind=erreur : ⚠️ uniquement (jamais ✅)
- leçon sub_kind=leçon : ✅ ou ⚠️

ÉTAT ACTUEL : pour chaque projet, 2-3 phrases décrivant l'état du projet MAINTENANT. Max 5 lignes.

FICHIERS TOUCHÉS : chemins relatifs à la racine du repo (ex: "brain/src/write.ts" et non "/Users/louis/Developer/coucou/brain/src/write.ts"). Sans doublons. Max 25.

PERSONNES : prénoms ou noms des personnes mentionnées (hors Louis et Claude).

SESSION :
${text}

Réponds UNIQUEMENT avec le JSON ci-dessous, sans markdown, sans commentaire :
{
  "title": "Titre ≤60 chars",
  "summary": "3-5 phrases factuelles",
  "projects": ["slug"],
  "elements": [
    {
      "kind": "décision",
      "sub_kind": null,
      "provenance": "décidé",
      "statut": "✅",
      "texte": "...",
      "projets": ["coucou"],
      "remplace": null,
      "raison": null,
      "domaine": null,
      "scope": "projet"
    }
  ],
  "project_states": [
    {"project": "coucou", "etat_actuel": "2-3 phrases max"}
  ],
  "files_touched": ["brain/src/write.ts"],
  "people": []
}`;
}

function buildFinalDigestPrompt(
  summaries: string[],
  sessionDate: string,
  projectHint: string
): string {
  const summaryBlock = summaries
    .map((s, i) => `### Morceau ${i + 1}\n${s}`)
    .join("\n\n");
  return buildDigestPrompt(summaryBlock, sessionDate, projectHint);
}

// ── Parse & validate ──────────────────────────────────────────────────────────

function parseDigest(raw: string): SessionDigest {
  const cleaned = raw
    .normalize("NFC")
    .replace(/^```(?:json)?\s*/m, "")
    .replace(/\s*```\s*$/m, "")
    .trim();

  let parsed: unknown;
  try {
    parsed = JSON.parse(cleaned);
  } catch (e) {
    throw new Error(
      `JSON invalide dans la réponse du modèle: ${(e as Error).message}\n${cleaned.slice(0, 300)}`
    );
  }

  const result = SessionDigestSchema.safeParse(parsed);
  if (!result.success) {
    throw new Error(
      `Schéma invalide: ${result.error.message}\n${JSON.stringify(parsed, null, 2).slice(0, 500)}`
    );
  }

  return result.data;
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
    const prompt = buildDigestPrompt(chunks[0]!.text, session.date, session.projectNameHint);
    digestText = runClaude(prompt, config.mergeModel, cwd);
  } else {
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

  return parseDigest(digestText);
}

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

// ── Repo digest ────────────────────────────────────────────────────────────────

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
  const cleaned = raw
    .normalize("NFC")
    .replace(/^```(?:json)?\s*/m, "")
    .replace(/\s*```\s*$/m, "")
    .trim();

  try {
    return JSON.parse(cleaned) as RepoDigest;
  } catch {
    return {
      slug: repo.name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
      name: repo.name,
      goal:
        repo.readme.split("\n").find((l) => l.trim() && !l.startsWith("#")) ??
        "Projet sans description",
      stack: repo.stack?.split("\n")[0] ?? "inconnu",
      remote: repo.remote,
      recentActivity: repo.recentCommits.split("\n").slice(0, 5).join("; "),
    };
  }
}
