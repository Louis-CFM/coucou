// Loaded before every test file (see the `test` script in package.json).
// Node runs the island's TypeScript as it is; this only supplies what the
// webview and the bundler normally would.

import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath } from "node:url";
import { internals } from "./tauri.mjs";

// The sources import each other without an extension, which Vite resolves.
registerHooks({
  resolve(specifier, context, nextResolve) {
    const ours = !context.parentURL?.includes("/node_modules/");
    if (ours && specifier.startsWith(".") && !/\.(?:[cm]?[jt]s|json)$/.test(specifier)) {
      return nextResolve(`${specifier}.ts`, context);
    }
    return nextResolve(specifier, context);
  },
  // Vite imports JSON (src/i18n/*.json) without `with { type: "json" }`;
  // Node would refuse it, so it is handed over as a module.
  load(url, context, nextLoad) {
    if (url.startsWith("file:") && url.endsWith(".json") && !url.includes("/node_modules/")) {
      const source = readFileSync(fileURLToPath(url), "utf8");
      return { format: "module", source: `export default ${source};`, shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});

// The island reaches timers and Tauri through `window`.
globalThis.window = globalThis;
globalThis.__TAURI_INTERNALS__ = internals;
