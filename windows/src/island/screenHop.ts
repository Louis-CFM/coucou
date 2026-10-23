// The island changes screens like a notch would: it tucks up into
// the top edge of the display it leaves, the window moves while it's out of
// sight, and it drops down from the top edge of the next display, settling with
// a small give. Without it the window jumps across in one frame.

const TUCK_MS = 190;
const DROP_MS = 560;
/** Past the island's bottom edge, so Mochi's overhang and glow go too. */
const TUCK_MARGIN = 24;
const EASE_IN = "cubic-bezier(0.5, 0, 0.9, 0.4)";
/** Decelerates into a few px of overshoot, then settles back. */
const EASE_DROP = "cubic-bezier(0.22, 1.18, 0.36, 1)";
/** Frames to wait at most for the window to land on the new display. */
const LAND_FRAMES = 12;

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

type Move = () => Promise<void>;

let hopping: Promise<void> | null = null;
/** A display change that came in mid-hop, run while the island is still away. */
let queued: Move | null = null;
/** Where the island was last placed: the window starts on its display. */
let lastDisplay = display();

/**
 * Runs `move` (which places the window on its display) inside the hop.
 * `visible` says whether there is an island on screen to animate; a hidden
 * one just moves.
 */
export function hopScreens(move: Move, visible: () => boolean): Promise<void> {
  if (hopping) {
    queued = move;
    return hopping;
  }
  hopping = hop(move, visible).finally(() => {
    hopping = null;
  });
  return hopping;
}

async function hop(move: Move, visible: () => boolean) {
  const root = document.getElementById("root");
  if (!root || !visible() || reducedMotion.matches) {
    await moveAll(move);
    return;
  }
  // A drop still running is taken over from where the island is.
  const from = getComputedStyle(root);
  const start = { transform: from.transform, opacity: Number(from.opacity) };
  const shift = new DOMMatrix(from.transform).m42;
  for (const a of root.getAnimations()) a.cancel();

  const away = { transform: `translateY(${-depth(shift)}px)`, opacity: 0 };
  // Settings → "Island lives on" has Rust move the window before this runs:
  // it is already there, so it only drops in.
  const tuck = display() === lastDisplay
    ? root.animate([start, away], { duration: TUCK_MS, easing: EASE_IN, fill: "forwards" })
    : null;
  await tuck?.finished.catch(() => {});
  try {
    await moveAll(move);
    await landed();
  } finally {
    // Started before the tuck is dropped, in the same task: no frame shows the
    // island back in place before it falls.
    root.animate(
      [
        { ...away, offset: 0 },
        { opacity: 1, offset: 0.35 },
        { transform: "none", opacity: 1, offset: 1 },
      ],
      { duration: DROP_MS, easing: EASE_DROP },
    );
    tuck?.cancel();
  }
}

/** Places the window, then again for any display change that came meanwhile. */
async function moveAll(move: Move) {
  let next: Move | null = queued ?? move;
  while (next) {
    queued = null;
    await next();
    next = queued;
  }
  lastDisplay = display();
}

/** How far up the island has to go to leave the screen, from where it rests. */
function depth(shift: number): number {
  let bottom = 0;
  for (const id of ["island", "bot-canvas"]) {
    const el = document.getElementById(id);
    if (el) bottom = Math.max(bottom, el.getBoundingClientRect().bottom - shift);
  }
  return Math.ceil(bottom) + TUCK_MARGIN;
}

/** Waits for the window to settle on the new display: its pixel ratio stops changing. */
async function landed() {
  let last = window.devicePixelRatio;
  for (let i = 0, still = 0; i < LAND_FRAMES && still < 2; i++) {
    await new Promise((r) => requestAnimationFrame(r));
    still = window.devicePixelRatio === last ? still + 1 : 0;
    last = window.devicePixelRatio;
  }
}

/** The display the window is on, as the webview sees it. */
function display(): string {
  const s = screen as Screen & { availLeft?: number; availTop?: number };
  return `${s.availLeft ?? 0},${s.availTop ?? 0},${s.width}x${s.height}`;
}
