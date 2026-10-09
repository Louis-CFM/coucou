// Just enough of a DOM for the views' helpers (views/dom.ts) to build nodes in
// Node. Writing `innerHTML` throws: a view that renders untrusted text must
// never parse it as markup, and a test that reaches for it fails loudly.

class FakeText {
  constructor(text) {
    this.nodeType = 3;
    this.data = String(text);
    this.parentNode = null;
  }
  get textContent() {
    return this.data;
  }
}

class FakeElement {
  constructor(tag, ns = null) {
    this.nodeType = 1;
    this.tagName = String(tag).toUpperCase();
    this.namespaceURI = ns;
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.listeners = new Map();
    this.className = "";
    this.title = "";
    this.dataset = {};
    this.scrollTop = 0;
    this.scrollHeight = 0;
    this.style = { setProperty: (k, v) => (this.style[k] = v) };
    const el = this;
    this.classList = {
      add: (c) => (el.className = [...new Set([...el.className.split(" ").filter(Boolean), c])].join(" ")),
      remove: (c) => (el.className = el.className.split(" ").filter((x) => x && x !== c).join(" ")),
      contains: (c) => el.className.split(" ").includes(c),
      toggle: (c, on) => ((on ?? !el.classList.contains(c)) ? el.classList.add(c) : el.classList.remove(c)),
    };
  }
  set innerHTML(_) {
    throw new Error("innerHTML must never be used");
  }
  get innerHTML() {
    throw new Error("innerHTML must never be used");
  }
  set outerHTML(_) {
    throw new Error("outerHTML must never be used");
  }
  insertAdjacentHTML() {
    throw new Error("insertAdjacentHTML must never be used");
  }
  get parentElement() {
    return this.parentNode?.nodeType === 1 ? this.parentNode : null;
  }
  get children() {
    return this.childNodes.filter((n) => n.nodeType === 1);
  }
  get firstElementChild() {
    return this.children[0] ?? null;
  }
  get firstChild() {
    return this.childNodes[0] ?? null;
  }
  get textContent() {
    return this.childNodes.map((n) => n.textContent).join("");
  }
  set textContent(text) {
    this.childNodes = [];
    if (text !== "") this.append(new FakeText(text));
  }
  setAttribute(k, v) {
    this.attributes.set(k, String(v));
  }
  getAttribute(k) {
    return this.attributes.get(k) ?? null;
  }
  addEventListener(type, fn) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), fn]);
  }
  /** Calls the listeners of `type` with a minimal event. */
  fire(type) {
    const event = { type, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, stopPropagation() {} };
    for (const fn of this.listeners.get(type) ?? []) fn(event);
    return event;
  }
  append(...nodes) {
    for (const n of nodes) {
      const node = typeof n === "string" ? new FakeText(n) : n;
      node.parentNode = this;
      this.childNodes.push(node);
    }
  }
  replaceChildren(...nodes) {
    this.childNodes = [];
    this.append(...nodes);
  }
  removeChild(node) {
    this.childNodes = this.childNodes.filter((n) => n !== node);
    return node;
  }
  remove() {
    this.parentNode?.removeChild(this);
  }
  /** `.a.b` class selectors only: the first descendant carrying every class. */
  querySelector(selector) {
    const wanted = selector.split(".").filter(Boolean);
    return [...this.walk()].find((e) => wanted.every((c) => e.classList.contains(c))) ?? null;
  }
  scrollIntoView() {}
  focus() {}
  select() {}
  /** Every descendant element, depth first. */
  *walk() {
    for (const c of this.children) {
      yield c;
      yield* c.walk();
    }
  }
  /** Descendants by tag name ("A") or class (".md-p"). */
  find(selector) {
    const match = selector.startsWith(".")
      ? (e) => e.classList.contains(selector.slice(1))
      : (e) => e.tagName === selector.toUpperCase();
    return [...this.walk()].filter(match);
  }
}

export function installFakeDom() {
  globalThis.requestAnimationFrame = (fn) => fn();
  globalThis.document = {
    createElement: (tag) => new FakeElement(tag),
    createElementNS: (ns, tag) => new FakeElement(tag, ns),
    createTextNode: (text) => new FakeText(text),
    body: new FakeElement("body"),
  };
  return { root: () => new FakeElement("div") };
}
