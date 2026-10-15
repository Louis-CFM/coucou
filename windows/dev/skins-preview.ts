// The full skins (pumpkin, frog, bee…) as the wardrobe icon draws them, at a
// few sizes and head turns. R below 16 is the island's simplified drawing.
// `npx vite`, then open /dev/skins-preview.html. Not shipped.

import { SKIN_BODY, iconMochi } from "../src/mochi/outfits";
import type { Outfit } from "../src/mochi/wardrobe";

const SIZES = [10, 14, 24, 40];
const YAWS = [-0.7, 0, 0.7];
const grid = document.getElementById("grid") as HTMLTableElement;
const dpr = window.devicePixelRatio || 1;

const head = grid.insertRow();
head.insertCell().textContent = "";
for (const R of SIZES) {
  const th = document.createElement("th");
  th.colSpan = YAWS.length;
  th.textContent = `R = ${R}${R < 16 ? " (simple)" : ""}, yaw ${YAWS.join(" / ")}`;
  head.append(th);
}

for (const outfit of Object.keys(SKIN_BODY) as Outfit[]) {
  const row = grid.insertRow();
  row.insertCell().textContent = outfit;
  for (const R of SIZES) {
    for (const yaw of YAWS) {
      const size = Math.ceil(R * 3.6);
      const c = document.createElement("canvas");
      c.width = size * dpr;
      c.height = size * dpr;
      c.style.width = `${size}px`;
      const ctx = c.getContext("2d")!;
      ctx.scale(dpr, dpr);
      iconMochi(ctx, size, outfit, undefined, R, yaw);
      row.insertCell().append(c);
    }
  }
}
