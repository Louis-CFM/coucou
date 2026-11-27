import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expandHome } from "./utils.js";

export interface BrainConfig {
  brainPath: string;
  claudeProjectsPath: string;
  repoPaths: string[];
  additionalRepoPaths?: string[];
  excludeProjectDirs?: string[];
  repoScanMaxDepth?: number;
  chunkModel: string;
  mergeModel: string;
  maxChunkTokens: number;
  language: string;
  repoAliases: Record<string, string>;
  /** Sessions modified less than this many minutes ago are skipped (active session guard) */
  activeSessionMinutes?: number;
}

/** Load config: base config.json merged with optional local overrides */
export function loadConfig(): BrainConfig {
  const dir = path.dirname(fileURLToPath(import.meta.url));
  const basePath = path.join(dir, "..", "brain.config.json");
  const localPath = path.join(dir, "..", "brain.config.local.json");

  if (!fs.existsSync(basePath)) {
    throw new Error(`Config not found: ${basePath}`);
  }

  const base: BrainConfig = JSON.parse(fs.readFileSync(basePath, "utf8"));

  if (fs.existsSync(localPath)) {
    const local: Partial<BrainConfig> = JSON.parse(fs.readFileSync(localPath, "utf8"));
    return { ...base, ...local };
  }

  return base;
}

/** Resolve the brain's state/digestion directory (excluded from ingestion) */
export function digestionDir(config: BrainConfig): string {
  return path.join(expandHome(config.brainPath), ".state", "digestion");
}
