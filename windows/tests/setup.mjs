// Loaded before every test file (see the `test` script in package.json).
// Node runs the island's TypeScript as it is; this only supplies what the
// webview and the bundler normally would.

import { readFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { resolve as pathResolve, dirname } from "node:path";
import { internals } from "./tauri.mjs";

const srcDir = pathResolve(dirname(fileURLToPath(import.meta.url)), "../src");

// The sources import each other without an extension, which Vite resolves.
registerHooks({
  resolve(specifier, context, nextResolve) {
    const ours = !context.parentURL?.includes("/node_modules/");
    if (ours && specifier.startsWith("@/")) {
      const rel = specifier.slice(2);
      const target = pathResolve(srcDir, rel);
      const fileUrl = pathToFileURL(/\.(?:[cm]?[jt]sx?|json|css)$/.test(target) ? target : `${target}.ts`).href;
      return nextResolve(fileUrl, context);
    }
    if (ours && specifier.startsWith(".") && !/\.(?:[cm]?[jt]sx?|json|css)$/.test(specifier)) {
      return nextResolve(`${specifier}.ts`, context);
    }
    return nextResolve(specifier, context);
  },
  // Vite imports JSON (src/i18n/*.json) without `with { type: "json" }`;
  // Node would refuse it, so it is handed over as a module.
  // CSS imports in TS/JS files are resolved as empty mock modules for tests.
  load(url, context, nextLoad) {
    if (url.startsWith("file:") && url.endsWith(".css")) {
      return { format: "module", source: "export default {};", shortCircuit: true };
    }
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
globalThis.__COUCOU_TEST__ = true;
globalThis.NodeList = globalThis.NodeList ?? class NodeList {};
globalThis.HTMLCollection = globalThis.HTMLCollection ?? class HTMLCollection {};
globalThis.requestAnimationFrame = globalThis.requestAnimationFrame ?? ((cb) => setTimeout(cb, 0));
globalThis.cancelAnimationFrame = globalThis.cancelAnimationFrame ?? ((id) => clearTimeout(id));
