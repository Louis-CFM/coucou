import type { BlurSkirt } from "./motion";

/**
 * The faint wide part of a content blur (`BlurSkirt`, round 42). iOS blurs content as a core
 * Gaussian plus a second one about 13 pt wide; CSS `blur()` draws only the core. A slot blurred by
 * σ points draws a copy of itself, blurred `width` points, at w on top, added
 * (`mix-blend-mode: plus-lighter`), and itself at 1 - `dim` x w. Over the island's black body the
 * two add up to `(1 - dim w) G(σ) + w G(width)`; one element under one filter cannot draw that sum.
 * The engine adds the wide part on top (`dim` 0), so the core keeps the brightness it was fitted at.
 *
 * The copy is the slot's DOM, cloned: it never runs the content's code (no effects, no handlers),
 * and is out of the accessibility tree and of hit testing. It exists only while the weight is above
 * none, so a resting island draws exactly what it did. Content that changes while it is copied
 * (a digit turning) is copied again on the next frame.
 */

/** The weight of the wide part for a slot blurred `sigma` points on screen (`BlurSkirt`): 0 when sharp. */
export const skirtWeight = (skirt: BlurSkirt | undefined, sigma: number, leaving: boolean) => {
  if (!skirt || sigma <= 0) return 0;
  const gain = leaving ? (skirt.exitGain ?? skirt.gain) : skirt.gain;
  const tail = skirt.tail ?? 0;
  const ending = tail > 0 ? Math.min(1, sigma / tail) : 1;
  return Math.min(skirt.max, Math.max(0, gain * sigma ** (skirt.power ?? 2) - skirt.floor)) * ending;
};

/** How much of the weight the slot itself gives up (`BlurSkirt.dim`). */
export const skirtDim = (skirt: BlurSkirt | undefined) => (skirt ? Math.min(1, Math.max(0, skirt.dim ?? 1)) : 1);

/** The copy's blur in its own units: `width` on screen through a scale of `scale`, never past 20 widths. */
export const skirtBlur = (skirt: BlurSkirt, scale: number) => Math.min(skirt.width / Math.max(scale, 0.05), skirt.width * 20);

/** One element's copy: `node` is what was added to the page, `parts` each copied descendant by its source. */
export interface Echo {
  source: HTMLElement;
  node: HTMLElement;
  parts: Map<HTMLElement, HTMLElement>;
  observer: MutationObserver | null;
  stale: boolean;
  used: boolean;
}

/** Each child index from `root` down to `node`, or null when `node` is not inside `root`. */
const pathTo = (root: Node, node: Node): number[] | null => {
  const steps: number[] = [];
  for (let at: Node | null = node; at !== root; at = at.parentNode) {
    const parent: Node | null = at?.parentNode ?? null;
    if (!at || !parent) return null;
    steps.unshift(Array.prototype.indexOf.call(parent.childNodes, at));
  }
  return steps;
};

const follow = (root: Node, steps: number[]): Node | null => {
  let at: Node | null = root;
  for (const step of steps) at = at?.childNodes[step] ?? null;
  return at;
};

const isElement = (node: Node | null): node is HTMLElement => node !== null && node.nodeType === 1;

/** Media a copy leaves out: a copied video or frame would load and play a second time. */
const media = new Set(["VIDEO", "AUDIO", "IFRAME"]);

/** Marks a copy as decoration: no slot or layer names (tools read those), no ids, no media. */
const strip = (node: HTMLElement) => {
  node.removeAttribute("data-slot");
  node.removeAttribute("data-layer");
  node.removeAttribute("id");
  for (const child of Array.from(node.childNodes)) {
    if (!isElement(child)) continue;
    if (media.has(child.tagName.toUpperCase())) node.removeChild(child);
    else strip(child);
  }
};

/** Out of the accessibility tree, focus and hit testing. */
const quiet = (copy: HTMLElement) => {
  strip(copy);
  copy.setAttribute("aria-hidden", "true");
  copy.setAttribute("inert", "");
  copy.style.pointerEvents = "none";
};

export class Skirts {
  private echoes = new Map<HTMLElement, Echo>();

  /** Whether this page can copy elements (the interruption probe's DOM may not). */
  static canCopy = (element: HTMLElement) => typeof element.cloneNode === "function";

  /** Call before a frame's writes: copies not asked for again by `end` are removed. */
  begin() {
    for (const echo of this.echoes.values()) echo.used = false;
  }

  /** Removes the copies this frame did not ask for. */
  end() {
    for (const [source, echo] of this.echoes) {
      if (echo.used) continue;
      this.drop(echo);
      this.echoes.delete(source);
    }
  }

  /** Removes every copy. */
  clear() {
    for (const echo of this.echoes.values()) this.drop(echo);
    this.echoes.clear();
  }

  /**
   * The copy of `source` for this frame, made (or made again when its content changed) as the
   * last child of `parent`. With `wrap` the copy sits in a wrapper of its own, which is `node`:
   * the blur then applies after the copy's own clip. `parts` are descendants of `source` whose
   * copies the caller writes to.
   */
  echo(source: HTMLElement, parent: HTMLElement, wrap: boolean, parts: readonly HTMLElement[]): Echo | null {
    const was = this.echoes.get(source);
    if (was && !was.stale && was.node.parentNode === parent && parts.every((part) => was.parts.has(part))) {
      was.used = true;
      return was;
    }
    if (was) this.drop(was);
    const copy = source.cloneNode(true);
    if (!isElement(copy)) return null;
    const mapped = new Map<HTMLElement, HTMLElement>();
    for (const part of parts) {
      const steps = pathTo(source, part);
      const twin = steps ? follow(copy, steps) : null;
      if (isElement(twin)) mapped.set(part, twin);
    }
    mapped.set(source, copy);
    quiet(copy);
    let node = copy;
    if (wrap) {
      const doc = source.ownerDocument;
      node = doc.createElement("div");
      node.setAttribute("aria-hidden", "true");
      node.style.position = "absolute";
      node.style.inset = "0";
      node.style.pointerEvents = "none";
      node.appendChild(copy);
    }
    // Named, so tools that read the island's slots (the interruption probe) can tell a copy from its source.
    node.setAttribute("data-islandcn-skirt", "");
    node.style.mixBlendMode = "plus-lighter";
    // Its own layer while it shows (Apple's WebKit draws small blurs right only on a layer; platform.ts).
    node.style.willChange = "transform, opacity, filter";
    parent.appendChild(node);
    const echo: Echo = { source, node, parts: mapped, observer: null, stale: false, used: true };
    if (typeof MutationObserver !== "undefined") {
      echo.observer = new MutationObserver(() => {
        echo.stale = true;
      });
      echo.observer.observe(source, { childList: true, characterData: true, subtree: true });
    }
    this.echoes.set(source, echo);
    return echo;
  }

  private drop(echo: Echo) {
    echo.observer?.disconnect();
    echo.node.parentNode?.removeChild(echo.node);
  }
}
