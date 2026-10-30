// Keep hovered controls mounted: moving them in the DOM causes WebView2 to
// synthesize pointerleave/pointerenter and can discard a pending click.
export class PillSurface {
  readonly capsule = document.createElement("div");
  readonly bubbles = document.createElement("div");
  private contentKey: string | null = null;
  private bubbleKey: string | null = null;

  constructor(root: HTMLElement) {
    this.capsule.className = "capsule";
    this.bubbles.className = "bubble-slot";
    root.append(this.bubbles, this.capsule);
  }

  content(key: string, build: () => HTMLElement) {
    if (key === this.contentKey) return false;
    this.contentKey = key;
    this.capsule.replaceChildren(build());
    return true;
  }

  bubble(key: string, build: () => HTMLElement | null) {
    if (key === this.bubbleKey) return;
    this.bubbleKey = key;
    const next = build();
    this.bubbles.replaceChildren(...(next ? [next] : []));
  }
}

export type HotRect = [number, number, number, number];
type Box = Pick<DOMRect, "left" | "top" | "width" | "height">;

/** One geometry for native click-through and DOM hover, including size transitions. */
export function hotRects(capsule: Box, bubble: Box | null, edge: string, width: number, height: number): HotRect[] {
  const w = Math.max(capsule.width, width);
  const h = Math.max(capsule.height, height);
  const x = edge === "left" ? capsule.left : edge === "right" ? capsule.left + capsule.width - w : capsule.left + (capsule.width - w) / 2;
  const y = edge === "bottom" ? capsule.top + capsule.height - h : capsule.top + (capsule.height - h) / 2;
  const rects: HotRect[] = [[x - 14, y - 14, w + 28, h + 28]];
  if (bubble) rects.push([bubble.left - 6, bubble.top - 6, bubble.width + 12, bubble.height + 12]);
  return rects;
}

export function insideHot(rects: HotRect[], x: number, y: number): boolean {
  return rects.some(([rx, ry, w, h]) => x >= rx && x <= rx + w && y >= ry && y <= ry + h);
}
