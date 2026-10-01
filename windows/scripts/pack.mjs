// Copies what Tauri buries in target/release/bundle/ into windows/release/, with
// the names it ships under. Used by `npm run pack` and by the release workflows,
// so both produce exactly the same file names.
//
// Windows: the NSIS installer. Linux: the AppImage, the .rpm and the .deb.

import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundleRoot = join(root, "target", "release", "bundle");
const bundleDir = join(bundleRoot, "nsis");
const outDir = join(root, "release");

const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));

/** Newest file in `dir` ending in `suffix`, or null. */
function newest(dir, suffix) {
  let files = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(suffix));
  } catch {
    return null;
  }
  return files
    .map((f) => join(dir, f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0] ?? null;
}

if (process.platform === "linux") {
  const kinds = [
    ["appimage", ".AppImage", `Coucou-Linux-${version}-x86_64.AppImage`, "Coucou-Linux-x86_64.AppImage"],
    ["rpm", ".rpm", `Coucou-Linux-${version}-x86_64.rpm`, null],
    ["deb", ".deb", `Coucou-Linux-${version}-amd64.deb`, null],
  ];
  mkdirSync(outDir, { recursive: true });
  const made = [];
  for (const [dir, suffix, versioned, rolling] of kinds) {
    const built = newest(join(bundleRoot, dir), suffix);
    if (!built) continue;
    for (const name of [versioned, rolling].filter(Boolean)) {
      copyFileSync(built, join(outDir, name));
      made.push(join(outDir, name));
    }
  }
  if (made.length === 0) {
    console.error(`No bundle in ${bundleRoot} — run \`npm run tauri build\` first.`);
    process.exit(1);
  }
  console.log("\n  Linux packages ready\n");
  for (const f of made) console.log(`  ${f}  (${(statSync(f).size / 1024 / 1024).toFixed(2)} MB)`);
  console.log("");
  process.exit(0);
}

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
const versioned = join(outDir, `Coucou-Windows-${version}-setup.exe`);
const rolling = join(outDir, "Coucou-Windows-setup.exe");
copyFileSync(built, versioned);
copyFileSync(built, rolling);

const mb = (statSync(versioned).size / 1024 / 1024).toFixed(2);
console.log(`\n  Installer ready — ${mb} MB\n`);
console.log(`  ${versioned}`);
console.log(`  ${rolling}\n`);
