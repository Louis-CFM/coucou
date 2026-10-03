// Markdown for chat replies, as GitHub renders it: GFM (tables, task lists,
// strikethrough, autolinks, footnotes) through marked, math through KaTeX
// (loaded the first time a reply has some), and GitHub's raw HTML subset.
//
// Model output is untrusted and this page holds Tauri IPC, so marked's HTML
// goes through DOMPurify with an allowlist (no script, no on* handlers, no
// style, no class, only http(s)/mailto/# link targets), then the DOM is
// finished by hand: links lose their href and open in the browser through
// Rust (http(s) only), images become links (the CSP blocks remote ones), code
// gets its copy button.

import { Marked, type TokenizerAndRendererExtension } from "marked";
import markedFootnote from "marked-footnote";
import createDOMPurify from "dompurify";
import { Bridge } from "../core/bridge";
import { svg } from "./dom";
import { ICONS } from "./icons";

/** Puts text on the clipboard; the old execCommand path if the API is refused. */
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const area = document.createElement("textarea");
    area.value = text;
    area.style.cssText = "position:fixed;opacity:0";
    document.body.append(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  }
}

/**
 * A code block with its language and a copy button, as on claude.ai. Used for
 * fenced code in replies and for a dropped code file in the chat.
 */
export function codeBlock(code: string, lang: string, title?: string): HTMLElement {
  const block = document.createElement("div");
  block.className = "code-block";
  const head = document.createElement("div");
  head.className = "code-head";
  const label = document.createElement("span");
  label.className = "code-lang";
  label.textContent = title ?? (lang || "code");
  const copy = document.createElement("button");
  copy.className = "code-copy";
  copy.title = "Copy code";
  const reset = () => copy.replaceChildren(svg(ICONS.copy, 11), document.createTextNode("Copy"));
  reset();
  copy.addEventListener("click", async (e) => {
    e.stopPropagation();
    if (!(await copyText(code))) return;
    copy.replaceChildren(svg(ICONS.check, 11, { stroke: 2.4 }), document.createTextNode("Copied"));
    window.setTimeout(reset, 1400);
  });
  head.append(label, copy);
  const pre = document.createElement("pre");
  const el = document.createElement("code");
  el.textContent = code;
  pre.append(el);
  block.append(head, pre);
  return block;
}

// ── Parsing ───────────────────────────────────────────────────────────────────

const escapeHtml = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** TeX goes out as escaped text in a `data-math` element; KaTeX fills it in later. */
const mathHtml = (tex: string, display: boolean) =>
  display
    ? `<div data-math="display">${escapeHtml(tex.trim())}</div>`
    : `<span data-math="inline">${escapeHtml(tex.trim())}</span>`;

/** `$$ … $$` and `\[ … \]` starting a block. */
const mathBlock: TokenizerAndRendererExtension = {
  name: "mathBlock",
  level: "block",
  start: (src) => src.match(/^ {0,3}(\$\$|\\\[)/m)?.index,
  tokenizer(src) {
    const m = /^ {0,3}(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])[ \t]*(?:\n+|$)/.exec(src);
    if (m) return { type: "mathBlock", raw: m[0], text: m[1] ?? m[2] };
  },
  renderer: (t) => mathHtml(t.text, true),
};

/** `$…$` (GitHub's rules, so "$5 and $10" stays text), $`…`$, `$$…$$`,
 *  and the `\(…\)` / `\[…\]` many models write. */
const mathInline: TokenizerAndRendererExtension = {
  name: "mathInline",
  level: "inline",
  start(src) {
    const i = src.search(/\$|\\[([]/);
    return i < 0 ? undefined : i;
  },
  tokenizer(src) {
    const m =
      /^\$\$([\s\S]+?)\$\$/.exec(src) ??
      /^\\\[([\s\S]+?)\\\]/.exec(src) ??
      /^\\\(([\s\S]+?)\\\)/.exec(src) ??
      /^\$`([^`]+)`\$/.exec(src) ??
      /^\$(?![\s$])((?:\\.|[^\\$\n])+?)(?<!\s)\$(?![\d$])/.exec(src);
    if (m) return { type: "mathInline", raw: m[0], text: m[1], display: /^(\$\$|\\\[)/.test(m[0]) };
  },
  renderer: (t) => mathHtml(t.text, t.display),
};

const md = new Marked(
  // Single line breaks stay line breaks, as in GitHub comments and as before.
  { gfm: true, breaks: true },
  markedFootnote(),
  {
    extensions: [mathBlock, mathInline],
    renderer: {
      // The language rides on a data attribute: class is not let through.
      code: ({ text, lang }) =>
        `<pre data-lang="${escapeHtml((lang ?? "").split(/\s/)[0])}"><code>${escapeHtml(text)}</code></pre>`,
    },
  },
);

// ── Sanitizing ────────────────────────────────────────────────────────────────

const purify = createDOMPurify(window);
// Images never get a live src: they become links below (the CSP blocks remote
// ones anyway). Done here, in DOMPurify's inert document, so nothing is fetched.
purify.addHook("afterSanitizeAttributes", (node) => {
  if (node.nodeName === "IMG" && node.hasAttribute("src")) {
    node.setAttribute("data-src", node.getAttribute("src")!);
    node.removeAttribute("src");
  }
});

/** GitHub's raw HTML allowlist, minus what has no place in a chat bubble. */
const PURIFY = {
  ALLOWED_TAGS: [
    "a", "abbr", "b", "bdo", "blockquote", "br", "caption", "cite", "code", "dd", "del", "details", "dfn",
    "div", "dl", "dt", "em", "figcaption", "figure", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img",
    "input", "ins", "kbd", "li", "mark", "ol", "p", "pre", "q", "rp", "rt", "ruby", "s", "samp", "section",
    "small", "span", "strike", "strong", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th",
    "thead", "time", "tr", "tt", "u", "ul", "var", "wbr",
  ],
  // No style, no class, no on*. data-* stays (data-math, data-lang): inert.
  ALLOWED_ATTR: [
    "href", "src", "alt", "title", "align", "colspan", "rowspan", "open", "start", "reversed", "type",
    "checked", "disabled", "id", "datetime", "aria-label", "aria-describedby",
  ],
  // DOMPurify checks every non-URI attribute value against this too: http(s),
  // mailto and anything with no scheme pass; javascript:, data:… don't.
  ALLOWED_URI_REGEXP: /^(?:https?:|mailto:|[^a-z]|[a-z+.-]+(?:[^a-z+.\-:]|$))/i,
  // ids become "user-content-…", as on GitHub: no clobbering of globals.
  SANITIZE_NAMED_PROPS: true,
  RETURN_DOM_FRAGMENT: true as const,
};

/** Markdown in, sanitized DOM out, before the finishing touches. */
function sanitized(src: string): DocumentFragment {
  return purify.sanitize(md.parse(src, { async: false }), PURIFY);
}

// ── Finishing the DOM ─────────────────────────────────────────────────────────

const isWeb = (url: string) => /^https?:\/\//i.test(url);

const ALERTS = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"];

function openOnClick(el: HTMLElement, url: string) {
  el.title = url;
  el.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    void Bridge.openUrl(url);
  });
}

export function renderMarkdown(src: string): DocumentFragment {
  const out = sanitized(src);

  // Links: never an href the webview could follow.
  for (const a of out.querySelectorAll("a")) {
    const href = a.getAttribute("href") ?? "";
    a.removeAttribute("href");
    if (href.startsWith("#")) {
      // Footnotes and their way back, within this reply. The arrow as text,
      // not Windows' blue emoji.
      if (a.hasAttribute("data-footnote-backref")) a.firstChild!.textContent = "↩︎";
      const id = `user-content-${decodeURIComponent(href.slice(1))}`;
      a.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        const reply = a.closest(".reply") ?? a.parentElement;
        reply?.querySelector(`[id="${CSS.escape(id)}"]`)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
      });
    } else if (isWeb(href)) {
      openOnClick(a, href);
    } else {
      a.replaceWith(...a.childNodes); // mailto and the like: just the text
    }
  }

  for (const img of out.querySelectorAll("img")) {
    const url = img.getAttribute("data-src") ?? "";
    const label = `Image: ${img.getAttribute("alt") || url.split("/").pop() || "picture"}`;
    if (isWeb(url)) {
      const a = document.createElement("a");
      a.className = "md-img";
      a.textContent = label;
      openOnClick(a, url);
      img.replaceWith(a);
    } else {
      img.replaceWith(label);
    }
  }

  // Task list boxes only, never editable.
  for (const input of out.querySelectorAll("input")) {
    if (input.type !== "checkbox") input.remove();
    else input.disabled = true;
  }

  // Headings keep the chat's own style.
  for (const h of out.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    if (h.closest("section[data-footnotes]")) {
      h.remove(); // "Footnotes": the rule above them says it
      continue;
    }
    const div = document.createElement("div");
    div.className = `md-h md-h${Math.min(3, Number(h.tagName[1]))}`;
    div.append(...h.childNodes);
    h.replaceWith(div);
  }
  out.querySelector("section[data-footnotes]")?.classList.add("md-footnotes");

  // > [!NOTE] and friends, as GitHub's alerts.
  for (const q of out.querySelectorAll("blockquote")) {
    const text = q.querySelector("p")?.firstChild;
    const m = text?.nodeType === Node.TEXT_NODE ? /^\s*\[!(\w+)\]\s*/.exec(text.textContent ?? "") : null;
    if (!m || !text || !ALERTS.includes(m[1].toUpperCase())) continue;
    text.textContent = (text.textContent ?? "").slice(m[0].length);
    if (!text.textContent && text.nextSibling?.nodeName === "BR") text.nextSibling.remove();
    q.classList.add("md-alert", `md-alert-${m[1].toLowerCase()}`);
    const title = document.createElement("div");
    title.className = "md-alert-title";
    title.textContent = m[1][0].toUpperCase() + m[1].slice(1).toLowerCase();
    q.prepend(title);
  }

  // Wide tables scroll sideways inside the small chat.
  for (const table of out.querySelectorAll("table")) {
    const wrap = document.createElement("div");
    wrap.className = "md-table";
    table.replaceWith(wrap);
    wrap.append(table);
  }

  // Code: the block with its copy button; ```math is display math.
  for (const pre of out.querySelectorAll("pre")) {
    const lang = pre.getAttribute("data-lang") ?? "";
    const code = (pre.textContent ?? "").replace(/\n$/, "");
    if (lang === "math") {
      const div = document.createElement("div");
      div.dataset.math = "display";
      div.textContent = code;
      pre.replaceWith(div);
    } else {
      pre.replaceWith(codeBlock(code, lang));
    }
  }

  const math = [...out.querySelectorAll<HTMLElement>("[data-math]")];
  for (const el of math) el.classList.add("md-math");
  if (math.length) void typeset(math);
  return out;
}

// ── Math ──────────────────────────────────────────────────────────────────────

type Katex = typeof import("katex").default;
let katex: Promise<Katex> | null = null;

/** KaTeX, its CSS and fonts load once a reply holds math, not before. */
export function loadKatex(): Promise<Katex> {
  katex ??= Promise.all([import("katex"), import("katex/dist/katex.min.css")]).then(([m]) => m.default);
  return katex;
}

async function typeset(nodes: HTMLElement[]) {
  let k: Katex;
  try {
    k = await loadKatex();
  } catch {
    katex = null;
    return; // the TeX source stays readable
  }
  const log = nodes[0].closest(".chat-log");
  const atBottom = log ? log.scrollHeight - log.scrollTop - log.clientHeight < 40 : false;
  for (const el of nodes) {
    // trust: false (the default) keeps \href, \url, \includegraphics… off.
    k.render(el.textContent ?? "", el, {
      displayMode: el.dataset.math === "display", throwOnError: false, strict: "ignore", trust: false, maxExpand: 1000,
    });
  }
  if (log && atBottom) log.scrollTop = log.scrollHeight;
}
