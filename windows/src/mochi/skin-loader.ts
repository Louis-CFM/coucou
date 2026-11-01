// Reads the user's skin folder through Rust and hands the files to the
// collection (skins.ts). Kept apart from skins.ts so that file stays free of the
// bridge and can be tested on its own.

import { Bridge } from "../core/bridge";
import { setUserSkins } from "./skins";

/** Reads <config>/skins/*.json again; files that do not parse are left out. */
export async function loadUserSkins(): Promise<void> {
  const files = await Bridge.userSkins();
  if (!files) return;
  const parsed: unknown[] = [];
  for (const text of files) {
    try {
      parsed.push(JSON.parse(text));
    } catch {
      /* not JSON: skipped */
    }
  }
  setUserSkins(parsed);
}
