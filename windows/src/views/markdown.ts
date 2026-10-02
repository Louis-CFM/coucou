// Markdown for chat replies: paragraphs, headings, lists, quotes, fenced code,
// and inline **bold**, *italic*, `code` and [links](https://…).
//
// Builds DOM nodes and only ever sets text content, so a reply can never inject
// markup; links open in the browser through Rust, and only http(s) ones.

import { Bridge } from "../core/bridge";

export function renderMarkdown(src: string): DocumentFragment {
  const out = document.createDocumentFragment();
  const lines = src.replace(/\r\n?/g, "\n").split("\n");
  let i = 0;
  let para: string[] = [];

  const flush = () => {
    if (para.length === 0) return;
    const p = document.createElement("p");
    para.forEach((line, k) => {
      if (k > 0) p.append(document.createElement("br"));
      p.append(inline(line));
    });
    out.append(p);
    para = [];
  };

  while (i < lines.length) {
    const line = lines[i];

    // ``` fenced code ```
    const fence = /^\s*```/.exec(line);
    if (fence) {
      flush();
      const code: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
      i++; // closing fence
      const pre = document.createElement("pre");
      const el = document.createElement("code");
      el.textContent = code.join("\n");
      pre.append(el);
      out.append(pre);
      continue;
    }

    // # Heading
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flush();
      const el = document.createElement("div");
      el.className = `md-h md-h${Math.min(3, heading[1].length)}`;
      el.append(inline(heading[2]));
      out.append(el);
      i++;
      continue;
    }

    // Lists: "- ", "* ", "• " or "1. "
    const bullet = /^\s*([-*•]|\d+[.)])\s+/.exec(line);
    if (bullet) {
      flush();
      const ordered = /\d/.test(bullet[1]);
      const list = document.createElement(ordered ? "ol" : "ul");
      while (i < lines.length) {
        const m = /^\s*([-*•]|\d+[.)])\s+(.*)$/.exec(lines[i]);
        if (!m || /\d/.test(m[1]) !== ordered) break;
        const li = document.createElement("li");
        li.append(inline(m[2]));
        list.append(li);
        i++;
      }
      out.append(list);
      continue;
    }

    // > quote
    if (/^\s*>/.test(line)) {
      flush();
      const q = document.createElement("blockquote");
      const body: string[] = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) body.push(lines[i++].replace(/^\s*>\s?/, ""));
      q.append(inline(body.join(" ")));
      out.append(q);
      continue;
    }

    // --- rule
    if (/^\s*([-*_])\1{2,}\s*$/.test(line)) {
      flush();
      out.append(document.createElement("hr"));
      i++;
      continue;
    }

    if (line.trim() === "") flush();
    else para.push(line);
    i++;
  }
  flush();
  return out;
}

const INLINE = /(`[^`]+`)|(\*\*[^*]+\*\*|__[^_]+__)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\((?:[^()\s]|\([^()\s]*\))+\))/;

function inline(text: string): DocumentFragment {
  const out = document.createDocumentFragment();
  let rest = text;
  while (rest) {
    const m = INLINE.exec(rest);
    if (!m) {
      out.append(rest);
      break;
    }
    if (m.index > 0) out.append(rest.slice(0, m.index));
    const tok = m[0];
    if (m[1]) {
      const el = document.createElement("code");
      el.textContent = tok.slice(1, -1);
      out.append(el);
    } else if (m[2]) {
      const el = document.createElement("strong");
      el.append(inline(tok.slice(2, -2)));
      out.append(el);
    } else if (m[3]) {
      const el = document.createElement("em");
      el.append(inline(tok.slice(1, -1)));
      out.append(el);
    } else if (m[4]) {
      // Addresses may hold one level of brackets (Wikipedia links do).
      const link = /^\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)$/.exec(tok)!;
      if (/^https?:\/\//i.test(link[2])) {
        const a = document.createElement("a");
        a.textContent = link[1];
        a.title = link[2];
        a.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          void Bridge.openUrl(link[2]);
        });
        out.append(a);
      } else {
        out.append(link[1]);
      }
    }
    rest = rest.slice(m.index + tok.length);
  }
  return out;
}
