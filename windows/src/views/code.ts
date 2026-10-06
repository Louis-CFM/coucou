// A file as the GitHub panel shows it: its extension's badge, and its lines
// coloured the way an editor would — keywords, strings, numbers, calls, types.
//
// No highlighting library: the island reads a few dozen lines of a diff, one
// line at a time, so a small tokenizer per comment style is all it takes. It
// knows nothing of what came on the line before (a string or a comment left
// open), which a diff's fragments wouldn't tell it anyway.

import { h } from "./dom";
import { COLOR, isLight } from "./palette";

type Comment = "slash" | "hash" | "dash";

export interface FileKind {
  /** Two or three letters for the badge. */
  label: string;
  /** GitHub's colour for the language. */
  color: string;
  comment?: Comment;
  /** A programming language: keywords, calls and types are coloured too. */
  words?: boolean;
  /** `'` opens a string. Not in Rust, where it also starts a lifetime. */
  apostrophe?: boolean;
}

const code = (label: string, color: string, more: Partial<FileKind> = {}): FileKind => ({
  label, color, comment: "slash", words: true, apostrophe: true, ...more,
});
const script = (label: string, color: string, more: Partial<FileKind> = {}): FileKind => ({
  label, color, comment: "hash", words: true, apostrophe: true, ...more,
});
const data = (label: string, color: string, more: Partial<FileKind> = {}): FileKind => ({
  label, color, apostrophe: true, ...more,
});

const TS = code("TS", "#3178C6");
const JS = code("JS", "#F1E05A");
const CPP = code("C++", "#F34B7D");
const SHELL = script("SH", "#89E051");
const YAML = data("YML", "#CB171E", { comment: "hash" });
const IMAGE: FileKind = { label: "IMG", color: "#A074C4" };

const BY_EXTENSION: Record<string, FileKind> = {
  ts: TS, mts: TS, cts: TS, tsx: code("TSX", "#3178C6"),
  js: JS, mjs: JS, cjs: JS, jsx: code("JSX", "#F1E05A"),
  rs: code("RS", "#DEA584", { apostrophe: false }),
  go: code("GO", "#00ADD8"),
  swift: code("SW", "#F05138"),
  kt: code("KT", "#A97BFF"), kts: code("KT", "#A97BFF"),
  java: code("JV", "#B07219"),
  c: code("C", "#555555"), h: code("H", "#555555"),
  cpp: CPP, cc: CPP, cxx: CPP, hpp: CPP,
  cs: code("C#", "#178600"),
  php: code("PHP", "#4F5D95"),
  dart: code("DT", "#00B4AB"),
  vue: code("VUE", "#41B883"),
  svelte: code("SV", "#FF3E00"),
  astro: code("AST", "#FF5A03"),
  py: script("PY", "#3572A5"),
  rb: script("RB", "#701516"),
  sh: SHELL, bash: SHELL, zsh: SHELL,
  ps1: script("PS", "#012456"),
  sql: { label: "SQL", color: "#E38C00", comment: "dash", words: true, apostrophe: true },
  lua: { label: "LUA", color: "#000080", comment: "dash", words: true, apostrophe: true },
  css: data("CSS", "#663399", { comment: "slash" }),
  scss: data("SCS", "#C6538C", { comment: "slash" }),
  less: data("LES", "#1D365D", { comment: "slash" }),
  json: data("{ }", "#CBCB41"), jsonc: data("{ }", "#CBCB41", { comment: "slash" }),
  yml: YAML, yaml: YAML,
  toml: data("TML", "#9C4221", { comment: "hash" }),
  lock: data("LCK", COLOR.grey, { comment: "hash" }),
  env: data("ENV", COLOR.grey, { comment: "hash" }),
  ini: data("INI", COLOR.grey, { comment: "hash" }),
  md: { label: "MD", color: "#083FA1" }, mdx: { label: "MDX", color: "#083FA1" },
  html: { label: "HTM", color: "#E34C26" }, htm: { label: "HTM", color: "#E34C26" },
  xml: { label: "XML", color: "#0060AC" },
  svg: { label: "SVG", color: "#FFB13B" },
  txt: { label: "TXT", color: COLOR.grey },
  png: IMAGE, jpg: IMAGE, jpeg: IMAGE, gif: IMAGE, webp: IMAGE, ico: IMAGE, icns: IMAGE,
};

/** Files known by their whole name. */
const BY_NAME: Record<string, FileKind> = {
  dockerfile: script("DKR", "#384D54", { words: false }),
  makefile: script("MK", "#427819", { words: false }),
};

export function fileKind(path: string): FileKind {
  const name = path.slice(path.lastIndexOf("/") + 1).toLowerCase();
  const named = BY_NAME[name];
  if (named) return named;
  const dot = name.lastIndexOf(".");
  const extension = dot > 0 ? name.slice(dot + 1) : "";
  // An extension nobody listed still gets its own letters, on grey.
  return BY_EXTENSION[extension] ?? { label: extension ? extension.slice(0, 3).toUpperCase() : "·", color: COLOR.blank };
}

/** The file's kind as an editor's tab shows it: its letters on its colour. */
export function extBadge(path: string): HTMLElement {
  const kind = fileKind(path);
  // On a light colour the letters go dark.
  const el = h("span", { class: isLight(kind.color) ? "gh-ext dark" : "gh-ext", text: kind.label });
  el.style.setProperty("--c", kind.color);
  return el;
}

// One list for every language: a word that is a keyword in one and a name in
// another is rare enough, and a diff line gives too little to tell which.
const KEYWORDS = new Set(
  (
    "abstract and as async await break case catch class const continue crate def default defer del delete do dyn elif else " +
    "enum except export extends extern final finally fn for from func function global go if impl implements import in " +
    "instanceof interface is lambda let loop match mod move mut namespace new nonlocal not of or override package pass " +
    "private protected pub public raise readonly ref return select self static struct super switch template this throw " +
    "trait try type typedef typeof union unsafe use using var virtual void where while with yield"
  ).split(" "),
);

/** Values spelled as words — coloured in data files too. */
const LITERALS = new Set(["true", "false", "null", "undefined", "nil", "None", "True", "False", "NaN"]);

const tokenizers = new Map<string, RegExp>();

/** comment | string | number | word, in that order of precedence. */
function tokenizer(kind: FileKind): RegExp {
  const key = `${kind.comment ?? ""}|${kind.apostrophe === false ? "" : "'"}`;
  let re = tokenizers.get(key);
  if (!re) {
    const comment =
      kind.comment === "slash"
        ? String.raw`\/\/.*$|\/\*.*?(?:\*\/|$)`
        : kind.comment === "hash"
          ? // Only at the start of a line or after a space: a # inside a URL is not a comment.
            String.raw`(?:^|(?<=\s))#.*$`
          : kind.comment === "dash"
            ? String.raw`--.*$`
            : "(?!)";
    const quoted = [String.raw`"(?:[^"\\]|\\.)*"`, "`(?:[^`\\\\]|\\\\.)*`"];
    if (kind.apostrophe !== false) quoted.push(String.raw`'(?:[^'\\]|\\.)*'`);
    const number = String.raw`\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b`;
    re = new RegExp(`(${comment})|(${quoted.join("|")})|(${number})|([A-Za-z_$][\\w$]*)`, "g");
    tokenizers.set(key, re);
  }
  re.lastIndex = 0;
  return re;
}

/** What colour a word takes, if any. */
function wordClass(word: string, kind: FileKind, next: string): string | null {
  if (LITERALS.has(word)) return "hl-k";
  if (!kind.words) return null;
  if (KEYWORDS.has(word)) return "hl-k";
  // CONSTANTS read as values; Capitalised names as types; a name before "(" as a call.
  if (/^[A-Z][A-Z0-9_]+$/.test(word)) return "hl-c";
  if (/^[A-Z]/.test(word)) return "hl-y";
  if (next === "(") return "hl-f";
  return null;
}

/** One line of code as coloured pieces. A file of no known kind stays plain. */
export function highlight(line: string, kind: FileKind): Node[] {
  if (kind.comment == null && !kind.words && kind.apostrophe == null) return [document.createTextNode(line)];
  const out: Node[] = [];
  const re = tokenizer(kind);
  let at = 0;
  const plain = (to: number) => {
    if (to > at) out.push(document.createTextNode(line.slice(at, to)));
  };
  for (let m = re.exec(line); m; m = re.exec(line)) {
    const [text, comment, string, number, word] = m;
    let cls: string | null = null;
    if (comment != null) cls = "hl-m";
    else if (string != null) {
      // A string before a colon is a key: JSON, YAML, an object literal.
      cls = /^\s*:/.test(line.slice(m.index + text.length)) ? "hl-p" : "hl-s";
    } else if (number != null) cls = "hl-c";
    else if (word != null) cls = wordClass(word, kind, line.charAt(m.index + text.length));
    if (cls) {
      plain(m.index);
      out.push(h("span", { class: cls, text }));
      at = m.index + text.length;
    }
    // An empty match (the hash comment's lookbehind can't produce one, but a
    // pattern that could would loop forever here).
    if (text.length === 0) re.lastIndex += 1;
  }
  plain(line.length);
  return out;
}
