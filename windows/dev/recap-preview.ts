// The weekly recap card in a real island, and the shared image with and
// without project names, on the sample week of scripts/test-weekly-recap.swift.
// `npm run dev`, then open /dev/recap-preview.html. Not shipped in the app.

import "../src/style.css";
import { Island } from "../src/island/island";
import { Recap } from "../src/recap/recap";
import { renderShareImage } from "../src/recap/share";

const island = new Island(document.getElementById("root")!);
await Recap.open(island);

const images = document.getElementById("images")!;
const summary = Recap.summary;
if (summary) {
  for (const [hide, caption] of [[false, "Shared image"], [true, "Project names hidden"]] as const) {
    const img = document.createElement("img");
    img.src = renderShareImage(summary, hide).toDataURL("image/png");
    const figure = document.createElement("figure");
    figure.append(img, caption);
    images.append(figure);
  }
}
