// test/plugin.test.mjs — plain node test, no framework. Run: node test/plugin.test.mjs
import assert from "node:assert/strict";
import plugin from "../index.ts";

// Shape: matches the bundled ponytail plugin's V2 form
assert.equal(plugin.id, "coucou");
assert.equal(typeof plugin.setup, "function");

// Hard constraint: setup must never throw, even when Coucou is not running.
// Returns a no-op cleanup in that case. (If Coucou IS running it connects and
// returns a real cleanup — both paths must resolve with a function.)
const cleanup = await plugin.setup({});
assert.equal(typeof cleanup, "function");
cleanup();
console.log("plugin.test.mjs PASS");
