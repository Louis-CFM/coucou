/**
 * Session and repo collection.
 * Extracts only human text + Claude text from .jsonl files.
 * Tool results are compressed to one-line summaries.
 * Thinking blocks and file-history snapshots are discarded.
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
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
  /** true when iCloud has offloaded the git pack files (macOS only) */
  isDataless?: boolean;
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
    case "ExitPlanMode": {
      const resultText = toolResultText(resultContent).trim();
      const approvedByHook = resultText.includes("Allowed by PermissionRequest hook") ||
        resultText.includes("Allowed by hook");
      if (approvedByHook) {
        return `[plan approuvé via le notch Coucou]`;
      }
      return `[plan approuvé dans le terminal]`;
    }
    default: {
      const resultText = toolResultText(resultContent).trim();
      const approvedByHook = resultText.includes("Allowed by PermissionRequest hook") ||
        resultText.includes("Allowed by hook");
      const label = approvedByHook
        ? `[${name} approuvé via le notch Coucou]`
        : `[${name}: ${isError ? "erreur" : "OK"}]`;
      return label;
    }
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
        // Skip internal notification messages injected by Claude Code hooks/tasks
        const trimmed = content.trim();
        if (
          trimmed.includes("<task-notification>") ||
          trimmed.includes("<system-reminder>") ||
          trimmed.includes("<parameter>") ||
          /^<[a-z][-a-z]*>/.test(trimmed)
        ) continue;
        // Skip bare tool use IDs (toolu_01…) that sometimes appear as content
        if (/^toolu_[A-Za-z0-9]{10,}$/.test(trimmed)) continue;

        // Plain human text
        const { text, masked } = maskSecrets(trimmed);
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

  const condensedText = messages.map((m) => `${m.role === "human" ? "Human" : "Claude"}: ${m.text}`).join("\n\n");

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

  // ── iCloud dataless detection ──────────────────────────────────────────────
  // On macOS, iCloud Drive offloads files by removing their data blocks while
  // keeping the metadata stub. The extended flags show "dataless" or
  // "compressed,dataless". Git pack files marked dataless cannot be read.
  const packDir = path.join(repoPath, ".git", "objects", "pack");
  const isDataless = (() => {
    try {
      const flags = execSync(`ls -lO "${packDir}" 2>/dev/null || true`, {
        encoding: "utf8", timeout: 5000
      });
      return flags.includes("dataless");
    } catch {
      return false;
    }
  })();

  if (isDataless) {
    return {
      path: repoPath,
      name,
      remote: run("git remote get-url origin", repoPath) || null,
      headCommit: "icloud-offloaded",
      recentCommits: "",
      readme: "",
      claudeMd: null,
      stack: null,
      topLevel: "",
      estimatedTokens: 0,
      masked: [],
      isDataless: true,
    } as RepoCondensed & { isDataless: true };
  }

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

// ── Claude Desktop export ─────────────────────────────────────────────────────

export interface DesktopConversation {
  uuid: string;
  name: string;
  summary?: string;
  created_at: string;   // ISO timestamp
  updated_at: string;   // ISO timestamp
  chat_messages: Array<{
    uuid: string;
    text?: string;
    /** Rich content blocks (type: text | thinking | tool_use | tool_result | image | injected_prompt_block) */
    content?: Array<{ type: string; text?: string }>;
    sender: "human" | "assistant";
    created_at: string;
    updated_at: string;
    attachments?: unknown[];
    files?: unknown[];
    parent_message_uuid?: string | null;
  }>;
}

/**
 * Load conversations from a Claude.ai data export.
 * Accepts: a .zip file, a directory containing conversations.json, or the JSON file itself.
 */
export function collectClaudeExport(exportPath: string): DesktopConversation[] {
  const resolvedPath = expandHome(exportPath);

  let jsonText: string;

  if (resolvedPath.endsWith(".zip")) {
    // Extract to a temp dir (avoids ENOBUFS for large exports piped via stdout)
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-export-"));
    try {
      const result = spawnSync("unzip", ["-o", resolvedPath, "conversations.json", "-d", tmpDir], {
        encoding: "utf8",
      });
      if (result.status !== 0) {
        throw new Error(
          `Could not extract conversations.json from zip: ${(result.stderr ?? "").slice(0, 300)}`
        );
      }
      const extracted = path.join(tmpDir, "conversations.json");
      if (!fs.existsSync(extracted)) {
        throw new Error("conversations.json not found inside zip");
      }
      jsonText = fs.readFileSync(extracted, "utf8");
    } finally {
      try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
    }
  } else {
    const stat = fs.statSync(resolvedPath);
    if (stat.isDirectory()) {
      const jsonPath = path.join(resolvedPath, "conversations.json");
      if (!fs.existsSync(jsonPath)) {
        throw new Error(`conversations.json not found in ${resolvedPath}`);
      }
      jsonText = fs.readFileSync(jsonPath, "utf8");
    } else {
      jsonText = fs.readFileSync(resolvedPath, "utf8");
    }
  }

  const data = JSON.parse(jsonText);
  const conversations: DesktopConversation[] = Array.isArray(data) ? data : [data];

  // Keep only conversations with at least one message
  return conversations.filter(
    (c) => c.uuid && Array.isArray(c.chat_messages) && c.chat_messages.length > 0
  );
}

/**
 * Convert a Claude Desktop conversation into the SessionCondensed format
 * used by the digest pipeline.
 */
export function formatConversationAsSessionCondensed(
  conv: DesktopConversation
): SessionCondensed {
  const date = (conv.updated_at ?? conv.created_at ?? "").slice(0, 10) || "1970-01-01";
  const hash = createHash("sha256")
    .update(conv.uuid + "|" + (conv.updated_at ?? ""))
    .digest("hex");

  const messages: CondensedMessage[] = [];
  let allMasked: MaskedItem[] = [];

  for (const msg of conv.chat_messages) {
    // Prefer top-level text; fall back to concatenating text-type content blocks.
    // Skip thinking, tool_use, tool_result, image, injected_prompt_block.
    let text = msg.text?.trim() ?? "";
    if (!text && Array.isArray(msg.content)) {
      text = msg.content
        .filter((b) => b.type === "text" && b.text)
        .map((b) => b.text!)
        .join("\n")
        .trim();
    }
    if (!text) continue;
    const { text: maskedText, masked } = maskSecrets(text);
    messages.push({
      role: msg.sender === "human" ? "human" : "claude",
      text: maskedText,
    });
    allMasked.push(...masked);
  }

  const condensedText = messages
    .map((m) => `${m.role === "human" ? "Human" : "Claude"}: ${m.text}`)
    .join("\n\n");

  const nameHint = (conv.name ?? conv.summary ?? "").trim().slice(0, 60) || "conversation";

  return {
    id: conv.uuid,
    projectPath: "desktop",
    projectNameHint: nameHint.slice(0, 60),
    jsonlPath: `desktop://${conv.uuid}`,
    hash,
    date,
    messages,
    filesModified: [],
    estimatedTokens: estimateTokens(condensedText),
    masked: allMasked,
  };
}
