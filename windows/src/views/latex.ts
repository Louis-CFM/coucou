// Lightweight LaTeX to MathML converter (zero external dependencies).
// WebKitGTK and Chromium/WebView2 natively render MathML Core.
// All nodes are created with document.createElementNS, never innerHTML.

const NS = "http://www.w3.org/1998/Math/MathML";

function m(tag: string, ...children: (Node | string)[]): Element {
  const el = document.createElementNS(NS, tag);
  for (const c of children) {
    if (typeof c === "string") {
      el.append(document.createTextNode(c));
    } else if (c) {
      el.append(c);
    }
  }
  return el;
}

const SYMBOLS: Record<string, string> = {
  // Greek lowercase
  alpha: "α", beta: "β", gamma: "γ", delta: "δ", epsilon: "ε", varepsilon: "ε",
  zeta: "ζ", eta: "η", theta: "θ", vartheta: "ϑ", iota: "ι", kappa: "κ",
  lambda: "λ", mu: "μ", nu: "ν", xi: "ξ", pi: "π", varpi: "ϖ", rho: "ρ",
  varrho: "ϱ", sigma: "σ", varsigma: "ς", tau: "τ", upsilon: "υ", phi: "φ",
  varphi: "ϕ", chi: "χ", psi: "ψ", omega: "ω",
  // Greek uppercase
  Gamma: "Γ", Delta: "Δ", Theta: "Θ", Lambda: "Λ", Xi: "Ξ", Pi: "Π",
  Sigma: "Σ", Upsilon: "Υ", Phi: "Φ", Psi: "Ψ", Omega: "Ω",
  // Operators & Relations
  pm: "±", mp: "∓", times: "×", div: "÷", cdot: "·", ast: "∗", star: "⋆",
  circ: "∘", bullet: "•", cap: "∩", cup: "∪", uplus: "⊎", sqcap: "⊓",
  sqcup: "⊔", vee: "∨", wedge: "∧", setminus: "∖", wr: "≀",
  leq: "≤", le: "≤", geq: "≥", ge: "≥", neq: "≠", ne: "≠", approx: "≈",
  equiv: "≡", sim: "∼", simeq: "≃", cong: "≅", propto: "∝",
  subset: "⊂", supset: "⊃", subseteq: "⊆", supseteq: "⊇", in: "∈",
  notin: "∉", ni: "∋",
  // Arrows
  leftarrow: "←", to: "→", rightarrow: "→", Leftarrow: "⇐", Rightarrow: "⇒",
  leftrightarrow: "↔", Leftrightarrow: "⇔", mapsto: "↦", uparrow: "↑", downarrow: "↓",
  // Misc symbols
  infty: "∞", partial: "∂", nabla: "∇", forall: "∀", exists: "∃", nexists: "∄",
  empty: "∅", emptyset: "∅", varnothing: "∅", aleph: "ℵ", hbar: "ℏ", ell: "ℓ",
  // Big operators
  sum: "∑", prod: "∏", coprod: "∐", int: "∫", iint: "∬", iiint: "∭", oint: "∮",
  // Blackboard bold
  mathbbR: "ℝ", mathbbN: "ℕ", mathbbZ: "ℤ", mathbbQ: "ℚ", mathbbC: "ℂ"
};

const FUNCTIONS = new Set([
  "sin", "cos", "tan", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh",
  "sec", "csc", "cot", "ln", "log", "exp", "min", "max", "sup", "inf",
  "lim", "limsup", "liminf", "det", "dim", "ker", "deg", "gcd", "hom", "arg"
]);

const ACCENTS: Record<string, string> = {
  vec: "→", hat: "^", bar: "¯", dot: "˙", ddot: "¨", tilde: "~"
};

type ASTNode =
  | { type: "mi"; val: string }
  | { type: "mn"; val: string }
  | { type: "mo"; val: string }
  | { type: "text"; val: string }
  | { type: "space" }
  | { type: "frac"; num: ASTNode; den: ASTNode }
  | { type: "sqrt"; rad: ASTNode; index: ASTNode | null }
  | { type: "accent"; base: ASTNode; accent: string }
  | { type: "sub"; base: ASTNode; sub: ASTNode }
  | { type: "sup"; base: ASTNode; sup: ASTNode }
  | { type: "subsup"; base: ASTNode; sub: ASTNode; sup: ASTNode }
  | { type: "bold"; val: ASTNode }
  | { type: "matrix"; table: ASTNode[][] }
  | { type: "delim"; open: string; close: string; inner: ASTNode }
  | { type: "row"; items: ASTNode[] };

function parseLatex(src: string): ASTNode {
  let pos = 0;
  const len = src.length;

  function skipSpace() {
    while (pos < len && /\s/.test(src[pos])) pos++;
  }

  function parseArg(): string {
    skipSpace();
    if (pos >= len) return "";
    if (src[pos] === "{") {
      pos++;
      let depth = 1;
      const start = pos;
      while (pos < len && depth > 0) {
        if (src[pos] === "{") depth++;
        else if (src[pos] === "}") depth--;
        pos++;
      }
      return src.slice(start, pos - 1);
    }
    if (src[pos] === "\\") {
      const start = pos++;
      while (pos < len && /[a-zA-Z]/.test(src[pos])) pos++;
      if (pos === start + 1 && pos < len) pos++;
      return src.slice(start, pos);
    }
    return src[pos++];
  }

  function parseSeq(stopChars = ""): ASTNode[] {
    const list: ASTNode[] = [];
    while (pos < len) {
      skipSpace();
      if (pos >= len) break;
      const c = src[pos];
      if (stopChars.includes(c)) break;
      const item = parseItem();
      if (item) list.push(item);
    }
    return list;
  }

  function parseItem(): ASTNode | null {
    skipSpace();
    if (pos >= len) return null;
    let base = parseAtom();
    if (!base) return null;

    // Prime notation: y' -> y^prime
    while (pos < len && src[pos] === "'") {
      pos++;
      base = { type: "sup", base, sup: { type: "mo", val: "′" } };
    }

    // Subscript and superscript: _ or ^
    while (pos < len && (src[pos] === "_" || src[pos] === "^")) {
      const op = src[pos++];
      const argStr = parseArg();
      const argNode = parseLatex(argStr);
      if (op === "_") {
        if (base.type === "sup") {
          base = { type: "subsup", base: base.base, sub: argNode, sup: base.sup };
        } else {
          base = { type: "sub", base, sub: argNode };
        }
      } else {
        if (base.type === "sub") {
          base = { type: "subsup", base: base.base, sub: base.sub, sup: argNode };
        } else {
          base = { type: "sup", base, sup: argNode };
        }
      }
    }
    return base;
  }

  function parseAtom(): ASTNode | null {
    skipSpace();
    if (pos >= len) return null;
    const c = src[pos];

    if (c === "{") {
      pos++;
      const inner = parseSeq("}");
      if (pos < len && src[pos] === "}") pos++;
      return { type: "row", items: inner };
    }

    if (c === "\\") {
      pos++;
      let cmd = "";
      while (pos < len && /[a-zA-Z]/.test(src[pos])) cmd += src[pos++];
      if (!cmd && pos < len) {
        cmd = src[pos++];
      }

      if (cmd === "frac") {
        const num = parseLatex(parseArg());
        const den = parseLatex(parseArg());
        return { type: "frac", num, den };
      }
      if (cmd === "sqrt") {
        skipSpace();
        let index: ASTNode | null = null;
        if (pos < len && src[pos] === "[") {
          pos++;
          const start = pos;
          while (pos < len && src[pos] !== "]") pos++;
          index = parseLatex(src.slice(start, pos));
          if (pos < len && src[pos] === "]") pos++;
        }
        const rad = parseLatex(parseArg());
        return { type: "sqrt", rad, index };
      }
      if (cmd === "begin") {
        const env = parseArg().trim();
        let envBody = "";
        const endTag = "\\end{" + env + "}";
        const endIdx = src.indexOf(endTag, pos);
        if (endIdx !== -1) {
          envBody = src.slice(pos, endIdx);
          pos = endIdx + endTag.length;
        } else {
          envBody = src.slice(pos);
          pos = len;
        }
        return parseMatrix(env, envBody);
      }
      if (cmd === "text" || cmd === "mathrm" || cmd === "operatorname") {
        return { type: "text", val: parseArg() };
      }
      if (cmd === "mathbf" || cmd === "bm") {
        return { type: "bold", val: parseLatex(parseArg()) };
      }
      if (cmd === "mathbb") {
        const letter = parseArg().trim();
        const sym = SYMBOLS["mathbb" + letter] || letter;
        return { type: "mi", val: sym };
      }
      if (ACCENTS[cmd]) {
        return { type: "accent", base: parseLatex(parseArg()), accent: ACCENTS[cmd] };
      }
      if (FUNCTIONS.has(cmd)) {
        return { type: "mi", val: cmd };
      }
      if (SYMBOLS[cmd]) {
        const s = SYMBOLS[cmd];
        const isOp = /[±×÷·∗⋆∩∪≤≥≠≈~→←↔∑∏∫∂∇∀∃∞]/.test(s);
        return { type: isOp ? "mo" : "mi", val: s };
      }
      if (cmd === "," || cmd === ":" || cmd === ";" || cmd === "quad" || cmd === "qquad") {
        return { type: "space" };
      }
      if (cmd === "{" || cmd === "}") {
        return { type: "mo", val: cmd };
      }
      if (cmd === "left" || cmd === "right") {
        skipSpace();
        const d = pos < len ? src[pos++] : "";
        return d && d !== "." ? { type: "mo", val: d } : null;
      }
      return { type: "mi", val: cmd };
    }

    if (/\d/.test(c)) {
      let num = "";
      while (pos < len && /[\d.]/.test(src[pos])) num += src[pos++];
      return { type: "mn", val: num };
    }

    if (/[a-zA-Z]/.test(c)) {
      pos++;
      return { type: "mi", val: c };
    }

    pos++;
    return { type: "mo", val: c };
  }

  function parseMatrix(env: string, body: string): ASTNode {
    const rows = body.split(/\\\\|\\cr/).map((r) => r.trim()).filter((r) => r.length > 0);
    const table = rows.map((r) => r.split("&").map((cell) => parseLatex(cell.trim())));
    const mat: ASTNode = { type: "matrix", table };
    if (env === "pmatrix") return { type: "delim", open: "(", close: ")", inner: mat };
    if (env === "bmatrix") return { type: "delim", open: "[", close: "]", inner: mat };
    if (env === "vmatrix") return { type: "delim", open: "|", close: "|", inner: mat };
    if (env === "Bmatrix") return { type: "delim", open: "{", close: "}", inner: mat };
    return mat;
  }

  const items = parseSeq();
  return items.length === 1 ? items[0] : { type: "row", items };
}

function nodeToMathML(node: ASTNode): Node {
  switch (node.type) {
    case "mi": return m("mi", node.val);
    case "mn": return m("mn", node.val);
    case "mo": return m("mo", node.val);
    case "text": return m("mtext", node.val);
    case "space": return m("mspace");
    case "frac": return m("mfrac", nodeToMathML(node.num), nodeToMathML(node.den));
    case "sqrt":
      return node.index
        ? m("mroot", nodeToMathML(node.rad), nodeToMathML(node.index))
        : m("msqrt", nodeToMathML(node.rad));
    case "accent": return m("mover", nodeToMathML(node.base), m("mo", node.accent));
    case "sub": return m("msub", nodeToMathML(node.base), nodeToMathML(node.sub));
    case "sup": return m("msup", nodeToMathML(node.base), nodeToMathML(node.sup));
    case "subsup": return m("msubsup", nodeToMathML(node.base), nodeToMathML(node.sub), nodeToMathML(node.sup));
    case "bold": {
      const el = m("mstyle", nodeToMathML(node.val));
      el.setAttribute("mathvariant", "bold");
      return el;
    }
    case "matrix": {
      const table = m("mtable");
      for (const row of node.table) {
        const tr = m("mtr");
        for (const cell of row) {
          tr.append(m("mtd", nodeToMathML(cell)));
        }
        table.append(tr);
      }
      return table;
    }
    case "delim": {
      return m("mrow", m("mo", node.open), nodeToMathML(node.inner), m("mo", node.close));
    }
    case "row": {
      const row = m("mrow");
      for (const item of node.items) row.append(nodeToMathML(item));
      return row;
    }
  }
}

/** Renders LaTeX into MathML and injects it into `into` without any third-party dependencies. */
export function renderLatex(into: HTMLElement, latex: string, display = false) {
  try {
    const math = document.createElementNS(NS, "math");
    if (display) {
      math.setAttribute("display", "block");
    }
    const ast = parseLatex(latex.trim());
    math.append(nodeToMathML(ast));
    into.replaceChildren(math);
  } catch {
    into.textContent = display ? `$$${latex}$$` : `$${latex}$`;
  }
}
