/**
 * Writes Markdown pages to ~/CoucouBrain/.
 * Records: one file per session.
 * Project pages: merged/updated on each new record (second LLM call).
 * lessons.md and INDEX.md: updated after each ingestion run.
 */
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { expandHome, toSlug, today, shortId } from "./utils.js";
import type { SessionCondensed } from "./collect.js";
import type { RepoCondensed } from "./collect.js";
import type { SessionDigest, RepoDigest } from "./digest.js";
import type { BrainConfig } from "./config.js";
import { digestionDir } from "./config.js";
import matter from "gray-matter";

// ── Frontmatter types ─────────────────────────────────────────────────────────

export type PageGroup =
  | "Projects"
  | "Records"
  | "Decisions"
  | "Plans"
  | "Lessons"
  | "Reference";

export interface PageFrontmatter {
  id: string;
  type: "record" | "project" | "topic" | "lesson" | "index";
  title: string;
  project: string | string[];
  created: string;
  updated: string;
  sources: string[];
  links: string[];
  group: PageGroup;
}

// ── Path helpers ──────────────────────────────────────────────────────────────

function brainDir(config: BrainConfig): string {
  return expandHome(config.brainPath);
}

function recordPath(config: BrainConfig, sessionId: string, date: string, slug: string): string {
  return path.join(brainDir(config), "records", `${date}_${slug}_${shortId(sessionId)}.md`);
}

/** Public: get the .md file path for a given session (mirrors writeRecord logic) */
export function recordFilePath(config: BrainConfig, sessionId: string, sessionDate: string, primaryProject: string): string {
  return recordPath(config, sessionId, sessionDate, toSlug(primaryProject));
}

function projectPagePath(config: BrainConfig, projectSlug: string): string {
  return path.join(brainDir(config), "projects", `${projectSlug}.md`);
}

// ── Markdown helpers ───────────────────────────────────────────────────────────

function frontmatterBlock(fm: PageFrontmatter): string {
  const lines = [
    "---",
    `id: ${fm.id}`,
    `type: ${fm.type}`,
    `title: "${fm.title.replace(/"/g, '\\"')}"`,
    `project: ${Array.isArray(fm.project) ? JSON.stringify(fm.project) : fm.project}`,
    `created: ${fm.created}`,
    `updated: ${fm.updated}`,
    `sources: ${JSON.stringify(fm.sources)}`,
    `links: ${JSON.stringify(fm.links)}`,
    `group: ${fm.group}`,
    "---",
  ];
  return lines.join("\n");
}

function listItem(text: string): string {
  return `- ${text}`;
}

function section(title: string, items: string[]): string {
  if (items.length === 0) return "";
  return `## ${title}\n${items.map(listItem).join("\n")}`;
}

// ── Record page ───────────────────────────────────────────────────────────────

export function buildRecordId(session: SessionCondensed, primaryProject: string): string {
  const dateSlug = session.date.replace(/-/g, "");
  return `rec_${dateSlug}_${toSlug(primaryProject)}_${shortId(session.id)}`;
}

export function writeRecord(
  session: SessionCondensed,
  digest: SessionDigest,
  config: BrainConfig
): string {
  const primaryProject = digest.projects[0] ?? session.projectNameHint;
  const recordId = buildRecordId(session, primaryProject);
  const projectLinks = digest.projects.map((p) => `[[proj_${toSlug(p)}]]`);

  const fm: PageFrontmatter = {
    id: recordId,
    type: "record",
    title: digest.summary.split(".")[0]?.slice(0, 80) ?? "Session sans titre",
    project: digest.projects,
    created: session.date,
    updated: today(),
    sources: [`session:${session.id}`],
    links: projectLinks,
    group: "Records",
  };

  const sections: string[] = [];

  // Summary (always present)
  sections.push(`## Résumé\n${digest.summary}`);

  // Decisions
  if (digest.decisions.length > 0) {
    const items = digest.decisions.map((d) => {
      const badge = `[${d.provenance}] ${d.status}`;
      const replaces = d.replaces ? ` → remplace [[${d.replaces}]]` : "";
      return `${badge} ${d.content}${replaces}`;
    });
    sections.push(section("Décisions", items));
  }

  // Facts
  if (digest.facts.length > 0) {
    sections.push(section("Faits importants", digest.facts));
  }

  // Errors & lessons
  if (digest.errors_and_lessons.length > 0) {
    const items = digest.errors_and_lessons.map((l) => `${l.status} [${l.type}] ${l.content}`);
    sections.push(section("Erreurs & leçons", items));
  }

  // Open tasks
  if (digest.open_tasks.length > 0) {
    sections.push(section("Tâches ouvertes", digest.open_tasks));
  }

  // Files touched
  const filesFromSession = session.filesModified;
  const filesFromDigest = digest.files_touched;
  const allFiles = [...new Set([...filesFromDigest, ...filesFromSession])];
  if (allFiles.length > 0) {
    sections.push(section("Fichiers touchés", allFiles));
  }

  const content = [frontmatterBlock(fm), "", ...sections.filter(Boolean)].join("\n\n");

  const filePath = recordPath(config, session.id, session.date, toSlug(primaryProject));
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");

  return recordId;
}

// ── Project page — creation ────────────────────────────────────────────────────

function buildProjectPageFromRepo(repo: RepoCondensed, repoDigest: RepoDigest, config: BrainConfig): string {
  const slug = repoDigest.slug;
  const projectId = `proj_${slug}`;

  const fm: PageFrontmatter = {
    id: projectId,
    type: "project",
    title: repoDigest.name,
    project: slug,
    created: today(),
    updated: today(),
    sources: [`repo:${repo.path}`],
    links: [],
    group: "Projects",
  };

  const content = [
    frontmatterBlock(fm),
    "",
    `## But\n${repoDigest.goal}`,
    "",
    `## Stack\n${repoDigest.stack}`,
    "",
    `## Remote\n${repoDigest.remote ?? "aucun"}`,
    "",
    `## Activité récente\n${repoDigest.recentActivity}`,
    "",
    "## Décisions\n_(à alimenter par les sessions)_",
    "",
    "## Leçons\n_(à alimenter par les sessions)_",
    "",
    "## Tâches ouvertes\n_(à alimenter par les sessions)_",
    "",
    "## Fiches liées",
  ].join("\n");

  const filePath = projectPagePath(config, slug);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");

  return projectId;
}

export function writeProjectFromRepo(
  repo: RepoCondensed,
  repoDigest: RepoDigest,
  config: BrainConfig
): string {
  return buildProjectPageFromRepo(repo, repoDigest, config);
}

// ── Project page — merge via LLM ──────────────────────────────────────────────

function runClaudeForMerge(prompt: string, cwd: string, model: string): string {
  const result = spawnSync(
    "claude",
    ["--print", "--output-format", "json", "--model", model],
    {
      input: prompt,
      cwd,
      timeout: 180_000,
      maxBuffer: 10 * 1024 * 1024,
      encoding: "utf8",
    }
  );
  if (result.error) throw new Error(`claude spawn: ${result.error.message}`);
  if (result.status !== 0) throw new Error(`claude exit ${result.status}: ${result.stderr?.toString().slice(0, 300)}`);

  try {
    const envelope = JSON.parse(result.stdout);
    return envelope.result ?? result.stdout;
  } catch {
    return result.stdout;
  }
}

/** Merge a new record into the project page via a second LLM call */
export function mergeRecordIntoProject(
  projectSlug: string,
  recordId: string,
  recordContent: string,
  digest: SessionDigest,
  config: BrainConfig
): void {
  const filePath = projectPagePath(config, projectSlug);

  // If project page doesn't exist, create a skeleton
  if (!fs.existsSync(filePath)) {
    const projectId = `proj_${toSlug(projectSlug)}`;
    const fm: PageFrontmatter = {
      id: projectId,
      type: "project",
      title: projectSlug,
      project: projectSlug,
      created: today(),
      updated: today(),
      sources: [],
      links: [],
      group: "Projects",
    };
    const skeleton = [
      frontmatterBlock(fm),
      "",
      "## But\n_(inconnu)_",
      "",
      "## Stack\n_(inconnu)_",
      "",
      "## État actuel\n_(à alimenter)_",
      "",
      "## Décisions",
      "",
      "## Leçons",
      "",
      "## Tâches ouvertes",
      "",
      "## Fiches liées",
    ].join("\n");
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, skeleton, "utf8");
  }

  const currentContent = fs.readFileSync(filePath, "utf8");
  const cwd = digestionDir(config);
  fs.mkdirSync(cwd, { recursive: true });

  const prompt = `Tu mets à jour la page projet d'un projet de développement logiciel.

PAGE PROJET ACTUELLE :
${currentContent}

NOUVELLE FICHE DE SESSION (id: ${recordId}) :
${recordContent}

RÈGLES ABSOLUES :
1. Les décisions remplacées passent en ❌ avec la date ${today()}, la raison, et un lien [[${recordId}]] vers la nouvelle décision
2. Ne supprime JAMAIS une décision ou leçon : mets à jour son statut
3. Met à jour "État actuel" pour refléter où en est le projet
4. Met à jour "Tâches ouvertes" : supprime ce qui est fait, ajoute le nouveau
5. Ajoute [[${recordId}]] dans la section "Fiches liées"
6. Met à jour le champ "updated" dans le frontmatter YAML avec ${today()}
7. Réponds UNIQUEMENT avec le markdown complet de la page projet mise à jour, sans explication

Page projet mise à jour :`;

  const updated = runClaudeForMerge(prompt, cwd, config.mergeModel);

  // Sanity check: result should start with ---
  const cleaned = updated.trim();
  if (!cleaned.startsWith("---")) {
    console.warn(`  ⚠️  Merge inattendu pour ${projectSlug}, frontmatter manquant. Conservation de l'ancien contenu.`);
    return;
  }

  fs.writeFileSync(filePath, cleaned, "utf8");
}

// ── lessons.md ────────────────────────────────────────────────────────────────

export function appendToLessons(lessons: SessionDigest["errors_and_lessons"], projectSlugs: string[], config: BrainConfig): void {
  const crossLessons = lessons.filter((l) => l.status === "⚠️" || l.type === "leçon");
  if (crossLessons.length === 0) return;

  const lessonsPath = path.join(brainDir(config), "lessons.md");
  let content = fs.existsSync(lessonsPath) ? fs.readFileSync(lessonsPath, "utf8") : `---
id: lessons
type: lesson
title: "Leçons transverses"
project: []
created: ${today()}
updated: ${today()}
sources: []
links: []
group: Lessons
---

Leçons et pièges applicables à tous les projets.

`;

  // Update the updated field
  content = content.replace(/^updated: .*/m, `updated: ${today()}`);

  const projectRef = projectSlugs.map((s) => `[[proj_${s}]]`).join(", ");
  const newEntries = crossLessons
    .map((l) => `- ${l.status} [${l.type}] ${l.content} _(${today()} — ${projectRef})_`)
    .join("\n");

  content = content.trimEnd() + "\n\n" + newEntries + "\n";
  fs.writeFileSync(lessonsPath, content, "utf8");
}

// ── INDEX.md ──────────────────────────────────────────────────────────────────

export function rebuildIndex(config: BrainConfig): void {
  const base = brainDir(config);
  const indexPath = path.join(base, "INDEX.md");

  const lines: string[] = [
    `---`,
    `id: index`,
    `type: index`,
    `title: "Index CoucouBrain"`,
    `project: []`,
    `created: ${today()}`,
    `updated: ${today()}`,
    `sources: []`,
    `links: []`,
    `group: Reference`,
    `---`,
    "",
    `Dernière mise à jour : ${today()}`,
    "",
    "## Projets",
  ];

  // List project pages
  const projectsDir = path.join(base, "projects");
  if (fs.existsSync(projectsDir)) {
    for (const f of fs.readdirSync(projectsDir).sort()) {
      if (!f.endsWith(".md")) continue;
      const raw = fs.readFileSync(path.join(projectsDir, f), "utf8");
      const { data } = matter(raw);
      lines.push(`- [[${data.id ?? f}]] — ${data.title ?? f}`);
    }
  }

  lines.push("", "## Fiches récentes (30 dernières)");

  // List recent records
  const recordsDir = path.join(base, "records");
  if (fs.existsSync(recordsDir)) {
    const files = fs.readdirSync(recordsDir)
      .filter((f) => f.endsWith(".md"))
      .sort()
      .reverse()
      .slice(0, 30);
    for (const f of files) {
      const raw = fs.readFileSync(path.join(recordsDir, f), "utf8");
      const { data } = matter(raw);
      const proj = Array.isArray(data.project) ? data.project.join(", ") : data.project;
      lines.push(`- [[${data.id ?? f}]] — ${data.title ?? f} _(${proj})_`);
    }
  }

  lines.push("", "## Pages clés");
  lines.push("- [[lessons]] — Leçons transverses");

  fs.writeFileSync(indexPath, lines.join("\n") + "\n", "utf8");
}

// ── Git commit ─────────────────────────────────────────────────────────────────

export function gitCommit(config: BrainConfig, message: string): void {
  const base = brainDir(config);
  try {
    spawnSync("git", ["add", "-A"], { cwd: base, encoding: "utf8" });
    const result = spawnSync("git", ["commit", "-m", message], { cwd: base, encoding: "utf8" });
    if (result.status === 0) {
      console.log(`  ✓ git commit: ${message}`);
    } else {
      const out = result.stdout?.trim();
      if (out?.includes("nothing to commit")) {
        console.log("  (rien à committer)");
      } else {
        console.warn(`  git commit a échoué: ${result.stderr}`);
      }
    }
  } catch (e) {
    console.warn(`  git error: ${(e as Error).message}`);
  }
}

// ── Brain init ────────────────────────────────────────────────────────────────

export function ensureBrainDir(config: BrainConfig): void {
  const base = brainDir(config);
  fs.mkdirSync(path.join(base, "records"), { recursive: true });
  fs.mkdirSync(path.join(base, "projects"), { recursive: true });
  fs.mkdirSync(path.join(base, ".state", "digestion"), { recursive: true });

  // Init git if not already
  if (!fs.existsSync(path.join(base, ".git"))) {
    spawnSync("git", ["init"], { cwd: base, encoding: "utf8" });
    console.log(`  ✓ git init dans ${base}`);
  }

  // .gitignore
  const gitignorePath = path.join(base, ".gitignore");
  if (!fs.existsSync(gitignorePath)) {
    fs.writeFileSync(gitignorePath, ".state/\n", "utf8");
  }
}
