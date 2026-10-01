// Copies the packages Tauri buries in target/release/bundle/ into
// windows/release/, with the names they ship under. Used by `npm run pack` and by
// the release workflow, so both produce exactly the same file names.
//
//   Windows: Coucou-Windows-X.Y.Z-setup.exe   (+ Coucou-Windows-setup.exe)
//   Linux:   Coucou-Linux-X.Y.Z-amd64.deb      (+ Coucou-Linux-amd64.deb)
//            Coucou-Linux-X.Y.Z-amd64.AppImage (+ Coucou-Linux-amd64.AppImage)

import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const bundleRoot = join(root, "target", "release", "bundle");
const outDir = join(root, "release");

const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));

const packages =
  process.platform === "win32"
    ? [{ dir: "nsis", suffix: "-setup.exe", name: (v) => `Coucou-Windows${v}-setup.exe` }]
    : [
        { dir: "deb", suffix: ".deb", name: (v) => `Coucou-Linux${v}-amd64.deb` },
        { dir: "appimage", suffix: ".AppImage", name: (v) => `Coucou-Linux${v}-amd64.AppImage` },
      ];

/** The newest file in `dir` ending with `suffix`, in case an older build is still lying around. */
function newest(dir, suffix) {
  let files = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(suffix));
  } catch {}
  return files
    .map((f) => join(dir, f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
}

mkdirSync(outDir, { recursive: true });
const ready = [];
for (const pkg of packages) {
  const dir = join(bundleRoot, pkg.dir);
  const built = newest(dir, pkg.suffix);
  if (!built) {
    console.error(`No package in ${dir} — run \`npm run tauri build\` first.`);
    process.exit(1);
  }
  const versioned = join(outDir, pkg.name(`-${version}`));
  const rolling = join(outDir, pkg.name(""));
  copyFileSync(built, versioned);
  copyFileSync(built, rolling);
  ready.push(versioned, rolling);
}

const mb = (f) => (statSync(f).size / 1024 / 1024).toFixed(2);
console.log(`\n  Packages ready\n`);
for (const f of ready) console.log(`  ${f}  (${mb(f)} MB)`);
console.log();
