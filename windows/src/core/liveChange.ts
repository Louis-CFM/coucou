// A Cursor file edit, small enough to draw in the overview and open as a diff.
// Strings arrive already capped by the hook relay (2 000 characters).

export interface DiffLine {
  kind: "add" | "del" | "ctx";
  text: string;
}

export interface LiveChange {
  path: string;
  /** Up to three lines of the new text, for the overview card. */
  preview: string[];
  diff: DiffLine[];
  command: string | null;
  output: string | null;
  ok: boolean | null;
}

export interface Hunk {
  old_string?: string;
  new_string?: string;
}

const PREVIEW_LINES = 3;
const DIFF_CAP = 80;

export function hasFilePreview(change: LiveChange | null): boolean {
  return !!change && change.path.length > 0 && change.preview.length > 0;
}

export function fileName(path: string): string {
  const cleaned = path.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("\\"), cleaned.lastIndexOf("/"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned || "file";
}

export function fromHunks(path: string, hunks: Hunk[], prev: LiveChange | null): LiveChange | null {
  const diff: DiffLine[] = [];
  let lastOld = "";
  let lastNew = "";
  for (const hunk of hunks) {
    const oldText = hunk.old_string ?? "";
    const newText = hunk.new_string ?? "";
    if (!oldText && !newText) continue;
    lastOld = oldText;
    lastNew = newText;
    diff.push(...lineDiff(oldText, newText));
  }
  if (diff.length === 0) return prev;
  return {
    path: path || prev?.path || "",
    preview: previewLines(lastNew || lastOld, lineDiff(lastOld, lastNew)),
    diff: diff.slice(0, DIFF_CAP),
    command: prev?.command ?? null,
    output: prev?.output ?? null,
    ok: prev?.ok ?? null,
  };
}

/** A shell command is about to run. Drop the previous output so it can't linger. */
export function withCommand(prev: LiveChange | null, command: string): LiveChange {
  return {
    ...(prev ?? blank()),
    command: command.slice(0, 120),
    output: null,
    ok: null,
  };
}

export function withOutput(
  prev: LiveChange | null,
  command: string,
  output: string,
  exitCode: number | null,
): LiveChange {
  const lines = output
    .split("\n")
    .map((line) => line.trimEnd())
    .filter((line) => line.trim().length > 0);
  const failed = exitCode != null ? exitCode !== 0 : /\b(FAIL|FAILED|ERROR)\b/.test(output);
  return {
    ...(prev ?? blank()),
    command: (command || prev?.command || "").slice(0, 120) || null,
    output: lines.slice(-6).join("\n"),
    ok: !failed,
  };
}

function blank(): LiveChange {
  return { path: "", preview: [], diff: [], command: null, output: null, ok: null };
}

function splitLines(text: string): string[] {
  if (!text) return [];
  return text.replace(/\n$/, "").split("\n");
}

/** Three lines around the first added line, so the card shows the edit itself. */
function previewLines(text: string, diff: DiffLine[]): string[] {
  const fresh = splitLines(text);
  if (fresh.length === 0) {
    return diff
      .filter((line) => line.kind === "del")
      .slice(0, PREVIEW_LINES)
      .map((line) => line.text.trimEnd());
  }
  if (fresh.length <= PREVIEW_LINES) return fresh.map((line) => line.trimEnd());
  const firstAdd = diff.find((line) => line.kind === "add")?.text;
  let at = firstAdd ? fresh.findIndex((line) => line === firstAdd) : 0;
  if (at < 0) at = 0;
  const start = Math.max(0, Math.min(at, fresh.length - PREVIEW_LINES));
  return fresh.slice(start, start + PREVIEW_LINES).map((line) => line.trimEnd());
}

function lineDiff(oldText: string, newText: string): DiffLine[] {
  const a = splitLines(oldText);
  const b = splitLines(newText);
  if (a.length === 0 && b.length === 0) return [];
  if (a.length > 48 || b.length > 48) {
    return [
      ...a.slice(0, 24).map((text) => ({ kind: "del" as const, text })),
      ...b.slice(0, 24).map((text) => ({ kind: "add" as const, text })),
    ];
  }

  const n = a.length;
  const m = b.length;
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ kind: "ctx", text: a[i] });
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.push({ kind: "del", text: a[i] });
      i++;
    } else {
      out.push({ kind: "add", text: b[j] });
      j++;
    }
  }
  while (i < n) out.push({ kind: "del", text: a[i++] });
  while (j < m) out.push({ kind: "add", text: b[j++] });
  return out;
}

const KEYWORDS = new Set([
  "const", "let", "var", "function", "return", "if", "else", "export", "import",
  "from", "async", "await", "class", "new", "type", "interface", "extends",
  "true", "false", "null", "undefined",
]);

export interface Token {
  text: string;
  kind: "" | "kw" | "fn" | "st" | "nu" | "cm";
}

/** A tiny highlighter, enough for the overview snippet and the diff rows. */
export function highlightLine(line: string): Token[] {
  const out: Token[] = [];
  const re =
    /(\/\/.*$|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_$][\w$]*\b)/g;
  let last = 0;
  let match: RegExpExecArray | null;
  while ((match = re.exec(line))) {
    if (match.index > last) out.push({ text: line.slice(last, match.index), kind: "" });
    const tok = match[1];
    let kind: Token["kind"] = "";
    if (tok.startsWith("//")) kind = "cm";
    else if (tok.startsWith('"') || tok.startsWith("'") || tok.startsWith("`")) kind = "st";
    else if (tok.charCodeAt(0) >= 48 && tok.charCodeAt(0) <= 57) kind = "nu";
    else if (KEYWORDS.has(tok)) kind = "kw";
    else if (/^\s*\(/.test(line.slice(match.index + tok.length))) kind = "fn";
    out.push({ text: tok, kind });
    last = match.index + tok.length;
  }
  if (last < line.length) out.push({ text: line.slice(last), kind: "" });
  if (out.length === 0) out.push({ text: " ", kind: "" });
  return out;
}
