#!/usr/bin/env node
/**
 * brain CLI — entry point
 *
 * brain ingest [--since YYYY-MM-DD] [--project <name>] [--limit <n>] [--dry-run] [--include-subagents]
 *             [--session <id...>] [--repo <name...>] [--repos-only] [--sessions-only]
 * brain stats
 */
import { Command } from "commander";
import fs from "node:fs";
import path from "node:path";
import { loadConfig } from "./config.js";
import { expandHome, toSlug } from "./utils.js";
import {
  discoverSessions,
  discoverRepos,
  readSession,
  collectRepo,
} from "./collect.js";
import { Manifest } from "./manifest.js";
import { digestSessionWithRetry, digestRepo } from "./digest.js";
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

const program = new Command();

program
  .name("brain")
  .description("Coucou Brain — digest Claude Code sessions and repos into a Markdown knowledge base")
  .version("0.1.0");

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
  .action(async (opts) => {
    const config = loadConfig();
    const manifest = new Manifest(config.brainPath);

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

            manifest.markSessionDone(s.id, recordId, digest.projects);
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
    const defaultGoldenPath = path.join(
      path.dirname(new URL(import.meta.url).pathname),
      "..",
      "tests",
      "golden-set.json"
    );
    const goldenPath = opts.golden
      ? path.resolve(opts.golden)
      : defaultGoldenPath;

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

program.parse();
