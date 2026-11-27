/**
 * LLM digest — calls `claude -p` from the brain's digestion directory.
 * Never called in --dry-run mode.
 *
 * Security: subprocess runs with zero tools.
 *   --strict-mcp-config --mcp-config '{"mcpServers":{}}' → removes all MCP tools
 *   --tools ""                                            → clears built-in set (LSP remains)
 *   --disallowed-tools "LSP"                              → removes LSP → [] total
 *
 * --allowedTools "" alone is INSECURE: MCP tools remain available.
 * --tools "" alone is INSECURE: LSP still present (init event shows ["LSP"]).
 * All three flags together → init event shows [], verified by stream-json.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { z } from "zod";
import { digestionDir } from "./config.js";
import { chunkMessages, type Chunk } from "./chunk.js";
import type { SessionCondensed, RepoCondensed } from "./collect.js";
import type { BrainConfig } from "./config.js";
import { LLMElementSchema, type OpenElementHint } from "./elements.js";

// ── Session digest schema (what the LLM returns) ──────────────────────────────

export const SessionDigestSchema = z.object({
  title: z.string().min(1).transform((s) => s.slice(0, 60)),
  summary: z.string().min(1),
  projects: z.array(z.string()).default([]),
  elements: z.array(LLMElementSchema).default([]),
  taches_faites: z.array(z.string()).default([]),
  taches_abandonnees: z.array(z.object({ id: z.string(), raison: z.string() })).default([]),
  remplacees: z.array(z.object({
    id: z.string(),
    par: z.string().nullable().default(null),
    raison: z.string(),
  })).default([]),
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
      "--strict-mcp-config",            // ignore all configured MCP servers
      "--mcp-config", '{"mcpServers":{}}',  // empty MCP set
      "--tools", "",                    // clear all built-in tools → only LSP remains
      "--disallowed-tools", "LSP",      // remove LSP → zero tools total
    ],
    {
      input: prompt,
      cwd,
      timeout: timeoutMs,
      maxBuffer: 20 * 1024 * 1024,
      encoding: "utf8",
      // Belt-and-suspenders: env flag in case Claude Code forwards inherited env to hooks
      env: { ...process.env, COUCOU_BRAIN_INTERNAL: "1" },
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

/** Marker injected into every prompt so brain's own sessions can be identified and excluded */
const INTERNAL_MARKER = "<!-- coucou-brain-internal -->";

/** Build a per-chunk extraction prompt: same rules as full digest, restricted to this chunk. */
function buildChunkDigestPrompt(
  chunk: Chunk,
  sessionDate: string,
  projectHint: string,
  openElements: OpenElementHint[] = []
): string {
  // openElements only passed to last chunk to avoid duplicate taches_faites/remplacees
  const elements = chunk.index === chunk.total - 1 ? openElements : [];
  const base = buildDigestPrompt(chunk.text, sessionDate, projectHint, elements);
  if (chunk.total <= 1) return base;
  const note = `\n⚠️ MORCEAU ${chunk.index + 1}/${chunk.total} : session longue découpée. Extrais UNIQUEMENT les éléments visibles dans CE MORCEAU. Title et summary décrivent CE MORCEAU uniquement. Les morceaux seront fusionnés ensuite.`;
  const marker = `Tu analyses une session Claude Code du ${sessionDate} (projet supposé : ${projectHint}).`;
  return base.replace(marker, marker + note);
}

/** Merge N per-chunk digests into one, deduplicating elements. */
function mergeChunkDigests(partials: SessionDigest[]): SessionDigest {
  if (partials.length === 0) throw new Error("No chunk digests to merge");
  if (partials.length === 1) return partials[0]!;

  const last = partials[partials.length - 1]!;
  const allElements = partials.flatMap((d) => d.elements);

  // Mesures with nom: last value wins (most recent data)
  const mesureLastByNom = new Map<string, (typeof allElements)[0]>();
  for (const e of allElements) {
    if (e.kind === "mesure" && e.nom) mesureLastByNom.set(e.nom, e);
  }

  // Other elements: first occurrence wins (earlier chunk = earlier context)
  const seenKeys = new Set<string>();
  const deduped: typeof allElements = [];
  for (const e of allElements) {
    if (e.kind === "mesure" && e.nom) continue;
    const key = `${e.kind}:${e.texte.slice(0, 60).toLowerCase().replace(/\s+/g, " ").trim()}`;
    if (!seenKeys.has(key)) {
      seenKeys.add(key);
      deduped.push(e);
    }
  }
  deduped.push(...mesureLastByNom.values());

  const uniq = <T>(arr: T[]): T[] => [...new Set(arr)];
  const uniqById = <T extends { id: string }>(arr: T[]): T[] => {
    const seen = new Set<string>();
    return arr.filter((x) => {
      if (seen.has(x.id)) return false;
      seen.add(x.id);
      return true;
    });
  };

  // Title: combine chunk titles (first + last if different) up to 60 chars
  const titles = [...new Set(partials.map((d) => d.title))];
  const title = titles.length === 1
    ? titles[0]!
    : (titles[0]! + " / " + titles[titles.length - 1]!).slice(0, 60);

  return {
    title,
    summary: partials.map((d) => d.summary).join(" "),
    projects: uniq(partials.flatMap((d) => d.projects)),
    elements: deduped,
    taches_faites: uniq(partials.flatMap((d) => d.taches_faites)),
    taches_abandonnees: uniqById(partials.flatMap((d) => d.taches_abandonnees)),
    remplacees: uniqById(partials.flatMap((d) => d.remplacees)),
    project_states: last.project_states,
    files_touched: uniq(partials.flatMap((d) => d.files_touched)),
    people: uniq(partials.flatMap((d) => d.people)),
  };
}

function buildOpenElementsBlock(openElements: OpenElementHint[]): string {
  if (openElements.length === 0) return "";
  const lines = openElements.map(
    (e) =>
      `  {"id":"${e.id}","kind":"${e.kind}","statut":${e.statut ? `"${e.statut}"` : "null"},"texte":"${e.texte.slice(0, 100).replace(/"/g, "'")}"}`
  );
  return `\nÉLÉMENTS OUVERTS (tâches non terminées et décisions actives du projet) :
${lines.join("\n")}

Si cette session termine une tâche, l'abandonne, ou corrige/remplace une décision active :
- Tâche terminée → ajoute son ID dans "taches_faites": ["<id>"]
- Tâche abandonnée → ajoute dans "taches_abandonnees": [{"id": "<id>", "raison": "pourquoi"}]
- Décision remplacée/corrigée → ajoute dans "remplacees": [{"id": "<id-ancienne>", "par": null, "raison": "pourquoi"}]
OBLIGATION : relis chaque décision active dans la liste. Si la session corrige ses valeurs (ex: taux incorrect → nouveau taux), l'invalide ou la remplace → cette décision DOIT figurer dans "remplacees". Ne jamais laisser une décision active non-traitée si cette session la contredit.\n`;
}

function buildDigestPrompt(
  text: string,
  sessionDate: string,
  projectHint: string,
  openElements: OpenElementHint[] = []
): string {
  const openBlock = buildOpenElementsBlock(openElements);
  return `${INTERNAL_MARKER}
Tu analyses une session Claude Code du ${sessionDate} (projet supposé : ${projectHint}).
${openBlock}

TITRE : génère un titre en 60 caractères maximum, précis et informatif. Exemples de BONS titres : "brain/ module TypeScript : pipeline sessions + repos", "404 CRT, WebP, panel entreprise, analytics". Mauvais titre : les 60 premiers caractères du résumé coupés au milieu.

PROJETS : identifie tous les slugs de projet touchés (ex: "coucou", "portfo", "sbe-hub"). Sous-projets : "coucou-brain" pour le module brain/ de Coucou. Pages personne : "people/enya" ou "people/nom".

ÉLÉMENTS : pour chaque décision, fait notable, leçon, tâche, préférence ou mesure, génère un élément.
Champs :
- kind : "décision" | "fait" | "leçon" | "tâche" | "préférence" | "mesure"
  • décision : choix technique ou de product pris ou rejeté
  • fait : information factuelle stable (architecture, URL, contrainte permanente)
  • leçon : enseignement ou erreur à retenir
  • tâche : action à faire ou déjà faite (statut ❌)
  • préférence : goût ou règle de travail de Louis
  • mesure : compteur ou montant qui évolue dans le temps (abonnés, CA, utilisateurs, lignes de code…)
    — OBLIGATION ABSOLUE : toute valeur numérique d'abonnés, inscrits newsletter, utilisateurs actifs, visiteurs, CA ou revenus DOIT être kind=mesure avec nom stable. Ne jamais utiliser fait pour ces valeurs numériques.
    — Utilise "mesure" quand la valeur changera à la prochaine session, PAS "fait".
    — Champ "nom" obligatoire : clé stable en français, identique à toutes les sessions (ex: "abonnés newsletter botan", "ca net 2026"). Toujours le même nom pour le même compteur d'une session à l'autre.
    — texte = valeur complète lisible (ex: "61 abonnés newsletter Botan actifs").
    — Projets : inclure TOUS les projets concernés. Si la mesure est consultée depuis le dashboard d'un autre projet, inclure ce projet aussi (ex: inscrits Botan vus dans le dashboard portfo admin → projets=["portfo","botan"]).
- sub_kind : pour leçon uniquement : "erreur" (bug, mauvaise approche) | "leçon" (bonne pratique)
- provenance :
  • "décidé" = Louis l'a dit ou confirmé explicitement
  • "proposé" = Claude a suggéré, Louis n'a pas dit oui
  • "constaté" = fait observé, ce que Claude a implémenté sans validation explicite
  • null pour mesure (pas de provenance)
- statut : "✅" (en vigueur/faite) | "❌" (abandonné) | "⏳" (en attente) | "⚠️" (piège) | null pour mesure
  • Pour kind=tâche : ✅=faite, ⏳=ouverte, ❌=abandonnée (raison obligatoire)
- texte : contenu en 1-2 phrases max (jamais plus de 400 chars)
- nom : pour mesure uniquement — clé stable servant de déduplication (null pour les autres kinds)
- projets : slugs des projets concernés
- remplace : id d'un élément précédent si cette décision l'annule (null sinon)
- raison : explication si statut ❌ (obligatoire dans ce cas)
- domaine : pour leçon uniquement : "shell" | "git" | "macos" | "nextjs" | "vercel" | "swift" | "claude-code" | "general"
- scope : "transverse" (leçon valable hors du projet) | "projet" (propre au projet)
  Règle : toute leçon sur une commande git, gh, shell, npm, ffmpeg, etc. est TOUJOURS "transverse".

RÈGLES IMPORTANTES :
- Approuver un plan ou une action via le notch Coucou N'EST PAS valider une préférence de goût ou de style. Si le condensé contient "[plan approuvé via le notch Coucou]" ou "[X approuvé via le notch Coucou]", le contenu de ce plan/action est [constaté] s'il est resté en place, jamais [décidé] — sauf si Louis a ensuite explicitement validé le choix dans une conversation. Ne jamais utiliser provenance='décidé' pour le seul fait qu'un plan a été approuvé via le notch.
- Si une décision de projet encode aussi une règle personnelle de Louis (workflow Git, communication, pratique de dev, style UI), génère AUSSI un élément kind=préférence avec le même contenu résumé, projets=[] si c'est une règle générale. Exemples :
  • Une décision "Enya ne pousse que sur branches" → aussi une préférence globale dont le texte DOIT contenir la phrase exacte "poussent sur branches" — texte obligatoire : "Collaborateurs poussent sur branches dédiées, pas directement sur main. Louis merge." avec projets=[].
  • Un revert de style parce que "Louis n'aime pas" → aussi une préférence globale décrivant ce qu'il n'aime pas.
  • Une contrainte "jamais X sans OK explicite" → aussi une préférence globale avec projets=[].
- Une méthode de déploiement, une contrainte d'architecture ou un choix permanent DOIT être capturé comme fait (pas seulement comme tâche). Exemples : "deploy via git push sur main", "auth admin via HMAC", "RLS désactivée sur cette table".
- Une tâche TERMINÉE dans la session doit avoir statut=✅ (faite). Statut=❌ = abandonnée (raison obligatoire). Ne laisse pas de tâches ouvertes si elles ont été accomplies dans la session.
- Un comportement SQL ou API inattendu (JOIN excluant NULLs, pagination, rate limit, encoding) = leçon scope=transverse.
- REVERT = proposé ❌ : un changement visuel ou fonctionnel implémenté puis revert dans la même session, ou annulé par Louis juste après l'avoir vu sans l'adopter, doit avoir provenance='proposé' + statut=❌. 'décidé ❌' est réservé à quelque chose que Louis a adopté et déployé/mergé avant de revenir dessus lors d'une session ultérieure.
- Fonctionnalité complète demandée et livrée dans la session : si Louis demande explicitement une feature dans son premier message (ex: "ajoute une section Botan au dashboard") ET que Claude l'implémente en entier → crée aussi une tâche ✅ décrivant la demande en plus des faits architecturaux.
- Mécanismes de sécurité (HMAC, JWT, tokens signés, auth admin) DOIVENT être kind=décision (pas fait) avec la technologie exacte dans le texte (ex: "Auth admin via HMAC-SHA256 session signing", "Tokens désinscription newsletter via HMAC-SHA256 avec BOTAN_UNSUB_SECRET").
- Taux et paramètres fiscaux réglementaires (URSSAF, IR libératoire, TVA, CFE, charges sociales) DOIVENT être kind=décision (provenance='décidé', statut=✅). Ces valeurs peuvent être corrigées lors d'une session ultérieure. Ne jamais utiliser kind=fait pour un taux ou un montant fiscal fixé par la loi ou par Louis.
- Section de tracking des dépenses/charges récurrentes créée dans le dashboard d'un projet : décision OBLIGATOIRE dont le texte contient "charges récurrentes". Ex: "Expense tracking portfo : section 'Charges récurrentes' avec groupement par fréquence (mensuel/annuel/unique), toggle active, bouton génération mensuelle, table expenses SQL."
- Une section de statistiques fiscales pour micro-entrepreneur doit être capturée comme décision avec le label exact "Stats fiscales micro-entrepreneur" dans le texte (ex: "Stats fiscales micro-entrepreneur : URSSAF X%, IR Y%...").
- Mode de déploiement d'un projet : si le déploiement se fait via git push (Vercel git integration, Railway, Fly.io, etc.), le fait DOIT contenir le terme "git push" (ex: "Déploiement portfo via git push sur main (Vercel git integration)").
- Politiques de sécurité base de données (RLS, row-level security, policies Supabase) : toujours capturer comme fait, que RLS soit activée ou désactivée. Ex: "RLS désactivée sur table clients portfo" ou "RLS activée sur email_subscribers".
- Format de fichiers statiques d'un projet (images WebP, vidéos H264/H265) = kind fait OBLIGATOIRE. INTERDIT d'utiliser kind=décision ou kind=tâche pour les formats d'assets d'un projet. Ces éléments décrivent l'état actuel, pas une action. Si la session portfo mentionne des images WebP ou des vidéos H264, générer EXACTEMENT ces deux faits (provenance=constaté, statut=null, projets=["portfo"]) :
  Fait 1 : "Images portfo en WebP 840px q80 (.v2.webp). Header Cache-Control immutable sur /frame dans next.config.ts."
  Fait 2 : "Vidéos works portfo en H264 1280px CRF26 60fps preset slow. Posters JPEG à 1s."
- RLS activée + 0 policy (bypass service_role) = leçon avec le terme "RLS admin-only" dans le texte. Ex: "RLS admin-only : RLS + 0 policy bloque les requêtes anon mais service_role (createAdminClient) bypasse. Pattern valide pour tables admin-only."
- Commandes git/gh utilisées avec succès pour gérer des PRs ou branches : générer UNE leçon transverse DISTINCTE par commande parmi les suivantes si elles apparaissent dans la session :
  • gh pr merge <num> --merge : leçon OBLIGATOIRE avec "gh pr merge" dans le texte. Ex: "gh pr merge <num> --merge fusionne une PR en merge commit via CLI sans --auto."
  • git fetch origin <branche> : leçon OBLIGATOIRE avec "git fetch origin" dans le texte. Ex: "git fetch origin <branche1> <branche2> récupère des branches distantes ciblées sans full fetch."
- Workflow d'un collaborateur qui n'est pas autorisé à pousser directement sur main (Enya, etc.) : fait ou décision avec le terme exact "passe uniquement" dans le texte (ex: "Enya passe uniquement par des branches + PR, Louis merge sur main").

COMBINAISONS AUTORISÉES :
- [décidé] ✅ : Louis a décidé ou validé
- [décidé] ❌ : Louis est revenu dessus (remplace + raison obligatoires)
- [proposé] ❌ : Louis a rejeté (raison obligatoire)
- [proposé] ⏳ : proposition en attente
- [constaté] : sans statut (jamais de statut sur [constaté])
- [proposé] ✅ N'EXISTE PAS → utilise ⏳ à la place
- leçon sub_kind=erreur : ⚠️ uniquement (jamais ✅)
- leçon sub_kind=leçon : ✅ ou ⚠️

DÉCISIONS REMPLACÉES : si une décision active est annulée ou remplacée par une nouvelle, ajoute-la dans "remplacees": [{"id": "<id-ancienne>", "par": "<id-nouvelle-ou-null>", "raison": "pourquoi"}]

ÉTAT ACTUEL : pour chaque projet, 2-3 phrases décrivant l'état du projet MAINTENANT. Max 5 lignes.

FICHIERS TOUCHÉS : chemins relatifs à la racine du repo (ex: "brain/src/write.ts" et non "/Users/louis/Developer/coucou/brain/src/write.ts"). Sans doublons. Max 25.

PERSONNES : prénoms ou noms des personnes mentionnées (hors Louis et Claude).

SESSION :
${text}

AVANT DE RÉPONDRE — CONTRÔLE OBLIGATOIRE :
1. Cherche tout élément dont le texte contient "WebP" ou "H264" → kind DOIT être "fait". Si tu as mis "décision" ou "tâche", corrige en "fait".
2. Si la session mentionne "Collaborateurs" ou "Enya" qui "ne pousse que sur branches" → vérifier qu'une préférence avec "poussent sur branches" dans le texte est présente.
3. Si la session utilise "git fetch origin <branche>" → vérifier qu'une leçon avec "git fetch origin" dans le texte est présente.

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
      "nom": null,
      "projets": ["coucou"],
      "remplace": null,
      "raison": null,
      "domaine": null,
      "scope": "projet"
    }
  ],
  "taches_faites": [],
  "taches_abandonnees": [],
  "remplacees": [],
  "project_states": [
    {"project": "coucou", "etat_actuel": "2-3 phrases max"}
  ],
  "files_touched": ["brain/src/write.ts"],
  "people": []
}`;
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
  config: BrainConfig,
  openElements: OpenElementHint[] = []
): Promise<SessionDigest> {
  const cwd = ensureDigestionDir(config);
  const chunks = chunkMessages(session.messages, config.maxChunkTokens);

  if (chunks.length === 1) {
    const prompt = buildDigestPrompt(
      chunks[0]!.text,
      session.date,
      session.projectNameHint,
      openElements
    );
    return parseDigest(runClaude(prompt, config.mergeModel, cwd));
  }

  // Multi-chunk: extract elements from each chunk independently, then merge
  console.log(`  Session longue : ${chunks.length} morceaux`);
  const partials: SessionDigest[] = [];
  for (const chunk of chunks) {
    console.log(`    Morceau ${chunk.index + 1}/${chunk.total} (~${chunk.estimatedTokens} tokens)…`);
    const prompt = buildChunkDigestPrompt(chunk, session.date, session.projectNameHint, openElements);
    const raw = runClaude(prompt, config.mergeModel, cwd);
    partials.push(parseDigest(raw));
  }
  return mergeChunkDigests(partials);
}

/**
 * Hash of the current digest prompt template (static parts only, no session content).
 * Stored in the manifest so sessions can be skipped if the prompt hasn't changed.
 */
export function digestPromptHash(): string {
  // Build a prompt with empty content to capture only the template/instruction text
  const template = buildDigestPrompt("__template__", "2000-01-01", "template-check");
  return createHash("sha256").update(template).digest("hex").slice(0, 12);
}

export async function digestSessionWithRetry(
  session: SessionCondensed,
  config: BrainConfig,
  openElements: OpenElementHint[] = []
): Promise<SessionDigest> {
  try {
    return await digestSession(session, config, openElements);
  } catch (firstError) {
    console.warn(`  Retry après erreur: ${(firstError as Error).message.slice(0, 100)}`);
    try {
      return await digestSession(session, config, openElements);
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

  const prompt = `${INTERNAL_MARKER}
Tu analyses un repo git pour créer sa fiche de projet.

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
