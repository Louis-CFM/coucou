/**
 * Writes Markdown pages to ~/CoucouBrain/.
 *
 * Architecture: LLM returns elements (JSON), code does all merging and rendering.
 * No second LLM call. State stored in .state/proj/*.json.
 */
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import matter from "gray-matter";
import { expandHome, toSlug, today, shortId } from "./utils.js";
import type { SessionCondensed, RepoCondensed } from "./collect.js";
import type { SessionDigest, RepoDigest } from "./digest.js";
import type { BrainConfig } from "./config.js";
import {
  type StoredElement,
  type LLMElement,
  type OpenElementHint,
  llmToStored,
  mergeElements,
  applyTaskClosures,
  applyDecisionReplacements,
  renderElement,
  validateLinks,
} from "./elements.js";

// ── State types ───────────────────────────────────────────────────────────────

interface ProjectState {
  id: string;
  title: string;
  goal: string;
  stack: string;
  remote: string | null;
  repoSources: string[];
  recordSources: string[];
  etatActuel: string;
  linkedProjects: string[];
  linkedPeople: string[];
  elements: StoredElement[];
  created: string;
  updated: string;
}

interface GlobalState {
  id: string;
  elements: StoredElement[];
  updated: string;
}

// ── Page group type ───────────────────────────────────────────────────────────

type PageGroup = "Projects" | "Records" | "Lessons" | "Reference" | "Louis" | "People";

interface PageFrontmatter {
  id: string;
  type: string;
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

function stateDir(config: BrainConfig): string {
  return path.join(brainDir(config), ".state", "proj");
}

function recordsDir(config: BrainConfig): string {
  return path.join(brainDir(config), "records");
}

function projectsDir(config: BrainConfig): string {
  return path.join(brainDir(config), "projects");
}

function peopleDir(config: BrainConfig): string {
  return path.join(brainDir(config), "people");
}

export function recordFilePath(
  config: BrainConfig,
  sessionId: string,
  sessionDate: string,
  primaryProject: string
): string {
  return path.join(
    recordsDir(config),
    `${sessionDate}_${toSlug(primaryProject)}_${shortId(sessionId)}.md`
  );
}

// ── State management ──────────────────────────────────────────────────────────

function loadProjectState(projectId: string, config: BrainConfig): ProjectState {
  const file = path.join(stateDir(config), `${projectId}.json`);
  if (!fs.existsSync(file)) {
    return {
      id: projectId,
      title: projectId.replace(/^proj_/, ""),
      goal: "",
      stack: "",
      remote: null,
      repoSources: [],
      recordSources: [],
      etatActuel: "",
      linkedProjects: [],
      linkedPeople: [],
      elements: [],
      created: today(),
      updated: today(),
    };
  }
  return JSON.parse(fs.readFileSync(file, "utf8")) as ProjectState;
}

function saveProjectState(state: ProjectState, config: BrainConfig): void {
  const dir = stateDir(config);
  fs.mkdirSync(dir, { recursive: true });
  state.updated = today();
  fs.writeFileSync(
    path.join(dir, `${state.id}.json`),
    JSON.stringify(state, null, 2),
    "utf8"
  );
}

function loadGlobalState(id: string, config: BrainConfig): GlobalState {
  const file = path.join(stateDir(config), `${id}.json`);
  if (!fs.existsSync(file)) {
    return { id, elements: [], updated: today() };
  }
  return JSON.parse(fs.readFileSync(file, "utf8")) as GlobalState;
}

function saveGlobalState(state: GlobalState, config: BrainConfig): void {
  const dir = stateDir(config);
  fs.mkdirSync(dir, { recursive: true });
  state.updated = today();
  fs.writeFileSync(
    path.join(dir, `${state.id}.json`),
    JSON.stringify(state, null, 2),
    "utf8"
  );
}

// ── Markdown helpers ──────────────────────────────────────────────────────────

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

// ── File path normalization ───────────────────────────────────────────────────

/**
 * Normalize file paths to relative:
 * - Strip known repo prefixes
 * - Remove ~/.claude/plans and .state paths
 * - Deduplicate
 * - Cap at 20, then "+N autres"
 */
export function normalizeFilePaths(
  paths: string[],
  repoPaths: string[]
): string[] {
  const HOME = expandHome("~");
  const knownPrefixes = [
    ...repoPaths.map((p) => expandHome(p).replace(/\/?$/, "/")),
    HOME + "/",
  ];

  const normalized = new Set<string>();

  for (const p of paths) {
    // Skip plans and state directories
    if (p.includes("/.claude/plans") || p.includes("/.state")) continue;

    let relative = p;
    for (const prefix of knownPrefixes) {
      if (p.startsWith(prefix)) {
        relative = p.slice(prefix.length);
        break;
      }
    }

    // Skip if still looks like an absolute path outside known repos
    if (relative.startsWith("/")) {
      // Take last 2 path segments as a reasonable fallback
      const parts = relative.split("/").filter(Boolean);
      relative = parts.slice(-2).join("/");
    }

    if (relative) normalized.add(relative);
  }

  const arr = [...normalized];
  if (arr.length <= 20) return arr;
  return [...arr.slice(0, 20), `+${arr.length - 20} autres`];
}

// ── Record page ───────────────────────────────────────────────────────────────

export function buildRecordId(session: SessionCondensed, primaryProject: string): string {
  const dateSlug = session.date.replace(/-/g, "");
  return `rec_${dateSlug}_${toSlug(primaryProject)}_${shortId(session.id)}`;
}

export function writeRecord(
  session: SessionCondensed,
  digest: SessionDigest,
  config: BrainConfig,
  allRepoPaths: string[] = []
): string {
  const primaryProject = digest.projects[0] ?? session.projectNameHint;
  const recordId = buildRecordId(session, primaryProject);
  const projectLinks = digest.projects.map((p) => `[[proj_${toSlug(p)}]]`);

  const fm: PageFrontmatter = {
    id: recordId,
    type: "record",
    title: digest.title,
    project: digest.projects,
    created: session.date,
    updated: today(),
    sources: [`session:${session.id}`],
    links: projectLinks,
    group: "Records",
  };

  const sections: string[] = [];

  // Summary
  sections.push(`## Résumé\n${digest.summary}`);

  // Decisions
  const decisions = digest.elements.filter((e) => e.kind === "décision");
  if (decisions.length > 0) {
    const { validIds } = buildPlaceholderIds([recordId]);
    const items = decisions.map((e) => renderElement(llmToStored(e, session.date, recordId), validIds));
    sections.push(section("Décisions", items));
  }

  // Faits
  const facts = digest.elements.filter((e) => e.kind === "fait");
  if (facts.length > 0) {
    const { validIds } = buildPlaceholderIds([recordId]);
    const items = facts.map((e) => renderElement(llmToStored(e, session.date, recordId), validIds));
    sections.push(section("Faits importants", items));
  }

  // Leçons
  const lessons = digest.elements.filter((e) => e.kind === "leçon");
  if (lessons.length > 0) {
    const { validIds } = buildPlaceholderIds([recordId]);
    const items = lessons.map((e) => renderElement(llmToStored(e, session.date, recordId), validIds));
    sections.push(section("Erreurs & leçons", items));
  }

  // Tâches
  const tasks = digest.elements.filter((e) => e.kind === "tâche");
  if (tasks.length > 0) {
    const { validIds } = buildPlaceholderIds([recordId]);
    const items = tasks.map((e) => renderElement(llmToStored(e, session.date, recordId), validIds));
    sections.push(section("Tâches ouvertes", items));
  }

  // Préférences
  const prefs = digest.elements.filter((e) => e.kind === "préférence");
  if (prefs.length > 0) {
    const { validIds } = buildPlaceholderIds([recordId]);
    const items = prefs.map((e) => renderElement(llmToStored(e, session.date, recordId), validIds));
    sections.push(section("Préférences", items));
  }

  // Mesures
  const measures = digest.elements.filter((e) => e.kind === "mesure");
  if (measures.length > 0) {
    const { validIds } = buildPlaceholderIds([recordId]);
    const items = measures.map((e) => renderElement(llmToStored(e, session.date, recordId), validIds));
    sections.push(section("Mesures", items));
  }

  // Files touched
  const allPaths = [...new Set([...digest.files_touched, ...session.filesModified])];
  const normalized = normalizeFilePaths(allPaths, allRepoPaths);
  if (normalized.length > 0) {
    sections.push(section("Fichiers touchés", normalized));
  }

  const content =
    frontmatterBlock(fm) + "\n" + sections.filter(Boolean).join("\n\n") + "\n";

  const filePath = recordFilePath(config, session.id, session.date, primaryProject);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");

  return recordId;
}

/** Build a Set of known IDs for link validation — seed with what we know so far */
function buildPlaceholderIds(known: string[]): { validIds: Set<string> } {
  return { validIds: new Set(known) };
}

// ── Project page — rendering ──────────────────────────────────────────────────

function renderProjectPage(
  state: ProjectState,
  allIds: Set<string>
): string {
  const fm: PageFrontmatter = {
    id: state.id,
    type: "project",
    title: state.title,
    project: state.id.replace(/^proj_/, ""),
    created: state.created,
    updated: state.updated,
    sources: [
      ...state.repoSources,
      ...state.recordSources.map((id) => `session:${id}`),
    ],
    links: [
      ...state.recordSources.filter((id) => allIds.has(id)).map((id) => `[[${id}]]`),
      ...state.linkedProjects.map((p) => `[[${p}]]`),
      ...state.linkedPeople.map((p) => `[[${p}]]`),
    ],
    group: "Projects",
  };

  const sections: string[] = [];

  if (state.goal) sections.push(`## But\n${state.goal}`);
  if (state.stack) sections.push(`## Stack\n${state.stack}`);
  if (state.remote) sections.push(`## Remote\n${state.remote}`);
  if (state.etatActuel) sections.push(`## État actuel\n${state.etatActuel}`);

  // Decisions — active first, then ❌
  const decs = state.elements.filter((e) => e.kind === "décision");
  if (decs.length > 0) {
    const active = decs.filter((e) => e.statut !== "❌");
    const closed = decs.filter((e) => e.statut === "❌");
    const items = [...active, ...closed].map((e) => renderElement(e, allIds));
    sections.push(section("Décisions structurantes", items));
  }

  // Lessons (project-specific)
  const lessons = state.elements.filter((e) => e.kind === "leçon" && e.scope !== "transverse");
  if (lessons.length > 0) {
    sections.push(section("Leçons", lessons.map((e) => renderElement(e, allIds))));
  }

  // Open tasks (not ❌ and not ✅)
  const tasks = state.elements.filter((e) => e.kind === "tâche" && e.statut !== "❌" && e.statut !== "✅");
  if (tasks.length > 0) {
    sections.push(section("Tâches ouvertes", tasks.map((e) => renderElement(e, allIds))));
  }

  // Notable facts
  const facts = state.elements.filter((e) => e.kind === "fait");
  if (facts.length > 0) {
    sections.push(section("Faits notables", facts.map((e) => renderElement(e, allIds))));
  }

  // Measures — only latest value per nom (already deduped in state via ID)
  const measures = state.elements.filter((e) => e.kind === "mesure");
  if (measures.length > 0) {
    sections.push(section("Mesures", measures.map((e) => renderElement(e, allIds))));
  }

  if (state.linkedProjects.length > 0) {
    sections.push(section("Projets liés", state.linkedProjects.map((p) => `[[${p}]]`)));
  }

  if (state.linkedPeople.length > 0) {
    sections.push(section("Personnes", state.linkedPeople.map((p) => `[[${p}]]`)));
  }

  // Records
  const recordLinks = state.recordSources.filter((id) => allIds.has(id));
  if (recordLinks.length > 0) {
    sections.push(section("Fiches liées", recordLinks.map((id) => `[[${id}]]`)));
  }

  return frontmatterBlock(fm) + "\n" + sections.filter(Boolean).join("\n\n") + "\n";
}

function writeProjectPage(state: ProjectState, config: BrainConfig, allIds: Set<string>): void {
  const slug = state.id.replace(/^proj_/, "");
  const dir = slug.startsWith("people/")
    ? peopleDir(config)
    : projectsDir(config);
  fs.mkdirSync(dir, { recursive: true });
  const filePath = path.join(dir, `${toSlug(slug)}.md`);
  const content = validateLinks(renderProjectPage(state, allIds), allIds);
  fs.writeFileSync(filePath, content, "utf8");
}

// ── Project update from session ───────────────────────────────────────────────

export function updateProjectFromSession(
  projectSlug: string,
  digest: SessionDigest,
  sessionDate: string,
  recordId: string,
  config: BrainConfig,
  allIds: Set<string>
): void {
  const projectId = `proj_${toSlug(projectSlug)}`;
  const state = loadProjectState(projectId, config);

  if (!state.recordSources.includes(recordId)) {
    state.recordSources.push(recordId);
  }

  // Update etat_actuel if session provides one for this project
  const ps = digest.project_states.find(
    (p) => toSlug(p.project) === toSlug(projectSlug)
  );
  if (ps?.etat_actuel) {
    state.etatActuel = ps.etat_actuel;
  }

  // Convert and merge elements for this project
  const newElements: StoredElement[] = digest.elements
    .filter((e) =>
      e.projets.some((p) => toSlug(p) === toSlug(projectSlug))
    )
    .filter((e) => e.kind !== "préférence")
    .filter((e) => !(e.kind === "leçon" && e.scope === "transverse"))
    .map((e) => llmToStored(e, sessionDate, recordId));

  state.elements = mergeElements(state.elements, newElements);

  // Apply task closures reported by the LLM
  state.elements = applyTaskClosures(
    state.elements,
    digest.taches_faites ?? [],
    digest.taches_abandonnees ?? [],
    sessionDate,
    recordId
  );

  // Apply decision replacements reported by the LLM
  state.elements = applyDecisionReplacements(
    state.elements,
    digest.remplacees ?? [],
    sessionDate,
    recordId
  );

  // Track linked people
  for (const name of digest.people ?? []) {
    const pid = `people_${toSlug(name)}`;
    if (!state.linkedPeople.includes(pid)) {
      state.linkedPeople.push(pid);
    }
  }

  saveProjectState(state, config);
  writeProjectPage(state, config, allIds);
}

// ── Project update from repo ──────────────────────────────────────────────────

export function updateProjectFromRepo(
  repo: RepoCondensed,
  repoDigest: RepoDigest,
  config: BrainConfig,
  allIds: Set<string>
): string {
  // Deduplicate by remote URL first, then by slug.
  // Two repos with different remotes must never share the same state file,
  // even if Claude picked the same slug for both.
  let projectId = `proj_${toSlug(repoDigest.slug)}`;
  if (repoDigest.remote) {
    const dir = stateDir(config);
    if (fs.existsSync(dir)) {
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith(".json")) continue;
        try {
          const st = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8")) as ProjectState;
          if (st.remote === repoDigest.remote) {
            projectId = st.id;
            break;
          }
        } catch {}
      }
    }
  }
  const state = loadProjectState(projectId, config);

  // Update or set repo meta
  state.title = repoDigest.name;
  state.goal = repoDigest.goal;
  state.stack = repoDigest.stack;
  state.remote = repoDigest.remote;

  const repoSource = `repo:${repo.path}`;
  if (!state.repoSources.includes(repoSource)) {
    state.repoSources.push(repoSource);
  }

  // Set initial etatActuel from repo activity if none
  if (!state.etatActuel) {
    state.etatActuel = repoDigest.recentActivity;
  }

  saveProjectState(state, config);
  writeProjectPage(state, config, allIds);
  return projectId;
}

/** Export alias used in cli.ts */
export const writeProjectFromRepo = updateProjectFromRepo;

// ── Lessons page ──────────────────────────────────────────────────────────────

export function updateLessons(
  digest: SessionDigest,
  sessionDate: string,
  recordId: string,
  config: BrainConfig,
  allIds: Set<string>
): void {
  const state = loadGlobalState("lessons", config);

  const newLessons: StoredElement[] = digest.elements
    .filter((e) => e.kind === "leçon" && e.scope === "transverse")
    .map((e) => llmToStored(e, sessionDate, recordId));

  if (newLessons.length === 0) return;

  state.elements = mergeElements(state.elements, newLessons);
  saveGlobalState(state, config);
  renderAndWriteLessonsPage(state, config, allIds);
}

function renderAndWriteLessonsPage(
  state: GlobalState,
  config: BrainConfig,
  allIds: Set<string>
): void {
  const lessonsPath = path.join(brainDir(config), "lessons.md");

  const fm: PageFrontmatter = {
    id: "lessons",
    type: "lesson",
    title: "Leçons transverses",
    project: [],
    created: "2026-11-26",
    updated: today(),
    sources: [],
    links: [],
    group: "Lessons",
  };

  // Group by domaine
  const byDomaine = new Map<string, StoredElement[]>();
  for (const elem of state.elements) {
    const d = elem.domaine ?? "general";
    if (!byDomaine.has(d)) byDomaine.set(d, []);
    byDomaine.get(d)!.push(elem);
  }

  const DOMAINE_LABELS: Record<string, string> = {
    "shell": "Shell",
    "git": "Git",
    "macos": "macOS",
    "nextjs": "Next.js",
    "vercel": "Vercel",
    "swift": "Swift",
    "claude-code": "Claude Code",
    "general": "Général",
  };

  const sections: string[] = [];
  for (const [domaine, elems] of [...byDomaine.entries()].sort()) {
    const label = DOMAINE_LABELS[domaine] ?? domaine;
    sections.push(section(label, elems.map((e) => renderElement(e, allIds))));
  }

  const content = [
    frontmatterBlock(fm),
    "Leçons et pièges applicables à tous les projets.",
    ...sections.filter(Boolean),
  ].join("\n\n");

  fs.writeFileSync(lessonsPath, validateLinks(content, allIds) + "\n", "utf8");
}

// ── Louis page ────────────────────────────────────────────────────────────────

export function updateLouis(
  digest: SessionDigest,
  sessionDate: string,
  recordId: string,
  config: BrainConfig,
  allIds: Set<string>
): void {
  const state = loadGlobalState("louis", config);

  const newPrefs: StoredElement[] = digest.elements
    .filter((e) => e.kind === "préférence")
    .map((e) => llmToStored(e, sessionDate, recordId));

  if (newPrefs.length === 0) return;

  state.elements = mergeElements(state.elements, newPrefs);
  saveGlobalState(state, config);
  renderAndWriteLouisPage(state, config, allIds);
}

function renderAndWriteLouisPage(
  state: GlobalState,
  config: BrainConfig,
  allIds: Set<string>
): void {
  const louisPath = path.join(brainDir(config), "louis.md");

  const fm: PageFrontmatter = {
    id: "louis",
    type: "person",
    title: "Louis",
    project: [],
    created: "2026-11-26",
    updated: today(),
    sources: [...new Set(state.elements.flatMap((e) => e.sources))],
    links: [],
    group: "Louis",
  };

  // Group preferences by project scope
  // Global: projets is empty or contains only non-project-slug entries
  // Project-specific: projets contains a project slug
  const globalElems: StoredElement[] = [];
  const byProject = new Map<string, StoredElement[]>();

  for (const elem of state.elements) {
    const projectSlugs = (elem.projets ?? []).filter(
      (p) => p && !p.startsWith("people/")
    );
    if (projectSlugs.length === 0) {
      globalElems.push(elem);
    } else {
      for (const slug of projectSlugs) {
        if (!byProject.has(slug)) byProject.set(slug, []);
        byProject.get(slug)!.push(elem);
      }
    }
  }

  const sections: string[] = [];

  if (globalElems.length > 0) {
    sections.push(
      section("Préférences globales", globalElems.map((e) => renderElement(e, allIds)))
    );
  }

  // Sort project sections alphabetically
  for (const slug of [...byProject.keys()].sort()) {
    const elems = byProject.get(slug)!;
    sections.push(
      section(slug, elems.map((e) => renderElement(e, allIds)))
    );
  }

  const content = [
    frontmatterBlock(fm),
    "Préférences et règles de travail de Louis, utiles pour Claude.",
    ...sections.filter(Boolean),
  ].join("\n\n");

  fs.writeFileSync(louisPath, validateLinks(content, allIds) + "\n", "utf8");
}

// ── People pages ──────────────────────────────────────────────────────────────

export function updatePeople(
  digest: SessionDigest,
  sessionDate: string,
  recordId: string,
  config: BrainConfig,
  allIds: Set<string>
): void {
  for (const name of digest.people ?? []) {
    const slug = toSlug(name);
    const id = `people_${slug}`;
    const state = loadGlobalState(id, config);

    // Elements explicitly tagged for this person
    const personElements: StoredElement[] = digest.elements
      .filter((e) => e.projets.some((p) => toSlug(p) === `people/${slug}` || p === slug))
      .map((e) => llmToStored(e, sessionDate, recordId));

    if (personElements.length > 0) {
      state.elements = mergeElements(state.elements, personElements);
      saveGlobalState(state, config);
    }

    // Always create/update the person page when mentioned
    renderAndWritePersonPage(id, name, state, config, allIds, recordId);
  }
}

function renderAndWritePersonPage(
  id: string,
  name: string,
  state: GlobalState,
  config: BrainConfig,
  allIds: Set<string>,
  recordId: string
): void {
  const slug = id.replace(/^people_/, "");
  const dir = peopleDir(config);
  fs.mkdirSync(dir, { recursive: true });
  const filePath = path.join(dir, `${slug}.md`);

  // Keep existing content if page already exists (don't overwrite manual edits)
  if (fs.existsSync(filePath)) return;

  const fm: PageFrontmatter = {
    id,
    type: "person",
    title: name,
    project: [],
    created: today(),
    updated: today(),
    sources: [`session:${recordId}`],
    links: [],
    group: "People",
  };

  const sections: string[] = [];
  if (state.elements.length > 0) {
    sections.push(
      section("Notes", state.elements.map((e) => renderElement(e, allIds)))
    );
  }

  const content = sections.filter(Boolean).length > 0
    ? [frontmatterBlock(fm), ...sections.filter(Boolean)].join("\n\n")
    : frontmatterBlock(fm);

  fs.writeFileSync(filePath, validateLinks(content, allIds) + "\n", "utf8");
}

// ── Rebuild all pages from state (re-render without LLM calls) ───────────────

/**
 * Re-render all project pages, lessons.md, and louis.md from their state files.
 * Use after manually patching state files or when pages are stale.
 */
export function rebuildAllPages(config: BrainConfig): string[] {
  const allIds = collectAllIds(config);
  allIds.add("lessons");
  allIds.add("louis");
  allIds.add("index");

  const rebuilt: string[] = [];

  // Project pages
  const sDir = stateDir(config);
  if (fs.existsSync(sDir)) {
    for (const f of fs.readdirSync(sDir)) {
      if (!f.endsWith(".json") || f === "lessons.json" || f === "louis.json") continue;
      try {
        const state = JSON.parse(
          fs.readFileSync(path.join(sDir, f), "utf8")
        ) as ProjectState;
        // Pre-register all IDs in this project state
        for (const e of state.elements) allIds.add(e.id);
        for (const r of state.recordSources) allIds.add(r);
        writeProjectPage(state, config, allIds);
        rebuilt.push(`projects/${state.id.replace(/^proj_/, "")}.md`);
      } catch {}
    }
  }

  // Lessons
  const lessonsState = loadGlobalState("lessons", config);
  if (lessonsState.elements.length > 0) {
    renderAndWriteLessonsPage(lessonsState, config, allIds);
    rebuilt.push("lessons.md");
  }

  // Louis
  const louisState = loadGlobalState("louis", config);
  if (louisState.elements.length > 0) {
    renderAndWriteLouisPage(louisState, config, allIds);
    rebuilt.push("louis.md");
  }

  rebuildIndex(config);
  rebuilt.push("INDEX.md");

  return rebuilt;
}

// ── Open elements getter (for digest prompt context) ─────────────────────────

/**
 * Returns all open tasks and active decisions from all project states.
 * Passed to the LLM digest so it can reference IDs for closure/replacement.
 */
export function getOpenElements(config: BrainConfig): OpenElementHint[] {
  const dir = stateDir(config);
  if (!fs.existsSync(dir)) return [];

  const result: OpenElementHint[] = [];
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith(".json")) continue;
    // Skip global states (lessons, louis)
    if (f === "lessons.json" || f === "louis.json") continue;
    try {
      const state = JSON.parse(
        fs.readFileSync(path.join(dir, f), "utf8")
      ) as ProjectState;
      for (const elem of state.elements) {
        if (
          (elem.kind === "tâche" && elem.statut !== "❌" && elem.statut !== "✅") ||
          (elem.kind === "décision" && elem.statut === "✅")
        ) {
          result.push({
            id: elem.id,
            kind: elem.kind,
            texte: elem.texte,
            statut: elem.statut ?? null,
            projets: Array.isArray(elem.projets) ? elem.projets : [],
          });
        }
      }
    } catch {}
  }
  return result;
}

// ── Global link validation pass ───────────────────────────────────────────────

/**
 * After all pages are written, do a final pass to fix any remaining
 * [[invalid]] links across all .md files.
 */
export function validateAllLinks(config: BrainConfig, allIds: Set<string>): string[] {
  const base = brainDir(config);
  const dirs = [
    base,
    path.join(base, "records"),
    path.join(base, "projects"),
    path.join(base, "people"),
  ];

  const fixed: string[] = [];

  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith(".md")) continue;
      const filePath = path.join(dir, f);
      const original = fs.readFileSync(filePath, "utf8");
      const updated = validateLinks(original, allIds);
      if (updated !== original) {
        fs.writeFileSync(filePath, updated, "utf8");
        fixed.push(path.relative(base, filePath));
      }
    }
  }

  return fixed;
}

// ── Collect all valid page IDs from brain directory ───────────────────────────

export function collectAllIds(config: BrainConfig): Set<string> {
  const base = brainDir(config);
  const ids = new Set<string>();
  const dirs = [
    base,
    path.join(base, "records"),
    path.join(base, "projects"),
    path.join(base, "people"),
  ];

  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith(".md")) continue;
      try {
        const raw = fs.readFileSync(path.join(dir, f), "utf8");
        const { data } = matter(raw);
        if (data.id) ids.add(data.id as string);
      } catch {}
    }
  }

  return ids;
}

// ── INDEX.md ──────────────────────────────────────────────────────────────────

export function rebuildIndex(config: BrainConfig): void {
  const base = brainDir(config);
  const indexPath = path.join(base, "INDEX.md");
  const allIds = collectAllIds(config);

  const lines: string[] = [
    "---",
    "id: index",
    "type: index",
    `title: "Index CoucouBrain"`,
    "project: []",
    `created: 2026-11-26`,
    `updated: ${today()}`,
    "sources: []",
    "links: []",
    "group: Reference",
    "---",
    "",
    `Dernière mise à jour : ${today()}`,
    "",
    "## Projets",
  ];

  // List project pages with current state summary
  const pDir = path.join(base, "projects");
  if (fs.existsSync(pDir)) {
    for (const f of fs.readdirSync(pDir).sort()) {
      if (!f.endsWith(".md")) continue;
      try {
        const raw = fs.readFileSync(path.join(pDir, f), "utf8");
        const { data } = matter(raw);
        const id = data.id ?? f;
        const title = data.title ?? f;
        // Try to get état actuel from state file
        const stateFile = path.join(stateDir(config), `${id}.json`);
        let summary = "";
        if (fs.existsSync(stateFile)) {
          const st = JSON.parse(fs.readFileSync(stateFile, "utf8")) as ProjectState;
          if (st.etatActuel) {
            const firstLine = st.etatActuel.split(/[.\n]/)[0]?.trim() ?? "";
            if (firstLine) {
              const truncated = firstLine.length > 80
                ? firstLine.slice(0, 80).replace(/\s\S+$/, "…")
                : firstLine;
              summary = ` — ${truncated}`;
            }
          }
        }
        const updatedRaw = data.updated;
        const updatedStr = updatedRaw instanceof Date
          ? updatedRaw.toISOString().slice(0, 10)
          : String(updatedRaw ?? "?").slice(0, 10);
        lines.push(`- [[${id}]] — ${title}${summary} _(mis à jour ${updatedStr})_`);
      } catch {}
    }
  }

  // People pages
  const ppDir = path.join(base, "people");
  if (fs.existsSync(ppDir)) {
    const peopleFiles = fs.readdirSync(ppDir).filter((f) => f.endsWith(".md"));
    if (peopleFiles.length > 0) {
      lines.push("", "## Personnes");
      for (const f of peopleFiles.sort()) {
        try {
          const raw = fs.readFileSync(path.join(ppDir, f), "utf8");
          const { data } = matter(raw);
          lines.push(`- [[${data.id ?? f}]] — ${data.title ?? f}`);
        } catch {}
      }
    }
  }

  lines.push("", "## Fiches récentes (30 dernières)");

  const rDir = path.join(base, "records");
  if (fs.existsSync(rDir)) {
    const files = fs
      .readdirSync(rDir)
      .filter((f) => f.endsWith(".md"))
      .sort()
      .reverse()
      .slice(0, 30);
    for (const f of files) {
      try {
        const raw = fs.readFileSync(path.join(rDir, f), "utf8");
        const { data } = matter(raw);
        const proj = Array.isArray(data.project)
          ? data.project.join(", ")
          : data.project;
        lines.push(`- [[${data.id ?? f}]] — ${data.title ?? f} _(${proj})_`);
      } catch {}
    }
  }

  lines.push("", "## Pages clés");
  lines.push("- [[lessons]] — Leçons transverses");
  lines.push("- [[louis]] — Préférences & règles de Louis");

  fs.writeFileSync(indexPath, validateLinks(lines.join("\n") + "\n", allIds), "utf8");
}

// ── Brain init ────────────────────────────────────────────────────────────────

export function ensureBrainDir(config: BrainConfig): void {
  const base = brainDir(config);
  fs.mkdirSync(path.join(base, "records"), { recursive: true });
  fs.mkdirSync(path.join(base, "projects"), { recursive: true });
  fs.mkdirSync(path.join(base, "people"), { recursive: true });
  fs.mkdirSync(path.join(base, ".state", "digestion"), { recursive: true });
  fs.mkdirSync(path.join(base, ".state", "proj"), { recursive: true });

  if (!fs.existsSync(path.join(base, ".git"))) {
    spawnSync("git", ["init"], { cwd: base, encoding: "utf8" });
    console.log(`  ✓ git init dans ${base}`);
  }

  const gitignorePath = path.join(base, ".gitignore");
  if (!fs.existsSync(gitignorePath)) {
    fs.writeFileSync(gitignorePath, ".state/\n", "utf8");
  }
}

// ── Git commit ─────────────────────────────────────────────────────────────────

export function gitCommit(config: BrainConfig, message: string): void {
  const base = brainDir(config);
  try {
    spawnSync("git", ["add", "-A"], { cwd: base, encoding: "utf8" });
    const result = spawnSync("git", ["commit", "-m", message], {
      cwd: base,
      encoding: "utf8",
    });
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
