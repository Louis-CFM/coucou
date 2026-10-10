// Minimal DOM helpers — no framework, as specified.

import { Msg, onLanguageChange } from "../i18n/i18n";

type Attrs = Record<string, string | number | boolean | EventListener | Msg | undefined>;
type Child = Node | string | Msg | null | undefined | false;

// ── Text that follows the language ────────────────────────────────────────────
//
// A `tl(…)` string given to h() — as `text`, an attribute (title, placeholder,
// aria-label…) or a child — is remembered with the node it went to. When the
// language changes, every such node still showing what it was given is
// redrawn in place: nothing is rebuilt, so no view loses its state. A node
// whose text some code has replaced since is left alone (and forgotten).

interface Binding {
  node: WeakRef<Node>;
  /** "text" (an element's text or a text node's data) or an attribute name. */
  attr: string;
  msg: Msg;
  /** What was last written, to notice when other code has written over it. */
  shown: string;
}

const bindings = new Set<Binding>();
let sincePrune = 0;

function read(node: Node, attr: string): string | null {
  if (attr === "text") return node.nodeType === 3 ? (node as Text).data : node.textContent;
  return (node as Element).getAttribute(attr);
}

function write(node: Node, attr: string, value: string) {
  if (attr === "text") {
    if (node.nodeType === 3) (node as Text).data = value;
    else node.textContent = value;
  } else {
    (node as Element).setAttribute(attr, value);
  }
}

function bind(node: Node, attr: string, msg: Msg, shown: string) {
  bindings.add({ node: new WeakRef(node), attr, msg, shown });
  // Views rebuild rows all the time: drop what has been collected now and then.
  if (++sincePrune >= 500) {
    sincePrune = 0;
    for (const b of bindings) if (!b.node.deref()) bindings.delete(b);
  }
}

/** Redraws every live `tl(…)` text in the current language. */
export function relabel() {
  for (const b of bindings) {
    const node = b.node.deref();
    if (!node || read(node, b.attr) !== b.shown) {
      bindings.delete(b);
      continue;
    }
    const next = String(b.msg);
    if (next !== b.shown) {
      write(node, b.attr, next);
      b.shown = next;
    }
  }
}

/** How many texts follow the language (tests). */
export function liveTextCount(): number {
  return bindings.size;
}

onLanguageChange(() => relabel());

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Attrs = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (v instanceof Msg) {
      const text = String(v);
      write(el, k, text);
      bind(el, k, v, text);
      continue;
    }
    if (k === "class") el.className = String(v);
    else if (k === "text") el.textContent = String(v);
    else if (k.startsWith("on") && typeof v === "function") {
      el.addEventListener(k.slice(2).toLowerCase(), v as EventListener);
    } else if (k === "style") el.setAttribute("style", String(v));
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children) {
    if (c == null || c === false) continue;
    if (c instanceof Msg) {
      const node = document.createTextNode(String(c));
      bind(node, "text", c, String(c));
      el.append(node);
      continue;
    }
    el.append(typeof c === "string" ? document.createTextNode(c) : c);
  }
  return el;
}

export function svg(
  path: string,
  size = 14,
  opts: { fill?: string; stroke?: number; evenOdd?: boolean } = {},
): SVGSVGElement {
  const el = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  el.setAttribute("viewBox", "0 0 24 24");
  el.setAttribute("width", String(size));
  el.setAttribute("height", String(size));
  el.setAttribute("aria-hidden", "true");
  const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
  p.setAttribute("d", path);
  if (opts.stroke) {
    p.setAttribute("fill", "none");
    p.setAttribute("stroke", "currentColor");
    p.setAttribute("stroke-width", String(opts.stroke));
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
  } else {
    p.setAttribute("fill", opts.fill ?? "currentColor");
    // Lets a filled glyph carry a cut-out (checkmark.seal.fill, xmark.octagon.fill).
    if (opts.evenOdd) p.setAttribute("fill-rule", "evenodd");
  }
  el.append(p);
  return el;
}

export function clear(el: Element) {
  while (el.firstChild) el.removeChild(el.firstChild);
}

/** Card dot used in every "who" row. */
export function dot(color: string, size = 7): HTMLElement {
  return h("i", {
    class: "dot",
    style: `width:${size}px;height:${size}px;background:${color}`,
  });
}
