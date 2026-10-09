import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
test("Nova keeps its product name and no upstream sound bundle", () => {
  const conf = JSON.parse(readFileSync(`${root}src-tauri/tauri.conf.json`, "utf8"));
  assert.equal(conf.productName, "Nova");
  assert.equal(conf.identifier, "com.sweety.nova");
  assert.deepEqual(conf.bundle.targets, ["nsis"]);
  assert.equal(conf.app.windows[0].skipTaskbar, true);
  const vite = readFileSync(`${root}vite.config.ts`, "utf8");
  assert.equal(vite.includes("sharedSounds"), false);
  assert.equal(vite.includes("Resources/sounds"), false);
  const pkg = JSON.parse(readFileSync(`${root}package.json`, "utf8"));
  assert.equal(pkg.name, "nova-windows");
});
test("user-facing translation tables contain no retired brand", () => {
  for (const name of readdirSync(`${root}src/i18n`).filter(n => n.endsWith(".json")))
    assert.doesNotMatch(readFileSync(`${root}src/i18n/${name}`, "utf8"), /coucou|mochi|notchbuddy/i);
});
test("main and independent upload renderers restore the white character palette", () => {
  for (const file of ["src/nova/engine.ts", "src/upload/canvas.ts"]) {
    const text = readFileSync(`${root}${file}`, "utf8");
    assert.ok(text.includes("#EDEDEF"), file);
    assert.ok(text.includes("#C4C5CA"), file);
    assert.ok(!text.includes("1.35 / (Math.abs(ca) + Math.abs(sa))"), file);
  }
  const recap = readFileSync(`${root}src/recap/share.ts`, "utf8");
  assert.ok(recap.includes("Nova · personal desktop island"));
});
