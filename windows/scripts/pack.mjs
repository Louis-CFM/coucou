// Copies the installer Tauri buries in target/release/bundle/nsis/ into
// windows/release/, with the name it ships under. Used by `npm run pack` and by
// the release workflow, so both produce exactly the same file names.

import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundleDir = join(root, "target", "release", "bundle", "nsis");
const outDir = join(root, "release");

const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));

let installers = [];
try {
  installers = readdirSync(bundleDir).filter((f) => f.endsWith("-setup.exe"));
} catch {
  console.error(`No installer in ${bundleDir} — run \`npm run tauri build\` first.`);
  process.exit(1);
}
if (installers.length === 0) {
  console.error(`No installer in ${bundleDir} — run \`npm run tauri build\` first.`);
  process.exit(1);
}

// Newest wins, in case an older build is still lying around.
const built = installers
  .map((f) => join(bundleDir, f))
  .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];

mkdirSync(outDir, { recursive: true });
const versioned = join(outDir, `Alfred-Windows-${version}-setup.exe`);
const rolling = join(outDir, "Alfred-Windows-setup.exe");
copyFileSync(built, versioned);
copyFileSync(built, rolling);

const mb = (statSync(versioned).size / 1024 / 1024).toFixed(2);
console.log(`\n  Installer ready — ${mb} MB\n`);
console.log(`  ${versioned}`);
console.log(`  ${rolling}\n`);
