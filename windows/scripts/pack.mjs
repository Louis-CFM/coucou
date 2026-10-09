import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
if (process.platform !== "win32") throw new Error("Build Nova on Windows x64.");
const { version } = JSON.parse(readFileSync(join(root, "src-tauri/tauri.conf.json"), "utf8"));
const dir = join(root, "target/release/bundle/nsis");
const built = readdirSync(dir).filter(f => f.endsWith("-setup.exe"))
  .map(f => join(dir, f)).sort((a,b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
if (!built) throw new Error("NSIS installer missing; Tauri build must succeed first.");
const out = join(root, "release"); mkdirSync(out, {recursive:true});
for (const name of [`Nova-Windows-${version}-setup.exe`, "Nova-Windows-setup.exe"])
  copyFileSync(built, join(out, name));
console.log(`Nova ${version} installer ready in release/`);
