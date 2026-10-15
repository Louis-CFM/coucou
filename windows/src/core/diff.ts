// Live diff — port of DiffEngine.swift (NotchBuddy/Sources/CoucouKit).
//
// Line diff (LCS) with 3-line context hunks, used for the Edit / MultiEdit /
// Write tool calls the hooks see. Same size guards as macOS: beyond 200 KB or
// 4 000 lines, or when the LCS table would pass a million cells, only the
// +N −M counts are kept and the diff is marked `tooLarge`.
//
// Also home to `toOneLine` (Claude's final message → one line of plain text)
// and the diff step encoding the ticker reads.

export type DiffKind = "context" | "added" | "removed";

export interface DiffLine {
  kind: DiffKind;
  text: string;
  /** 1-based; -1 for pure adds. */
  origLine: number;
  /** 1-based; -1 for pure removes. */
  newLine: number;
}

export interface DiffHunk {
  origStart: number;
  newStart: number;
  lines: DiffLine[];
}

export interface FileDiff {
  /** Stable identifier assigned by State.appendSessionDiff. */
  id: number;
  path: string;
  added: number;
  removed: number;
  hunks: DiffHunk[];
  tooLarge: boolean;
  /** True when produced by fromNew (Write tool). */
  isNewFile: boolean;
}

/** FileDiff.maxBytes / maxLines on macOS. */
export const DIFF_MAX_BYTES = 200 * 1024;
export const DIFF_MAX_LINES = 4000;
/** LCS is O(m·n): bail out before the quadratic blowup. */
const DIFF_MAX_CELLS = 1_000_000;
const CONTEXT = 3;

const encoder = new TextEncoder();
const utf8Length = (s: string) => encoder.encode(s).length;

/** Last path component, Windows or POSIX separators. */
export function fileName(path: string): string {
  const cleaned = path.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

// ── Public API ────────────────────────────────────────────────────────────────

export function fromEdit(oldText: string, newText: string, path: string): FileDiff {
  if (utf8Length(oldText) + utf8Length(newText) > DIFF_MAX_BYTES) {
    return countFallback(oldText, newText, path);
  }
  const oldLines = splitLines(oldText);
  const newLines = splitLines(newText);
  if (oldLines.length + newLines.length > DIFF_MAX_LINES) {
    return countFallback(oldText, newText, path);
  }
  if (oldLines.length * newLines.length > DIFF_MAX_CELLS) {
    return countFallback(oldText, newText, path);
  }
  const flat = buildDiffLines(oldLines, newLines);
  let added = 0;
  let removed = 0;
  for (const l of flat) {
    if (l.kind === "added") added++;
    else if (l.kind === "removed") removed++;
  }
  return {
    id: 0, path, added, removed, hunks: buildHunks(flat, CONTEXT), tooLarge: false, isNewFile: false,
  };
}

export function fromNew(content: string, path: string): FileDiff {
  if (utf8Length(content) > DIFF_MAX_BYTES) {
    const lineCount = content.split("\n").length;
    return { id: 0, path, added: lineCount, removed: 0, hunks: [], tooLarge: true, isNewFile: true };
  }
  const lines = splitLines(content);
  if (lines.length > DIFF_MAX_LINES) {
    return { id: 0, path, added: lines.length, removed: 0, hunks: [], tooLarge: true, isNewFile: true };
  }
  const diffLines: DiffLine[] = lines.map((text, i) => ({
    kind: "added", text, origLine: -1, newLine: i + 1,
  }));
  return {
    id: 0,
    path,
    added: diffLines.length,
    removed: 0,
    hunks: diffLines.length ? [{ origStart: 0, newStart: 1, lines: diffLines }] : [],
    tooLarge: false,
    isNewFile: true,
  };
}

/**
 * Build a file diff from tool arguments when they carry the replaced and new
 * text, or null when the call changes nothing or is not a supported edit.
 */
export function buildFileDiff(tool: string, input: Record<string, unknown>, cwd = ""): FileDiff | null {
  const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
  const path = resolvePath(str(input.file_path), cwd);
  switch (tool) {
    case "Edit": {
      const oldText = str(input.old_string);
      const newText = str(input.new_string);
      if (oldText == null || newText == null || path == null) return null;
      if (!oldText && !newText) return null;
      const d = fromEdit(oldText, newText, path);
      return d.added > 0 || d.removed > 0 ? d : null;
    }
    case "MultiEdit": {
      const edits = input.edits;
      if (path == null || !Array.isArray(edits) || edits.length === 0) return null;
      let added = 0;
      let removed = 0;
      let tooLarge = false;
      const hunks: DiffHunk[] = [];
      for (const edit of edits) {
        if (!edit || typeof edit !== "object") continue;
        const e = edit as Record<string, unknown>;
        const oldText = str(e.old_string);
        const newText = str(e.new_string);
        if (oldText == null || newText == null) continue;
        const d = fromEdit(oldText, newText, path);
        added += d.added;
        removed += d.removed;
        hunks.push(...d.hunks);
        if (d.tooLarge) tooLarge = true;
      }
      if (added === 0 && removed === 0) return null;
      return { id: 0, path, added, removed, hunks, tooLarge, isNewFile: false };
    }
    case "Write": {
      const content = str(input.content);
      if (path == null || !content) return null;
      const d = fromNew(content, path);
      return d.added > 0 || d.removed > 0 ? d : null;
    }
    case "write_to_file": {
      const target = resolvePath(str(input.TargetFile) ?? str(input.targetFile), cwd);
      const content = str(input.CodeContent) ?? str(input.codeContent);
      if (target == null || content == null || content.length === 0) return null;
      const d = fromNew(content, target);
      return d.added > 0 || d.removed > 0 ? d : null;
    }
    case "replace_file_content": {
      const target = resolvePath(str(input.TargetFile) ?? str(input.targetFile), cwd);
      const oldText = str(input.TargetContent) ?? str(input.targetContent);
      const newText = str(input.ReplacementContent) ?? str(input.replacementContent);
      if (target == null || oldText == null || newText == null || (!oldText && !newText)) return null;
      const d = fromEdit(oldText, newText, target);
      return d.added > 0 || d.removed > 0 ? d : null;
    }
    case "multi_replace_file_content": {
      const target = resolvePath(str(input.TargetFile) ?? str(input.targetFile), cwd);
      const chunks = input.ReplacementChunks ?? input.replacementChunks;
      if (target == null || !Array.isArray(chunks) || chunks.length === 0) return null;
      let added = 0;
      let removed = 0;
      let tooLarge = false;
      const hunks: DiffHunk[] = [];
      for (const chunk of chunks) {
        if (!chunk || typeof chunk !== "object") continue;
        const c = chunk as Record<string, unknown>;
        const oldText = str(c.TargetContent) ?? str(c.targetContent) ?? str(c.old_string);
        const newText = str(c.ReplacementContent) ?? str(c.replacementContent) ?? str(c.new_string);
        if (oldText == null || newText == null) continue;
        const d = fromEdit(oldText, newText, target);
        added += d.added;
        removed += d.removed;
        hunks.push(...d.hunks);
        tooLarge ||= d.tooLarge;
      }
      if (added === 0 && removed === 0) return null;
      return { id: 0, path: target, added, removed, hunks, tooLarge, isNewFile: false };
    }
    default:
      return null;
  }
}

/** One hook can carry an apply_patch call that changes several files. */
export function buildFileDiffs(tool: string, input: Record<string, unknown>, cwd = ""): FileDiff[] {
  if (tool === "apply_patch") {
    const patch = typeof input.command === "string" ? input.command : "";
    return patch ? parseCodexPatch(patch, cwd) : [];
  }
  const diff = buildFileDiff(tool, input, cwd);
  return diff ? [diff] : [];
}

function resolvePath(path: string | null, cwd: string): string | null {
  if (!path) return null;
  if (/^(?:[A-Za-z]:[\\/]|[\\/]{2}|\/)/.test(path) || !cwd) return path;
  const separator = cwd.includes("\\") ? "\\" : "/";
  let relative = path;
  while (relative.startsWith("./") || relative.startsWith(".\\")) relative = relative.slice(2);
  return `${cwd.replace(/[\\/]+$/, "")}${separator}${relative.replace(/[\\/]+/g, separator)}`;
}

/** Decode Codex's apply_patch body without executing or applying it. */
function parseCodexPatch(patch: string, cwd: string): FileDiff[] {
  type PatchFile = { path: string; kind: "update" | "add" | "delete"; hunks: DiffHunk[]; added: number; removed: number; tooLarge: boolean };
  const files: PatchFile[] = [];
  const state: { file: PatchFile | null } = { file: null };
  let hunkLines: DiffLine[] = [];
  let oldLine = 1;
  let newLine = 1;
  let fileBytes = 0;
  let fileLines = 0;

  const flushHunk = () => {
    if (!state.file || hunkLines.length === 0) return;
    state.file.hunks.push({
      origStart: hunkLines.find((line) => line.origLine > 0)?.origLine ?? oldLine,
      newStart: hunkLines.find((line) => line.newLine > 0)?.newLine ?? newLine,
      lines: hunkLines,
    });
    hunkLines = [];
  };
  const flushFile = () => {
    flushHunk();
    if (state.file) files.push(state.file);
    state.file = null;
  };
  const beginFile = (path: string, kind: PatchFile["kind"]) => {
    flushFile();
    state.file = { path, kind, hunks: [], added: 0, removed: 0, tooLarge: false };
    oldLine = 1;
    newLine = 1;
    fileBytes = 0;
    fileLines = 0;
  };

  const encoder = new TextEncoder();
  for (const line of patch.replace(/\r\n/g, "\n").split("\n")) {
    const update = line.match(/^\*\*\* Update File: (.+)$/);
    const add = line.match(/^\*\*\* Add File: (.+)$/);
    const del = line.match(/^\*\*\* Delete File: (.+)$/);
    const move = line.match(/^\*\*\* Move to: (.+)$/);
    if (update || add || del) {
      beginFile((update ?? add ?? del)![1].trim(), update ? "update" : add ? "add" : "delete");
      continue;
    }
    if (move && state.file) {
      state.file.path = move[1].trim();
      continue;
    }
    if (!state.file || line === "*** Begin Patch" || line === "*** End Patch" || line === "*** End of File") continue;
    if (line.startsWith("@@")) {
      flushHunk();
      const header = line.match(/^@@\s+-(\d+)(?:,\d+)?\s+\+(\d+)(?:,\d+)?\s+@@/);
      if (header) {
        oldLine = Number(header[1]);
        newLine = Number(header[2]);
      }
      continue;
    }

    const marker = line[0];
    if (marker !== " " && marker !== "+" && marker !== "-") continue;
    fileBytes += encoder.encode(line).length + 1;
    fileLines++;
    if (marker === " ") {
      hunkLines.push({ kind: "context", text: line.slice(1), origLine: oldLine++, newLine: newLine++ });
    } else if (marker === "+") {
      state.file.added++;
      hunkLines.push({ kind: "added", text: line.slice(1), origLine: -1, newLine: newLine++ });
    } else {
      state.file.removed++;
      hunkLines.push({ kind: "removed", text: line.slice(1), origLine: oldLine++, newLine: -1 });
    }
    if (fileBytes > DIFF_MAX_BYTES || fileLines > DIFF_MAX_LINES) state.file.tooLarge = true;
  }
  flushFile();

  return files.flatMap((item) => {
    if (item.kind === "delete" || (item.added === 0 && item.removed === 0)) return [];
    const path = resolvePath(item.path, cwd);
    if (!path) return [];
    return [{
      id: 0,
      path,
      added: item.added,
      removed: item.removed,
      hunks: item.tooLarge ? [] : item.hunks,
      tooLarge: item.tooLarge,
      isNewFile: item.kind === "add",
    }];
  });
}

// ── Line splitting ────────────────────────────────────────────────────────────

function splitLines(text: string): string[] {
  const parts = text.replace(/\r\n/g, "\n").split("\n");
  // A trailing newline leaves one empty element behind.
  if (parts[parts.length - 1] === "") parts.pop();
  return parts;
}

// ── LCS diff ──────────────────────────────────────────────────────────────────

function buildDiffLines(oldLines: string[], newLines: string[]): DiffLine[] {
  const m = oldLines.length;
  const n = newLines.length;
  const w = n + 1;
  // dp[i*w + j] = LCS length of oldLines[0..<i] and newLines[0..<j]. Lengths stay
  // under DIFF_MAX_LINES, so 16 bits are plenty and the table is half the size.
  const dp = new Uint16Array((m + 1) * w);
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      dp[i * w + j] = oldLines[i - 1] === newLines[j - 1]
        ? dp[(i - 1) * w + j - 1] + 1
        : Math.max(dp[(i - 1) * w + j], dp[i * w + j - 1]);
    }
  }

  // Backtrack to the matching pairs.
  const matches: [number, number][] = [];
  let i = m;
  let j = n;
  while (i > 0 && j > 0) {
    if (oldLines[i - 1] === newLines[j - 1]) {
      matches.push([i - 1, j - 1]);
      i--;
      j--;
    } else if (dp[(i - 1) * w + j] >= dp[i * w + j - 1]) {
      i--;
    } else {
      j--;
    }
  }
  matches.reverse();

  const result: DiffLine[] = [];
  let prevOld = -1;
  let prevNew = -1;
  const removedLine = (k: number): DiffLine => ({ kind: "removed", text: oldLines[k], origLine: k + 1, newLine: -1 });
  const addedLine = (k: number): DiffLine => ({ kind: "added", text: newLines[k], origLine: -1, newLine: k + 1 });
  for (const [oi, ni] of matches) {
    for (let k = prevOld + 1; k < oi; k++) result.push(removedLine(k));
    for (let k = prevNew + 1; k < ni; k++) result.push(addedLine(k));
    result.push({ kind: "context", text: oldLines[oi], origLine: oi + 1, newLine: ni + 1 });
    prevOld = oi;
    prevNew = ni;
  }
  for (let k = prevOld + 1; k < m; k++) result.push(removedLine(k));
  for (let k = prevNew + 1; k < n; k++) result.push(addedLine(k));
  return result;
}

// ── Hunks ─────────────────────────────────────────────────────────────────────

function buildHunks(lines: DiffLine[], context: number): DiffHunk[] {
  const merged: [number, number][] = [];
  lines.forEach((line, i) => {
    if (line.kind === "context") return;
    const start = Math.max(0, i - context);
    const end = Math.min(lines.length - 1, i + context);
    const last = merged[merged.length - 1];
    if (last && start <= last[1] + 1) last[1] = Math.max(last[1], end);
    else merged.push([start, end]);
  });
  return merged.map(([start, end]) => {
    const hunkLines = lines.slice(start, end + 1);
    return {
      origStart: hunkLines.find((l) => l.origLine > 0)?.origLine ?? 1,
      newStart: hunkLines.find((l) => l.newLine > 0)?.newLine ?? 1,
      lines: hunkLines,
    };
  });
}

// ── Count fallback (too large) ────────────────────────────────────────────────

function countFallback(oldText: string, newText: string, path: string): FileDiff {
  const oldLines = oldText.split("\n");
  const newLines = newText.split("\n");
  const oldSet = new Set(oldLines);
  const newSet = new Set(newLines);
  const added = newLines.filter((l) => l !== "" && !oldSet.has(l)).length;
  const removed = oldLines.filter((l) => l !== "" && !newSet.has(l)).length;
  return { id: 0, path, added, removed, hunks: [], tooLarge: true, isNewFile: false };
}

// ── toOneLine ─────────────────────────────────────────────────────────────────

/**
 * A possibly multi-line Markdown message as one line of plain text: only the
 * first non-empty paragraph (a blank line, a horizontal rule or a table row ends
 * it), without `**`, `__`, backticks, leading `#` or list markers.
 */
export function toOneLine(text: string, maxChars = 200): string {
  const trimWS = (s: string) => s.replace(/^[ \t]+|[ \t]+$/g, "");
  const paragraphs: string[][] = [];
  let current: string[] = [];
  for (const line of text.replace(/\r\n/g, "\n").split("\n")) {
    const t = trimWS(line);
    const isHR = t.length >= 3 && (/^-+$/.test(t) || /^\*+$/.test(t) || /^_+$/.test(t));
    if (t === "" || isHR || t.startsWith("|")) {
      if (current.length) paragraphs.push(current);
      current = [];
    } else {
      current.push(line);
    }
  }
  if (current.length) paragraphs.push(current);

  for (const para of paragraphs) {
    const s = para.join("\n").replaceAll("**", "").replaceAll("__", "").replaceAll("`", "");
    const processed: string[] = [];
    for (const line of s.split("\n")) {
      let l = trimWS(line.replace(/^#+/, ""));
      if (l.startsWith("- ") || l.startsWith("* ") || l.startsWith("• ")) l = l.slice(2);
      else l = l.replace(/^\d+\.\s+/, "");
      l = trimWS(l);
      if (l) processed.push(l);
    }
    const collapsed = processed.join(" ").split(/\s+/).filter(Boolean).join(" ");
    if (collapsed) return Array.from(collapsed).slice(0, maxChars).join("");
  }
  return "";
}

// ── Diff steps ────────────────────────────────────────────────────────────────
// A diff shows up in the ticker as a step string the user never sees raw:
// `"<filename>\t<added>:<removed>:<diffId>"` — same format as macOS.

export const DIFF_STEP_MARKER = "";

export interface DiffStep {
  filename: string;
  added: number;
  removed: number;
  diffId: number;
}

export function isDiffStep(step: string): boolean {
  return step.startsWith(DIFF_STEP_MARKER);
}

export function makeDiffStep(filename: string, added: number, removed: number, diffId: number): string {
  return `${DIFF_STEP_MARKER}${filename}\t${added}:${removed}:${diffId}`;
}

export function parseDiffStep(step: string): DiffStep | null {
  if (!isDiffStep(step)) return null;
  const body = step.slice(DIFF_STEP_MARKER.length);
  const tab = body.indexOf("\t");
  if (tab < 0) return null;
  const parts = body.slice(tab + 1).split(":");
  if (parts.length !== 3 || !parts.every((p) => /^-?\d+$/.test(p))) return null;
  const [added, removed, diffId] = parts.map(Number);
  return { filename: body.slice(0, tab), added, removed, diffId };
}

/** The last step that is text, never a diff marker. */
export function lastTextStep(steps: readonly string[]): string | undefined {
  for (let i = steps.length - 1; i >= 0; i--) {
    if (!isDiffStep(steps[i])) return steps[i];
  }
  return undefined;
}
