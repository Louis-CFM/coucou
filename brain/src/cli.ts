#!/usr/bin/env node
/**
 * brain CLI — entry point
 *
 * brain ingest [--since YYYY-MM-DD] [--project <name>] [--limit <n>] [--dry-run] [--include-subagents]
 *             [--session <id...>] [--repo <name...>] [--repos-only] [--sessions-only]
 * brain stats
 */
import { Command } from "commander";
import crypto from "node:crypto";
import fs from "node:fs";
import { spawnSync as _spawnSync } from "node:child_process";
import path from "node:path";
import { loadConfig } from "./config.js";
import { expandHome, toSlug } from "./utils.js";
import {
  discoverSessions,
  discoverRepos,
  readSession,
  collectRepo,
  collectClaudeExport,
  formatConversationAsSessionCondensed,
} from "./collect.js";
import { Manifest } from "./manifest.js";
import { digestSessionWithRetry, digestRepo, digestPromptHash } from "./digest.js";
import {
  ensureBrainDir,
  writeRecord,
  recordFilePath,
  updateProjectFromSession,
  updateProjectFromRepo,
  updateLessons,
  updateLouis,
  updatePeople,
  validateAllLinks,
  collectAllIds,
  rebuildIndex,
  rebuildAllPages,
  gitCommit,
  normalizeFilePaths,
  getOpenElements,
} from "./write.js";
import { computeStats } from "./stats.js";
import { runCoverage, formatCoverageResult } from "./coverage.js";
import { rebuildFts, writeHooksConfig, appendCorrection } from "./fts.js";
import { maskSecrets } from "./mask.js";
import type { StoredElement } from "./elements.js";

const program = new Command();

program
  .name("brain")
  .description("Coucou Brain — digest Claude Code sessions and repos into a Markdown knowledge base")
  .version("0.1.0");

// ── safety guard ──────────────────────────────────────────────────────────────

function assertNoRemote(brainPath: string): void {
  const expanded = expandHome(brainPath);
  const result = _spawnSync("git", ["-C", expanded, "remote"], { encoding: "utf8" });
  if (result.stdout?.trim()) {
    console.error(
      "❌  CoucouBrain a un remote git configuré (" +
        result.stdout.trim().split("\n").join(", ") +
        ").\n" +
        "   Ce repo contient de la mémoire de travail en clair — retire le remote avant de continuer :\n" +
        "   git -C " + expanded + " remote remove <nom>"
    );
    process.exit(1);
  }
}

// ── ingest ────────────────────────────────────────────────────────────────────

program
  .command("ingest")
  .description("Digest sessions and repos into ~/CoucouBrain/")
  .option("--since <date>", "Only sessions after this date (YYYY-MM-DD)")
  .option("--project <name>", "Only process sessions matching this project name")
  .option("--session <id...>", "Only process these session UUIDs (space-separated or repeated)")
  .option("--repo <name...>", "Only process repos whose path contains this name")
  .option("--limit <n>", "Max number of sessions to process", parseInt)
  .option("--dry-run", "Show what would be processed without calling the model")
  .option("--include-subagents", "Also process subagent sessions")
  .option("--repos-only", "Only process repos, skip sessions")
  .option("--sessions-only", "Only process sessions, skip repos")
  .option("--force", "Re-digest sessions even if already processed with the same prompt version")
  .option("--claude-export <path>", "Ingest a Claude.ai data export (zip or folder with conversations.json)")
  .action(async (opts) => {
    const config = loadConfig();
    assertNoRemote(config.brainPath);
    const manifest = new Manifest(config.brainPath);
    const currentPromptHash = digestPromptHash();

    if (!opts.dryRun) {
      ensureBrainDir(config);
    }

    // Collect repo paths for file normalization
    const allRepoPaths = [
      ...config.repoPaths.map((p: string) => expandHome(p)),
      ...(config.additionalRepoPaths ?? []).map((p: string) => expandHome(p)),
    ];

    // ── Sessions ──────────────────────────────────────────────────────────────
    if (!opts.reposOnly) {
      const allDiscovered = discoverSessions(config, {
        includeSubagents: opts.includeSubagents,
        sinceDate: opts.since,
        projectFilter: opts.project,
      });

      const activeSessions = allDiscovered.filter((s) => s.isActive);
      const discovered = allDiscovered.filter((s) => !s.isActive);

      if (activeSessions.length > 0) {
        console.log(
          `\n  ⏭  ${activeSessions.length} session(s) active(s) ignorée(s) (modifiée(s) il y a < ${config.activeSessionMinutes ?? 30} min) :`
        );
        for (const s of activeSessions) {
          console.log(`     ${s.id.slice(0, 8)}…  ${s.projectPath.slice(-40)}`);
        }
      }

      for (const s of discovered) {
        manifest.upsertSession({
          id: s.id,
          project_path: s.projectPath,
          jsonl_path: s.jsonlPath,
          hash: s.hash,
        });
      }

      const discoveredIds = new Set(discovered.map((d) => d.id));
      // Date lookup for chronological sort (oldest→newest so latest session wins etatActuel)
      const discoveredDateById = new Map(discovered.map((d) => [d.id, d.date]));
      let pending = manifest
        .getPendingSessions()
        .filter((s) => discoveredIds.has(s.id))
        .sort((a, b) => {
          const da = discoveredDateById.get(a.id) ?? "0";
          const db = discoveredDateById.get(b.id) ?? "0";
          return da.localeCompare(db);
        });

      // --session filter
      if (opts.session?.length) {
        const ids: string[] = opts.session;
        pending = pending.filter((s) =>
          ids.some((id) => s.id === id || s.id.startsWith(id))
        );
        for (const id of ids) {
          const done = manifest.getAllSessions().find(
            (s) => (s.id === id || s.id.startsWith(id)) && s.status === "done"
          );
          if (done && !pending.find((p) => p.id === done.id)) {
            // Skip if prompt unchanged and not --force
            if (!opts.force && manifest.isUpToDate(done.id, currentPromptHash)) {
              console.log(`  ⏭  ${done.id.slice(0, 8)}… déjà digéré avec le même prompt (--force pour forcer)`);
              continue;
            }
            manifest.resetSessionToPending(done.id);
            pending.push({ ...done, status: "pending" });
          }
        }
      }

      const toProcess = opts.limit ? pending.slice(0, opts.limit) : pending;

      console.log("\n📚 Sessions");
      console.log(`  Découvertes : ${discovered.length}`);
      console.log(`  À traiter   : ${pending.length}`);
      if (opts.limit) console.log(`  Limitées à  : ${toProcess.length}`);

      if (opts.dryRun) {
        console.log("\n--- DRY RUN : sessions ---");
        let totalTokens = 0;
        for (const s of toProcess) {
          const disc = discovered.find((d) => d.id === s.id)!;
          try {
            const condensed = readSession(s.jsonl_path);
            totalTokens += condensed.estimatedTokens;
            const maskedCount = condensed.masked.reduce((n, m) => n + m.count, 0);
            const rawKb = (disc.sizeBytes / 1024).toFixed(0);
            const tokens = condensed.estimatedTokens.toLocaleString();
            console.log(
              `  ${disc.date}  ${s.project_path.slice(-45).padEnd(47)}` +
                `  ~${tokens} tokens  ${rawKb}KB raw` +
                (maskedCount > 0 ? `  🔒 ${maskedCount} masqués` : "")
            );
          } catch (e) {
            console.log(
              `  ${s.id.slice(0, 8)}  [erreur: ${(e as Error).message.slice(0, 60)}]`
            );
          }
        }
        console.log(`\n  Total estimé : ~${totalTokens.toLocaleString()} tokens condensés`);
      } else {
        const maskedByType: Record<string, number> = {};
        let doneCount = 0;
        let failCount = 0;

        for (const s of toProcess) {
          const idx = doneCount + failCount + 1;
          console.log(
            `\n  [${idx}/${toProcess.length}] ${s.project_path.slice(-50)} / ${s.id.slice(0, 8)}…`
          );

          // Track record file path so we can delete it on failure
          let recordFileCreated: string | null = null;

          try {
            const condensed = readSession(s.jsonl_path);
            console.log(`    ~${condensed.estimatedTokens.toLocaleString()} tokens condensés`);

            // Skip near-empty sessions — not enough content for meaningful digest
            if (condensed.estimatedTokens < 30) {
              console.log(`    ⏭  session quasi vide, ignorée`);
              manifest.markSessionIgnored(s.id);
              continue;
            }

            for (const m of condensed.masked) {
              maskedByType[m.type] = (maskedByType[m.type] ?? 0) + m.count;
            }

            const openElements = getOpenElements(config);
            if (openElements.length > 0) {
              console.log(`    ${openElements.length} éléments ouverts transmis au modèle`);
            }

            const digest = await digestSessionWithRetry(condensed, config, openElements);
            // Fallback: if LLM returned no projects, use the session's project path hint
            if (digest.projects.length === 0) {
              digest.projects = [condensed.projectNameHint];
            }
            const primaryProject = digest.projects[0]!;

            // Build current valid IDs (before writing this record)
            const allIds = collectAllIds(config);

            const recordId = writeRecord(condensed, digest, config, allRepoPaths);
            recordFileCreated = recordFilePath(
              config,
              condensed.id,
              condensed.date,
              primaryProject
            );

            // Pre-register all IDs this session will produce
            allIds.add(recordId);
            for (const proj of digest.projects) {
              allIds.add(`proj_${toSlug(proj)}`);
            }
            for (const name of (digest.people ?? [])) {
              allIds.add(`people_${toSlug(name)}`);
            }
            allIds.add("lessons");
            allIds.add("louis");

            // Merge into project pages
            for (const proj of digest.projects) {
              const slug = toSlug(proj);
              console.log(`    → merge dans projects/${slug}.md`);
              updateProjectFromSession(slug, digest, condensed.date, recordId, config, allIds);
            }

            // Update global pages
            updateLessons(digest, condensed.date, recordId, config, allIds);
            updateLouis(digest, condensed.date, recordId, config, allIds);
            updatePeople(digest, condensed.date, recordId, config, allIds);

            manifest.markSessionDone(s.id, recordId, digest.projects, currentPromptHash);
            doneCount++;
            console.log(`    ✓ ${recordId}`);
          } catch (e) {
            console.error(`    ✗ Échec: ${(e as Error).message.slice(0, 200)}`);
            manifest.markSessionFailed(s.id);
            failCount++;

            // Clean up: delete record file if it was created before the failure
            if (recordFileCreated && fs.existsSync(recordFileCreated)) {
              fs.unlinkSync(recordFileCreated);
              console.log(`    🗑  fiche supprimée (échec propre)`);
            }
          }
        }

        console.log(`\n  Sessions : ${doneCount} OK, ${failCount} échec(s)`);
        if (Object.keys(maskedByType).length > 0) {
          console.log("  Secrets masqués :", JSON.stringify(maskedByType));
        }
      }
    }

    // ── Repos ─────────────────────────────────────────────────────────────────
    if (!opts.sessionsOnly) {
      const repos = discoverRepos(config);
      console.log(`\n🗂  Repos : ${repos.length} découverts`);

      for (const repoPath of repos) {
        manifest.upsertRepo({ path: repoPath, last_commit: "unknown" });
      }

      const repoSet = new Set(repos);
      let pendingRepos = manifest.getPendingRepos().filter((r) => repoSet.has(r.path));

      if (opts.repo?.length) {
        const names: string[] = opts.repo;
        pendingRepos = pendingRepos.filter((r) =>
          names.some((name) => r.path.toLowerCase().includes(name.toLowerCase()))
        );
      }

      if (opts.dryRun) {
        console.log("\n--- DRY RUN : repos ---");
        for (const r of pendingRepos) console.log(`  ${r.path}`);
      } else {
        let repoDone = 0;
        for (const r of pendingRepos) {
          console.log(`\n  Repo: ${r.path}`);
          try {
            const condensed = collectRepo(r.path, config.repoAliases);
            if (!condensed) {
              console.log("    pas un repo git, skip");
              continue;
            }
            if (condensed.isDataless) {
              console.log("    ☁️  déchargé par iCloud (dataless) — ignoré");
              manifest.markRepoFailed(r.path);
              continue;
            }
            const repoDigest = await digestRepo(condensed, config);
            const allIds = collectAllIds(config);
            allIds.add(`proj_${toSlug(repoDigest.slug)}`);
            const pageId = updateProjectFromRepo(condensed, repoDigest, config, allIds);
            manifest.markRepoDone(r.path, pageId);
            repoDone++;
            console.log(`    ✓ ${pageId}`);
          } catch (e) {
            console.error(`    ✗ ${(e as Error).message.slice(0, 200)}`);
            manifest.markRepoFailed(r.path);
          }
        }
        console.log(`\n  Repos : ${repoDone} OK`);
      }
    }

    // ── Claude Desktop export (--claude-export) ───────────────────────────────
    if (opts.claudeExport) {
      console.log("\n💬 Conversations Claude Desktop");
      let conversations: ReturnType<typeof collectClaudeExport> = [];
      try {
        conversations = collectClaudeExport(opts.claudeExport);
      } catch (e) {
        console.error(`  ✗ Lecture export échouée : ${(e as Error).message}`);
      }

      console.log(`  Découvertes : ${conversations.length}`);

      for (const conv of conversations) {
        manifest.upsertDesktopConversation({
          uuid: conv.uuid,
          updated_at: conv.updated_at ?? conv.created_at ?? "",
        });
      }

      const pendingDesktop = manifest.getPendingDesktopConversations()
        .filter((e) => conversations.some((c) => c.uuid === e.uuid));

      console.log(`  À traiter   : ${pendingDesktop.length}`);

      if (opts.dryRun) {
        console.log("\n--- DRY RUN : conversations ---");
        for (const e of pendingDesktop) {
          const conv = conversations.find((c) => c.uuid === e.uuid)!;
          console.log(`  ${e.updated_at.slice(0, 10)}  ${(conv.name ?? e.uuid).slice(0, 70)}`);
        }
      } else {
        let desktopDone = 0;
        let desktopFail = 0;

        for (const entry of pendingDesktop) {
          const conv = conversations.find((c) => c.uuid === entry.uuid)!;
          const idx = desktopDone + desktopFail + 1;
          console.log(
            `\n  [${idx}/${pendingDesktop.length}] ${(conv.name ?? entry.uuid).slice(0, 70)}`
          );

          let recordFileCreated: string | null = null;

          try {
            const condensed = formatConversationAsSessionCondensed(conv);
            console.log(`    ~${condensed.estimatedTokens.toLocaleString()} tokens condensés`);

            if (condensed.estimatedTokens < 30) {
              console.log(`    ⏭  conversation quasi vide, ignorée`);
              manifest.markDesktopConversationFailed(entry.uuid);
              continue;
            }

            const openElements = getOpenElements(config);
            const digest = await digestSessionWithRetry(condensed, config, openElements);
            if (digest.projects.length === 0) {
              digest.projects = [condensed.projectNameHint];
            }
            const primaryProject = digest.projects[0]!;

            const allIds = collectAllIds(config);
            const recordId = writeRecord(condensed, digest, config, allRepoPaths);
            recordFileCreated = recordFilePath(
              config,
              condensed.id,
              condensed.date,
              primaryProject
            );

            allIds.add(recordId);
            for (const proj of digest.projects) {
              allIds.add(`proj_${toSlug(proj)}`);
            }
            for (const name of (digest.people ?? [])) {
              allIds.add(`people_${toSlug(name)}`);
            }
            allIds.add("lessons");
            allIds.add("louis");

            for (const proj of digest.projects) {
              const slug = toSlug(proj);
              console.log(`    → merge dans projects/${slug}.md`);
              updateProjectFromSession(slug, digest, condensed.date, recordId, config, allIds, {
                sourceType: "desktop",
              });
            }

            updateLessons(digest, condensed.date, recordId, config, allIds);
            updateLouis(digest, condensed.date, recordId, config, allIds);
            updatePeople(digest, condensed.date, recordId, config, allIds);

            manifest.markDesktopConversationDone(
              entry.uuid,
              recordId,
              digest.projects,
              currentPromptHash
            );
            desktopDone++;
            console.log(`    ✓ ${recordId}`);
          } catch (e) {
            console.error(`    ✗ Échec: ${(e as Error).message.slice(0, 200)}`);
            manifest.markDesktopConversationFailed(entry.uuid);
            desktopFail++;

            if (recordFileCreated && fs.existsSync(recordFileCreated)) {
              fs.unlinkSync(recordFileCreated);
              console.log(`    🗑  fiche supprimée (échec propre)`);
            }
          }
        }

        console.log(`\n  Conversations : ${desktopDone} OK, ${desktopFail} échec(s)`);
      }
    }

    if (!opts.dryRun) {
      // Final link validation pass
      const allIds = collectAllIds(config);
      allIds.add("lessons");
      allIds.add("louis");
      allIds.add("index");

      const fixed = validateAllLinks(config, allIds);
      if (fixed.length > 0) {
        console.log(`\n  🔗 Liens corrigés dans : ${fixed.join(", ")}`);
      }

      rebuildIndex(config);
      const doneCount = manifest.getAllSessions().filter((s) => s.status === "done").length;
      gitCommit(config, `brain: ingestion — ${doneCount} fiches`);

      // Rebuild FTS index and write hooks config
      try {
        process.stdout.write("\n  🔍 Reconstruction de l'index FTS…");
        const { elements, corrections } = rebuildFts(config);
        console.log(` ${elements} éléments + ${corrections} corrections`);
        writeHooksConfig(config);
        console.log("  ✓ Hooks config écrite dans ~/.claude/brain-hooks.json");
      } catch (e) {
        console.warn(`  ⚠️  FTS rebuild failed (non bloquant) : ${(e as Error).message}`);
      }
    }

    manifest.close();
  });

// ── rebuild ───────────────────────────────────────────────────────────────────

program
  .command("rebuild")
  .description("Re-render all pages from state files (no LLM calls)")
  .action(() => {
    const config = loadConfig();
    const rebuilt = rebuildAllPages(config);
    console.log(`Rebuilt ${rebuilt.length} pages:`);
    rebuilt.forEach((p) => console.log(`  ${p}`));

    try {
      process.stdout.write("🔍 Reconstruction de l'index FTS… ");
      const { elements, corrections } = rebuildFts(config);
      console.log(`${elements} éléments + ${corrections} corrections`);
      writeHooksConfig(config);
      console.log("✓ Hooks config écrite dans ~/.claude/brain-hooks.json");
    } catch (e) {
      console.warn(`⚠️  FTS rebuild failed : ${(e as Error).message}`);
    }
  });

// ── stats ─────────────────────────────────────────────────────────────────────

program
  .command("stats")
  .description("Compute stats from ~/CoucouBrain/ and output JSON")
  .option("--pretty", "Pretty-print JSON")
  .action((opts) => {
    const config = loadConfig();
    const stats = computeStats(config);
    console.log(opts.pretty ? JSON.stringify(stats, null, 2) : JSON.stringify(stats));
  });

// ── coverage ──────────────────────────────────────────────────────────────────

program
  .command("coverage")
  .description("Compare brain pages to golden set and report missing elements")
  .option("--golden <path>", "Path to golden set JSON file")
  .action((opts) => {
    const config = loadConfig();
    // Priority: --golden flag > local state file (private, gitignored) > example file
    const localGoldenPath = path.join(expandHome(config.brainPath), ".state", "golden-set.json");
    const exampleGoldenPath = path.join(
      path.dirname(new URL(import.meta.url).pathname),
      "..",
      "tests",
      "golden-set.example.json"
    );
    const goldenPath = opts.golden
      ? path.resolve(opts.golden)
      : fs.existsSync(localGoldenPath)
        ? localGoldenPath
        : exampleGoldenPath;

    try {
      const result = runCoverage(config, goldenPath);
      console.log(formatCoverageResult(result));
      if (result.missing.length > 0) {
        process.exitCode = 1;
      }
    } catch (e) {
      console.error(`Coverage error: ${(e as Error).message}`);
      process.exitCode = 1;
    }
  });

// ── correct ───────────────────────────────────────────────────────────────────

program
  .command("correct <texte>")
  .description("Append a correction to ~/CoucouBrain/corrections.md under a named scope section")
  .option("--scope <scope>", "Section cible : 'global' ou slug de projet (ex: reels, sbe-hub)", "global")
  .action((texte: string, opts: { scope: string }) => {
    const config = loadConfig();
    try {
      appendCorrection(config, texte, opts.scope);
      console.log(`✓ Correction ajoutée sous §${opts.scope} dans corrections.md`);
    } catch (e) {
      console.error(`Erreur : ${(e as Error).message}`);
      process.exitCode = 1;
    }
  });

// ── ignore ────────────────────────────────────────────────────────────────────

program
  .command("ignore <session-id>")
  .description("Mark a session as ignored — it will never be digested")
  .option("--raison <text>", "Reason for ignoring (stored in manifest)")
  .action((sessionId: string, opts: { raison?: string }) => {
    const config = loadConfig();
    const manifest = new Manifest(config.brainPath);
    const existing = manifest.getSession(sessionId);
    if (!existing) {
      // Session not yet collected — upsert it as ignored
      // Find the JSONL file by scanning Claude projects dirs
      const { claudeProjectsPath } = config;
      const claudeBase = expandHome(claudeProjectsPath);
      let jsonlPath: string | null = null;
      let projectPath: string | null = null;
      try {
        for (const proj of fs.readdirSync(claudeBase)) {
          const candidate = path.join(claudeBase, proj, `${sessionId}.jsonl`);
          if (fs.existsSync(candidate)) {
            jsonlPath = candidate;
            projectPath = proj;
            break;
          }
        }
      } catch {}
      if (!jsonlPath || !projectPath) {
        console.error(`Session ${sessionId} introuvable dans ${claudeBase}`);
        process.exitCode = 1;
        manifest.close();
        return;
      }
      const hash = crypto.createHash("sha256")
        .update(fs.readFileSync(jsonlPath))
        .digest("hex")
        .slice(0, 16);
      manifest.upsertSession({ id: sessionId, project_path: projectPath, jsonl_path: jsonlPath, hash });
    }
    manifest.markSessionIgnored(sessionId, opts.raison);
    const reason = opts.raison ? ` (${opts.raison})` : "";
    console.log(`✓ Session ${sessionId} marquée 'ignored'${reason}`);
    manifest.close();
  });

// ── enrich ────────────────────────────────────────────────────────────────────

program
  .command("enrich")
  .description("Add keywords to existing elements that don't have them, then rebuild FTS")
  .option("--dry-run", "Show counts but don't write")
  .option("--project <slug>", "Restrict to one project")
  .option("--batch <n>", "Elements per LLM call (default 15)", "15")
  .action(async (opts: { dryRun?: boolean; project?: string; batch: string }) => {
    const config = loadConfig();
    assertNoRemote(config.brainPath);
    const { spawnSync } = await import("node:child_process");
    const stateDir = path.join(expandHome(config.brainPath), ".state", "proj");
    if (!fs.existsSync(stateDir)) {
      console.error("No state dir found. Run brain ingest first.");
      process.exitCode = 1;
      return;
    }

    if (!opts.dryRun) {
      const { gitCommit } = await import("./write.js");
      gitCommit(config, "brain: snapshot pré-enrich");
    }

    const batchSize = Math.max(1, Math.min(50, parseInt(opts.batch, 10) || 15));
    let totalMissing = 0;
    let totalWritten = 0;

    for (const f of fs.readdirSync(stateDir)) {
      if (!f.endsWith(".json")) continue;
      const stateFile = path.join(stateDir, f);
      let state: { id: string; elements: Array<{ id: string; kind: string; texte: string; keywords?: string[] }> };
      try {
        state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      } catch { continue; }

      if (opts.project && !state.id.includes(opts.project)) continue;

      const missing = state.elements.filter(
        (e) => !e.keywords || e.keywords.length === 0
      );
      if (missing.length === 0) continue;

      totalMissing += missing.length;
      console.log(`${state.id}: ${missing.length} elements sans keywords`);
      if (opts.dryRun) continue;

      // Process in batches
      let changed = false;
      for (let i = 0; i < missing.length; i += batchSize) {
        const batch = missing.slice(i, i + batchSize);
        const maskedBatch = batch.map((e) => ({
          id: e.id,
          kind: e.kind,
          texte: maskSecrets(e.texte).text,
        }));
        const prompt = `Génère 6 à 10 keywords de recherche FR+EN pour chaque élément.
Inclure les racines des mots composés (ex "Redesign" → "design"), synonymes, domaine, verbes d'action.

Éléments :
${JSON.stringify(maskedBatch, null, 2)}

Réponds UNIQUEMENT avec le JSON :
[{"id": "...", "keywords": ["k1", "k2", "k3", "k4", "k5", "k6"]}]`;

        const result = spawnSync(
          process.execPath,
          ["-e", `
const { spawnSync } = require('child_process');
const r = spawnSync('claude', [
  '--print', '--model', 'claude-haiku-4-5-20251001',
  '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
  '--tools', '', '--disallowed-tools', 'LSP',
], {
  input: process.argv[1], encoding: 'utf8', timeout: 60000,
  env: { ...process.env, COUCOU_BRAIN_INTERNAL: '1' }
});
process.stdout.write(r.stdout || '');
process.stderr.write(r.stderr || '');
process.exitCode = r.status || 0;
`, prompt],
          { encoding: "utf8", timeout: 90000 }
        );

        const raw = (result.stdout ?? "").trim();
        if (!raw) {
          console.error(`  Batch ${i}-${i + batch.length}: no output`);
          continue;
        }

        let parsed: Array<{ id: string; keywords: string[] }>;
        try {
          // Strip markdown code fences if present
          const json = raw.replace(/^```[a-z]*\n?/, "").replace(/\n?```$/, "");
          parsed = JSON.parse(json);
        } catch {
          console.error(`  Batch ${i}-${i + batch.length}: invalid JSON`);
          continue;
        }

        for (const item of parsed) {
          const elem = state.elements.find((e) => e.id === item.id);
          if (elem && Array.isArray(item.keywords) && item.keywords.length > 0) {
            elem.keywords = item.keywords.map((k: unknown) => String(k)).slice(0, 10);
            changed = true;
            totalWritten++;
          }
        }
        process.stdout.write(`  ${Math.min(i + batchSize, missing.length)}/${missing.length} enrichis\r`);
      }
      process.stdout.write("\n");

      if (changed) {
        fs.writeFileSync(stateFile, JSON.stringify(state, null, 2), "utf8");
      }
    }

    console.log(`\nTotal : ${totalMissing} sans keywords, ${totalWritten} enrichis`);

    if (!opts.dryRun && totalWritten > 0) {
      console.log("Rebuilding FTS...");
      const { rebuildFts: rebuild, writeHooksConfig: writeHooks } = await import("./fts.js");
      const result = rebuild(config);
      writeHooks(config);
      console.log(`FTS rebuilt: ${result.elements} elements`);
    }
  });

// ── dedup ─────────────────────────────────────────────────────────────────────

program
  .command("dedup")
  .description("Merge near-duplicate elements across all project state files, then rebuild FTS")
  .option("--dry-run", "Show counts but don't write")
  .option("--threshold <n>", "Jaccard similarity threshold (default: 0.7)", "0.7")
  .action(async (opts) => {
    const config = loadConfig();
    assertNoRemote(config.brainPath);
    const { dedupElements } = await import("./elements.js");
    type DedupJournalEntry = import("./elements.js").DedupJournalEntry;
    const brainBase = expandHome(config.brainPath);
    const stateDir = path.join(brainBase, ".state", "proj");

    if (!fs.existsSync(stateDir)) {
      console.error("State dir not found:", stateDir);
      process.exitCode = 1;
      return;
    }

    const threshold = parseFloat(opts.threshold);
    const allJournal: Array<DedupJournalEntry & { stateFile: string }> = [];
    let totalMerged = 0;

    if (!opts.dryRun) {
      // Git snapshot before any writes — allows `git checkout` restore
      const { gitCommit } = await import("./write.js");
      gitCommit(config, "brain: snapshot pré-dedup");
    }

    for (const f of fs.readdirSync(stateDir)) {
      if (!f.endsWith(".json")) continue;
      const stateFile = path.join(stateDir, f);
      let state: { id: string; elements: StoredElement[] };
      try {
        state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
      } catch { continue; }

      const before = state.elements.length;
      const { elements, merged, journal } = dedupElements(state.elements, threshold);
      if (merged === 0) continue;

      console.log(`${state.id}: ${before} → ${elements.length} (${merged} merged)`);
      for (const entry of journal) {
        allJournal.push({ ...entry, stateFile: f });
      }
      totalMerged += merged;

      if (!opts.dryRun) {
        state.elements = elements;
        fs.writeFileSync(stateFile, JSON.stringify(state, null, 2), "utf8");
      }
    }

    if (totalMerged === 0) {
      console.log("No duplicates found.");
      return;
    }

    console.log(`\nTotal merged: ${totalMerged}`);

    if (!opts.dryRun) {
      // Append to journal
      const journalPath = path.join(brainBase, ".state", "dedup-journal.json");
      const existing: typeof allJournal = fs.existsSync(journalPath)
        ? JSON.parse(fs.readFileSync(journalPath, "utf8"))
        : [];
      fs.writeFileSync(journalPath, JSON.stringify([...existing, ...allJournal], null, 2), "utf8");
      console.log(`Journal: ${journalPath} (${allJournal.length} entries)`);

      console.log("Rebuilding FTS...");
      const { rebuildFts: rebuild, writeHooksConfig: writeHooks } = await import("./fts.js");
      const result = rebuild(config);
      writeHooks(config);
      console.log(`FTS rebuilt: ${result.elements} elements`);
    } else {
      // Show up to 10 sample merges in dry-run
      console.log("\nSample merges (dry-run):");
      allJournal.slice(0, 10).forEach((e, i) => {
        console.log(`  ${i + 1}. ${e.from} → ${e.into} (sim=${e.similarity.toFixed(2)}) [${e.stateFile}]`);
      });
    }
  });

// ── reset ─────────────────────────────────────────────────────────────────────

program
  .command("reset")
  .description("Reset all done/failed sessions and repos to pending for full re-ingestion. Keeps 'ignored' sessions.")
  .option("--confirm", "Required to actually run the reset")
  .action((opts) => {
    if (!opts.confirm) {
      console.log("Ajoute --confirm pour effectuer le reset.");
      console.log("Les sessions 'ignored' (fiches de test, digestions internes) sont conservées.");
      return;
    }
    const config = loadConfig();
    assertNoRemote(config.brainPath);
    const manifest = new Manifest(config.brainPath);
    const { sessions, repos } = manifest.resetForReingestion();
    manifest.close();
    console.log(`Reset : ${sessions} session(s), ${repos} repo(s) remis en pending.`);
  });

// ── mcp ───────────────────────────────────────────────────────────────────────

program
  .command("mcp")
  .description("Start the CoucouBrain MCP server (stdio transport)")
  .action(async () => {
    const { startMcpServer } = await import("./mcp/server.js");
    await startMcpServer();
  });

// ── pause / resume ────────────────────────────────────────────────────────────

program
  .command("pause")
  .description("Suspend hook injections (useful for Twitch live / recording sessions)")
  .action(() => {
    const config = loadConfig();
    const flagPath = path.join(expandHome(config.brainPath), ".state", "paused");
    fs.mkdirSync(path.dirname(flagPath), { recursive: true });
    fs.writeFileSync(flagPath, new Date().toISOString(), "utf8");
    console.log("⏸  Brain hooks en pause. Les sessions Claude Code ne recevront plus de contexte brain.");
    console.log("   Relancer avec : brain resume");
  });

program
  .command("resume")
  .description("Re-enable hook injections after a pause")
  .action(() => {
    const config = loadConfig();
    const flagPath = path.join(expandHome(config.brainPath), ".state", "paused");
    if (fs.existsSync(flagPath)) {
      fs.unlinkSync(flagPath);
      console.log("▶️  Brain hooks réactivés.");
    } else {
      console.log("(Pas en pause — rien à faire.)");
    }
  });

// ── fts ───────────────────────────────────────────────────────────────────────

program
  .command("fts <query>")
  .description("Test FTS search directly (debug)")
  .option("--project <slug>", "Current project slug for boost")
  .option("--limit <n>", "Max results", parseInt)
  .action(async (query: string, opts: { project?: string; limit?: number }) => {
    const config = loadConfig();
    const { searchFts: sfts, buildFtsQuery } = await import("./fts.js");
    const ftsQuery = buildFtsQuery(query);
    console.log("FTS query:", ftsQuery ?? "(vide — pas assez de termes)");
    if (!ftsQuery) return;
    const results = sfts(config, query, { project: opts.project, limit: opts.limit ?? 10, threshold: -0.1 });
    if (results.length === 0) {
      console.log("Aucun résultat.");
      return;
    }
    for (const r of results) {
      const mark = r.isCorrection ? "CORRECTION" : r.kind;
      const warn = r.statut === "❌" || r.statut === "⚠️" ? ` ${r.statut}` : "";
      console.log(`  [${mark}${warn}] ${r.sourceProject.replace(/^proj_/, "")}  score=${r.score.toFixed(3)}`);
      console.log(`    ${r.texte.slice(0, 120)}`);
    }
  });

// ── doctor ────────────────────────────────────────────────────────────────────

program
  .command("doctor")
  .description("Health check: MCP server, hooks, launchd, last ingest, pause status")
  .action(async () => {
    const config = loadConfig();
    const base = expandHome(config.brainPath);
    const { spawnSync } = await import("node:child_process");

    console.log("\n🩺 CoucouBrain Doctor\n");

    // ── 1. MCP server ─────────────────────────────────────────────────────────
    // Registered via `claude mcp add --scope user` → stored in ~/.claude.json (not settings.json)
    let hasMcp = false;
    const claudeJsonPath = path.join(
      process.env.CLAUDE_CONFIG_DIR ?? path.join(process.env.HOME ?? "~", ".claude"),
      "..",
      ".claude.json"
    );
    try {
      const claudeJson = JSON.parse(fs.readFileSync(claudeJsonPath, "utf8"));
      const servers = claudeJson?.mcpServers ?? {};
      hasMcp = "coucou-brain" in servers;
      if (!hasMcp) {
        // Also try via `claude mcp list` output as fallback
        const mcpCheck = spawnSync("claude", ["mcp", "list"], { encoding: "utf8", timeout: 5000 });
        hasMcp = (mcpCheck.stdout ?? "").includes("coucou-brain");
      }
    } catch {}
    console.log(hasMcp
      ? "  [✓] MCP server : coucou-brain enregistré (~/.claude.json)"
      : "  [✗] MCP server : coucou-brain ABSENT — lancez :\n      claude mcp add --scope user coucou-brain -- brain mcp");

    // ── 2. FTS index ─────────────────────────────────────────────────────────
    const ftsPath = path.join(base, ".state", "fts.db");
    if (fs.existsSync(ftsPath)) {
      const stat = fs.statSync(ftsPath);
      const ageMin = Math.round((Date.now() - stat.mtimeMs) / 60000);
      console.log(`  [✓] Index FTS : ${ftsPath} (${ageMin} min)`);
    } else {
      console.log("  [✗] Index FTS : absent — lancez `brain rebuild` ou `brain ingest`");
    }

    // ── 3. Hooks config ───────────────────────────────────────────────────────
    const claudeDir = process.env.CLAUDE_CONFIG_DIR ?? `${process.env.HOME}/.claude`;
    const hooksConfigPath = `${claudeDir}/brain-hooks.json`;
    if (fs.existsSync(hooksConfigPath)) {
      const cfg = JSON.parse(fs.readFileSync(hooksConfigPath, "utf8")) as { updatedAt?: string };
      console.log(`  [✓] Hooks config : ${hooksConfigPath} (${cfg.updatedAt?.slice(0, 16) ?? "?"} UTC)`);
    } else {
      console.log("  [✗] Hooks config : absente — lancez `brain rebuild`");
    }

    // ── 4. Hook smoke test ────────────────────────────────────────────────────
    const hooksDir = path.join(path.dirname(new URL(import.meta.url).pathname), "..", "hooks");
    const hookScript = path.join(hooksDir, "brain-session-start.js");
    if (fs.existsSync(hookScript)) {
      const fakeInput = JSON.stringify({ session_id: "test-doctor", cwd: process.cwd() });
      const hookRun = spawnSync("node", [hookScript], {
        input: fakeInput,
        encoding: "utf8",
        timeout: 8000,
        env: { ...process.env, COUCOU_BRAIN_INTERNAL: undefined },
      });
      if (hookRun.status === 0) {
        const tokens = Math.round((hookRun.stdout ?? "").length / 4);
        console.log(`  [✓] SessionStart hook : OK (${tokens} tokens injectés)`);
      } else {
        console.log(`  [✗] SessionStart hook : ERREUR (exit ${hookRun.status})\n      ${hookRun.stderr?.slice(0, 200)}`);
      }
    } else {
      console.log(`  [✗] SessionStart hook : ${hookScript} introuvable`);
    }

    // ── 5. LaunchD ────────────────────────────────────────────────────────────
    const launchd = spawnSync("launchctl", ["list", "fr.louisraille.brain-ingest"], {
      encoding: "utf8", timeout: 5000,
    });
    if (launchd.status === 0) {
      console.log("  [✓] LaunchD : fr.louisraille.brain-ingest chargé");
    } else {
      console.log("  [✗] LaunchD : non chargé — voir brain/launchd/fr.louisraille.brain-ingest.plist");
    }

    // ── 6. Last ingest ────────────────────────────────────────────────────────
    const dbPath = path.join(base, ".state", "manifest.db");
    if (fs.existsSync(dbPath)) {
      const stat = fs.statSync(dbPath);
      const ageH = Math.round((Date.now() - stat.mtimeMs) / 3600000);
      console.log(`  [✓] Dernière ingestion : il y a ${ageH}h (${stat.mtime.toISOString().slice(0, 16)} UTC)`);
    } else {
      console.log("  [✗] manifest.db absent — aucune ingestion effectuée");
    }

    // ── 7. Pause status ───────────────────────────────────────────────────────
    const pausedFlag = path.join(base, ".state", "paused");
    if (fs.existsSync(pausedFlag)) {
      const since = fs.readFileSync(pausedFlag, "utf8").slice(0, 16);
      console.log(`  [⏸] Brain en PAUSE depuis ${since} UTC — lancez 'brain resume' pour réactiver`);
    } else {
      console.log("  [✓] Pause : désactivée (hooks actifs)");
    }

    // ── 8. Hook log ───────────────────────────────────────────────────────────
    const logPath = path.join(base, ".state", "logs", "hooks.log");
    if (fs.existsSync(logPath)) {
      const lines = fs.readFileSync(logPath, "utf8").split("\n").filter(Boolean);
      const last10 = lines.slice(-10);
      console.log(`\n  Journal hooks (dernières ${last10.length} lignes) :`);
      last10.forEach((l) => console.log(`    ${l}`));
    } else {
      console.log("\n  Journal hooks : absent (aucun hook n'a encore tourné)");
    }

    console.log();
  });

program.parse();
