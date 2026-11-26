/**
 * Session and repo collection.
 * Extracts only human text + Claude text from .jsonl files.
 * Tool results are compressed to one-line summaries.
 * Thinking blocks and file-history snapshots are discarded.
 */
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { expandHome, sha256File, estimateTokens, projectNameFromClaudePath, decodeClaudeProjectPath } from "./utils.js";
import { maskSecrets, type MaskedItem } from "./mask.js";
import type { BrainConfig } from "./config.js";

// ── JSONL types ──────────────────────────────────────────────────────────────

interface TextBlock {
  type: "text";
  text: string;
}
interface ThinkingBlock {
  type: "thinking";
  thinking: string;
}
interface ToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}
interface ToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string | TextBlock[];
  is_error?: boolean;
}
type ContentBlock = TextBlock | ThinkingBlock | ToolUseBlock | ToolResultBlock;

interface JsonlMessage {
  type: string;
  isSidechain?: boolean;
  message?: {
    role?: string;
    content?: string | ContentBlock[];
  };
}

// ── Output types ─────────────────────────────────────────────────────────────

export interface CondensedMessage {
  role: "human" | "claude";
  text: string;
}

export interface SessionCondensed {
  id: string;
  projectPath: string;
  projectNameHint: string; // derived from path, may be overridden by LLM
  jsonlPath: string;
  hash: string;
  date: string; // YYYY-MM-DD from file mtime
  messages: CondensedMessage[];
  filesModified: string[];
  estimatedTokens: number;
  masked: MaskedItem[];
}

export interface RepoCondensed {
  path: string;
  name: string;
  remote: string | null;
  headCommit: string;
  recentCommits: string;   // last 50 commits oneline
  readme: string;          // truncated
  claudeMd: string | null; // CLAUDE.md if present
  stack: string | null;    // package.json / Package.swift summary
  topLevel: string;        // ls output
  estimatedTokens: number;
  masked: MaskedItem[];
}

// ── Tool result summarizer ───────────────────────────────────────────────────

function toolResultText(content: string | TextBlock[]): string {
  if (typeof content === "string") return content.slice(0, 200);
  return content.map((b) => b.text).join("").slice(0, 200);
}

function summarizeToolUse(name: string, input: Record<string, unknown>): string {
  const p = (k: string) => (input[k] as string | undefined) ?? "";
  switch (name) {
    case "Read":    return `[a lu ${p("file_path")}]`;
    case "Write":   return `[a créé ${p("file_path")}]`;
    case "Edit":    return `[a modifié ${p("file_path")}]`;
    case "Glob":    return `[glob: ${p("pattern")} dans ${p("path") || "."}]`;
    case "Grep":    return `[grep: "${p("pattern")}" dans ${p("path") || "."}]`;
    case "Bash": {
      const cmd = p("command").slice(0, 80);
      return `[bash: ${cmd}]`;
    }
    case "Agent":   return `[a lancé un sous-agent: ${(p("description") || "").slice(0, 60)}]`;
    default:        return `[${name}]`;
  }
}

function summarizeToolResult(
  toolUseId: string,
  resultContent: string | TextBlock[],
  isError: boolean | undefined,
  toolUseMap: Map<string, ToolUseBlock>
): string {
  const toolUse = toolUseMap.get(toolUseId);
  if (!toolUse) return isError ? "[outil: erreur]" : "[outil: résultat]";

  const name = toolUse.name;
  const input = toolUse.input;
  const p = (k: string) => (input[k] as string | undefined) ?? "";

  switch (name) {
    case "Bash": {
      const rawOutput = toolResultText(resultContent).trim();
      const status = isError ? "KO" : "OK";
      const cmd = p("command").slice(0, 60);
      const preview = rawOutput.slice(0, 100).replace(/\n/g, " ");
      return `[bash ${status}: ${cmd}${preview ? ` → ${preview}` : ""}]`;
    }
    case "Read":
      return `[a lu ${p("file_path")} — ${toolResultText(resultContent).split("\n").length} lignes]`;
    case "Write":
      return `[a créé ${p("file_path")}]`;
    case "Edit":
      return `[a modifié ${p("file_path")}]`;
    case "Glob": {
      const count = toolResultText(resultContent).split("\n").filter(Boolean).length;
      return `[glob: ${count} résultat(s) pour ${p("pattern")}]`;
    }
    case "Grep": {
      const count = toolResultText(resultContent).split("\n").filter(Boolean).length;
      return `[grep: ${count} occurrence(s) de "${p("pattern")}"]`;
    }
    default:
      return `[${name}: ${isError ? "erreur" : "OK"}]`;
  }
}

// ── File tracking ────────────────────────────────────────────────────────────

function extractFilesFromToolUses(toolUseMap: Map<string, ToolUseBlock>): string[] {
  const files = new Set<string>();
  for (const tu of toolUseMap.values()) {
    const input = tu.input;
    const filePath = (input["file_path"] as string | undefined) ?? (input["path"] as string | undefined);
    if (filePath && (tu.name === "Write" || tu.name === "Edit")) {
      files.add(filePath);
    }
  }
  return [...files];
}

// ── Session reader ───────────────────────────────────────────────────────────

export function readSession(jsonlPath: string): SessionCondensed {
  const raw = fs.readFileSync(jsonlPath, "utf8");
  const lines: JsonlMessage[] = raw
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l));

  const id = path.basename(jsonlPath, ".jsonl");
  const projectPath = path.basename(path.dirname(jsonlPath));
  const stat = fs.statSync(jsonlPath);
  const date = stat.mtime.toISOString().slice(0, 10);
  const hash = sha256File(jsonlPath);

  // Build tool_use id → block map (from assistant messages)
  const toolUseMap = new Map<string, ToolUseBlock>();
  for (const msg of lines) {
    if (msg.type === "assistant" && Array.isArray(msg.message?.content)) {
      for (const block of msg.message!.content as ContentBlock[]) {
        if (block.type === "tool_use") {
          toolUseMap.set(block.id, block);
        }
      }
    }
  }

  const messages: CondensedMessage[] = [];
  let allMasked: MaskedItem[] = [];

  for (const msg of lines) {
    if (msg.isSidechain) continue; // skip sub-agent relay messages

    if (msg.type === "user") {
      const content = msg.message?.content;
      if (!content) continue;

      if (typeof content === "string") {
        // Plain human text
        const { text, masked } = maskSecrets(content.trim());
        if (text) {
          messages.push({ role: "human", text });
          allMasked.push(...masked);
        }
      } else if (Array.isArray(content)) {
        // Check if this is a tool_result message or human text
        const isAllToolResults = content.every(
          (b) => (b as ContentBlock).type === "tool_result"
        );

        if (isAllToolResults) {
          // Summarize each tool result
          const summaries: string[] = [];
          for (const block of content as ToolResultBlock[]) {
            const summary = summarizeToolResult(
              block.tool_use_id,
              block.content,
              block.is_error,
              toolUseMap
            );
            summaries.push(summary);
          }
          if (summaries.length > 0) {
            messages.push({ role: "human", text: summaries.join("\n") });
          }
        } else {
          // Mixed or pure text blocks — keep text, skip images/etc
          const textParts: string[] = [];
          for (const block of content as ContentBlock[]) {
            if (block.type === "text") {
              textParts.push(block.text);
            } else if (block.type === "tool_result") {
              const summary = summarizeToolResult(
                block.tool_use_id,
                block.content,
                block.is_error,
                toolUseMap
              );
              textParts.push(summary);
            }
          }
          const combined = textParts.join("\n").trim();
          if (combined) {
            const { text, masked } = maskSecrets(combined);
            messages.push({ role: "human", text });
            allMasked.push(...masked);
          }
        }
      }
    } else if (msg.type === "assistant") {
      const content = msg.message?.content;
      if (!content || !Array.isArray(content)) continue;

      // Keep only text blocks, skip thinking and tool_use
      const textParts: string[] = [];
      for (const block of content as ContentBlock[]) {
        if (block.type === "text") {
          textParts.push(block.text);
        } else if (block.type === "tool_use") {
          // Add a one-liner so the reader knows what Claude did
          textParts.push(summarizeToolUse(block.name, block.input));
        }
        // Discard: thinking blocks
      }
      const combined = textParts.join("\n").trim();
      if (combined) {
        const { text, masked } = maskSecrets(combined);
        messages.push({ role: "claude", text });
        allMasked.push(...masked);
      }
    }
    // All other types (file-history-snapshot, permission-mode, cost-state, etc.) → skip
  }

  const condensedText = messages.map((m) => `${m.role === "human" ? "Louis" : "Claude"}: ${m.text}`).join("\n\n");

  return {
    id,
    projectPath,
    projectNameHint: projectNameFromClaudePath(projectPath),
    jsonlPath,
    hash,
    date,
    messages,
    filesModified: extractFilesFromToolUses(toolUseMap),
    estimatedTokens: estimateTokens(condensedText),
    masked: allMasked,
  };
}

// ── Internal session detection ────────────────────────────────────────────────

/** Returns true if the JSONL session was launched by brain itself (should be excluded). */
function isInternalSession(jsonlPath: string): boolean {
  try {
    // Only need to check the first few KB — the marker is in the first user message
    const buf = Buffer.alloc(4096);
    const fd = fs.openSync(jsonlPath, "r");
    const bytesRead = fs.readSync(fd, buf, 0, 4096, 0);
    fs.closeSync(fd);
    return buf.slice(0, bytesRead).toString("utf8").includes("coucou-brain-internal");
  } catch {
    return false;
  }
}

// ── Session discovery ─────────────────────────────────────────────────────────

export interface DiscoveredSession {
  id: string;
  projectPath: string;
  jsonlPath: string;
  hash: string;
  date: string;
  sizeBytes: number;
  /** true if the session was modified recently and should be skipped */
  isActive?: boolean;
}

export function discoverSessions(
  config: BrainConfig,
  opts: { includeSubagents?: boolean; sinceDate?: string; projectFilter?: string }
): DiscoveredSession[] {
  const projectsPath = expandHome(config.claudeProjectsPath);
  const brainStatePath = expandHome(config.brainPath) + "/.state";

  const sessions: DiscoveredSession[] = [];

  for (const proj of fs.readdirSync(projectsPath)) {
    const projDir = path.join(projectsPath, proj);
    if (!fs.statSync(projDir).isDirectory()) continue;

    // Skip explicitly excluded project dirs
    if (config.excludeProjectDirs?.includes(proj)) continue;
    // Skip any project whose decoded filesystem path is inside ~/CoucouBrain/
    // (covers .state/digestion/ and any brain sub-directory).
    // The encoded name encodes '/' as '-', so we check by trying to decode.
    const decodedPath = decodeClaudeProjectPath(proj);
    const brainRootPath = expandHome(config.brainPath);
    if (decodedPath && decodedPath.startsWith(brainRootPath)) continue;

    // Filter by project name if specified
    if (opts.projectFilter) {
      const name = projectNameFromClaudePath(proj).toLowerCase();
      if (!name.includes(opts.projectFilter.toLowerCase())) continue;
    }

    const scanDir = (dir: string, isSubagent: boolean) => {
      let entries: fs.Dirent[];
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const entry of entries) {
        if (entry.isDirectory() && entry.name === "subagents") {
          if (opts.includeSubagents) {
            scanDir(path.join(dir, "subagents"), true);
          }
          continue;
        }
        if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
        // Skip vercel-plugin files
        if (entry.name === "skill-injections.jsonl") continue;

        const jsonlPath = path.join(dir, entry.name);
        const stat = fs.statSync(jsonlPath);
        const date = stat.mtime.toISOString().slice(0, 10);

        if (opts.sinceDate && date < opts.sinceDate) continue;

        // Skip active sessions (recently modified = likely still open)
        const activeMinutes = config.activeSessionMinutes ?? 30;
        const ageMinutes = (Date.now() - stat.mtimeMs) / (1000 * 60);
        if (ageMinutes < activeMinutes) {
          // Will be logged by the caller
          sessions.push({ id: path.basename(entry.name, ".jsonl"), projectPath: proj, jsonlPath, hash: "", date, sizeBytes: stat.size, isActive: true });
          continue;
        }

        const id = path.basename(entry.name, ".jsonl");
        if (isInternalSession(jsonlPath)) continue;
        sessions.push({
          id,
          projectPath: proj,
          jsonlPath,
          hash: sha256File(jsonlPath),
          date,
          sizeBytes: stat.size,
        });
      }
    };

    // Scan top-level + optionally subagents
    for (const entry of fs.readdirSync(projDir, { withFileTypes: true })) {
      if (entry.isDirectory() && entry.name === "subagents") {
        if (opts.includeSubagents) {
          scanDir(path.join(projDir, "subagents"), true);
        }
        continue;
      }
      if (entry.isDirectory()) continue; // skip other subdirs (vercel-plugin, etc.)
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      if (entry.name === "skill-injections.jsonl") continue;

      const jsonlPath = path.join(projDir, entry.name);
      const stat = fs.statSync(jsonlPath);
      const date = stat.mtime.toISOString().slice(0, 10);
      if (opts.sinceDate && date < opts.sinceDate) continue;

      const activeMinutes = config.activeSessionMinutes ?? 30;
      const ageMinutes = (Date.now() - stat.mtimeMs) / (1000 * 60);
      const id = path.basename(entry.name, ".jsonl");

      if (ageMinutes < activeMinutes) {
        sessions.push({ id, projectPath: proj, jsonlPath, hash: "", date, sizeBytes: stat.size, isActive: true });
        continue;
      }

      if (isInternalSession(jsonlPath)) continue;
      sessions.push({
        id,
        projectPath: proj,
        jsonlPath,
        hash: sha256File(jsonlPath),
        date,
        sizeBytes: stat.size,
      });
    }
  }

  // Sort chronologically (oldest first) for correct merge order
  sessions.sort((a, b) => a.date.localeCompare(b.date));
  return sessions;
}

// ── Repo collection ───────────────────────────────────────────────────────────

export function collectRepo(repoPath: string, aliases: Record<string, string>): RepoCondensed | null {
  if (!fs.existsSync(path.join(repoPath, ".git"))) return null;

  const run = (cmd: string, cwd: string): string => {
    try {
      return execSync(cmd, { cwd, encoding: "utf8", timeout: 10000, stdio: ["pipe", "pipe", "pipe"] }).trim();
    } catch {
      return "";
    }
  };

  const rawName = path.basename(repoPath);
  const name = aliases[rawName] ?? rawName;
  const headCommit = run("git rev-parse HEAD", repoPath) || "unknown";
  const remote = run("git remote get-url origin", repoPath) || null;
  const recentCommits = run("git log --oneline -50", repoPath);
  const topLevel = run("ls -1", repoPath);

  // README (truncated to 3000 chars)
  const readmePath = ["README.md", "README", "readme.md"].map((n) => path.join(repoPath, n)).find(fs.existsSync);
  const readme = readmePath ? fs.readFileSync(readmePath, "utf8").slice(0, 3000) : "";

  // CLAUDE.md
  const claudeMdPath = path.join(repoPath, "CLAUDE.md");
  const claudeMd = fs.existsSync(claudeMdPath) ? fs.readFileSync(claudeMdPath, "utf8").slice(0, 2000) : null;

  // Stack: package.json or Package.swift summary
  let stack: string | null = null;
  const pkgPath = path.join(repoPath, "package.json");
  const swiftPath = path.join(repoPath, "Package.swift");
  if (fs.existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
      const deps = Object.keys(pkg.dependencies ?? {}).slice(0, 20);
      const devDeps = Object.keys(pkg.devDependencies ?? {}).slice(0, 10);
      stack = `package.json — name: ${pkg.name}, version: ${pkg.version}\ndeps: ${deps.join(", ")}\ndevDeps: ${devDeps.join(", ")}`;
    } catch {}
  } else if (fs.existsSync(swiftPath)) {
    stack = fs.readFileSync(swiftPath, "utf8").slice(0, 1000);
  }

  const allText = [readme, claudeMd ?? "", stack ?? "", recentCommits, topLevel].join("\n");
  const { text: maskedText, masked } = maskSecrets(allText);

  return {
    path: repoPath,
    name,
    remote,
    headCommit,
    recentCommits,
    readme: maskedText.slice(0, readme.length) || readme, // keep structure
    claudeMd,
    stack,
    topLevel,
    estimatedTokens: estimateTokens(maskedText),
    masked,
  };
}

/** Discover all git repos in the configured paths */
export function discoverRepos(config: BrainConfig): string[] {
  const paths = [
    ...config.repoPaths.map(expandHome),
    ...(config.additionalRepoPaths ?? []).map(expandHome),
  ];

  const found = new Set<string>();
  const remotes = new Map<string, string>(); // remote → first path seen

  const scan = (dir: string, depth: number) => {
    if (depth > (config.repoScanMaxDepth ?? 2)) return;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const full = path.join(dir, entry.name);
      if (entry.name === ".git") {
        const repoPath = dir;
        const run = (cmd: string): string => {
          try { return execSync(cmd, { cwd: repoPath, encoding: "utf8", stdio: ["pipe","pipe","pipe"] }).trim(); }
          catch { return ""; }
        };
        const remote = run("git remote get-url origin");
        const head = run("git rev-parse HEAD");
        // Deduplicate by remote URL (same repo in two locations)
        if (remote && remotes.has(remote)) {
          // Keep the ~/Developer version over Documents/Projets
          const existing = remotes.get(remote)!;
          if (!repoPath.includes("/Developer/") && existing.includes("/Developer/")) {
            return; // skip this duplicate
          }
          found.delete(existing);
          remotes.set(remote, repoPath);
        } else if (remote) {
          remotes.set(remote, repoPath);
        }
        found.add(repoPath);
        return; // don't recurse into a git repo
      }
      scan(full, depth + 1);
    }
  };

  for (const p of paths) {
    if (fs.existsSync(p)) scan(p, 0);
  }

  return [...found].sort();
}
