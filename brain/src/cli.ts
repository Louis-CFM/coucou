#!/usr/bin/env node
/**
 * brain CLI — entry point
 *
 * brain ingest [--since YYYY-MM-DD] [--project <name>] [--limit <n>] [--dry-run] [--include-subagents]
 * brain stats
 */
import { Command } from "commander";
import fs from "node:fs";
import { loadConfig } from "./config.js";
import { toSlug } from "./utils.js";
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
  mergeRecordIntoProject,
  writeProjectFromRepo,
  appendToLessons,
  rebuildIndex,
  gitCommit,
} from "./write.js";
import { computeStats } from "./stats.js";

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

    // ── Sessions ──────────────────────────────────────────────────────────────
    if (!opts.reposOnly) {
      const discovered = discoverSessions(config, {
        includeSubagents: opts.includeSubagents,
        sinceDate: opts.since,
        projectFilter: opts.project,
      });

      for (const s of discovered) {
        manifest.upsertSession({
          id: s.id,
          project_path: s.projectPath,
          jsonl_path: s.jsonlPath,
          hash: s.hash,
        });
      }

      const discoveredIds = new Set(discovered.map((d) => d.id));
      const pending = manifest
        .getPendingSessions()
        .filter((s) => discoveredIds.has(s.id));

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
            console.log(`  ${s.id.slice(0, 8)}  [erreur: ${(e as Error).message.slice(0, 60)}]`);
          }
        }
        console.log(`\n  Total estimé : ~${totalTokens.toLocaleString()} tokens condensés`);
      } else {
        const maskedByType: Record<string, number> = {};
        let doneCount = 0;
        let failCount = 0;

        for (const s of toProcess) {
          const idx = doneCount + failCount + 1;
          console.log(`\n  [${idx}/${toProcess.length}] ${s.project_path.slice(-50)} / ${s.id.slice(0, 8)}…`);

          try {
            const condensed = readSession(s.jsonl_path);
            console.log(`    ~${condensed.estimatedTokens.toLocaleString()} tokens condensés`);

            for (const m of condensed.masked) {
              maskedByType[m.type] = (maskedByType[m.type] ?? 0) + m.count;
            }

            const digest = await digestSessionWithRetry(condensed, config);
            const recordId = writeRecord(condensed, digest, config);

            const primaryProject = digest.projects[0]!;
            const recordContent = fs.readFileSync(
              recordFilePath(config, condensed.id, condensed.date, primaryProject),
              "utf8"
            );

            for (const proj of digest.projects) {
              const slug = toSlug(proj);
              console.log(`    → merge dans projects/${slug}.md`);
              mergeRecordIntoProject(slug, recordId, recordContent, digest, config);
            }

            appendToLessons(digest.errors_and_lessons, digest.projects.map(toSlug), config);
            manifest.markSessionDone(s.id, recordId, digest.projects);
            doneCount++;
            console.log(`    ✓ ${recordId}`);
          } catch (e) {
            console.error(`    ✗ Échec: ${(e as Error).message.slice(0, 200)}`);
            manifest.markSessionFailed(s.id);
            failCount++;
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
      const pendingRepos = manifest.getPendingRepos().filter((r) => repoSet.has(r.path));

      if (opts.dryRun) {
        console.log("\n--- DRY RUN : repos ---");
        for (const r of pendingRepos) console.log(`  ${r.path}`);
      } else {
        let repoDone = 0;
        for (const r of pendingRepos) {
          console.log(`\n  Repo: ${r.path}`);
          try {
            const condensed = collectRepo(r.path, config.repoAliases);
            if (!condensed) { console.log("    pas un repo git, skip"); continue; }
            const repoDigest = await digestRepo(condensed, config);
            const pageId = writeProjectFromRepo(condensed, repoDigest, config);
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
      rebuildIndex(config);
      const doneCount = manifest.getAllSessions().filter((s) => s.status === "done").length;
      gitCommit(config, `brain: ingestion — ${doneCount} fiches`);
    }

    manifest.close();
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

program.parse();
