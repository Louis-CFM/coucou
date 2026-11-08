// Copies the packages Tauri buries in target/release/bundle/ into
// OS-specific release paths (linux/release/ for Linux, windows/release/ for Windows).
// Used by `npm run pack` and by the release workflows.

import { readFileSync, mkdirSync, copyFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(root, "..");
const bundleRoot = join(root, "target", "release", "bundle");

// Target directories separated by OS
const outDirs = process.platform === "linux"
  ? [join(repoRoot, "linux", "release"), join(root, "release")]
  : [join(root, "release")];

const { version } = JSON.parse(readFileSync(join(root, "src-tauri", "tauri.conf.json"), "utf8"));

// What each platform ships: where Tauri puts it, how to recognise it, and the
// names it is published under (the rolling name, when there is one, always
// points at the latest release).
const arch = process.arch === "arm64" ? "aarch64" : "x86_64";
const debArch = process.arch === "arm64" ? "arm64" : "amd64";
const PACKAGES = {
  win32: [
    {
      dir: "nsis",
      suffix: "-setup.exe",
      names: [`NexIsland-Windows-${version}-setup.exe`, "NexIsland-Windows-setup.exe"],
    },
    {
      dir: "msi",
      suffix: ".msi",
      names: [`NexIsland-Windows-${version}.msi`, "NexIsland-Windows.msi"],
    },
  ],
  linux: [
    {
      dir: "appimage",
      suffix: ".AppImage",
      names: [`NexIsland-Linux-${version}-${arch}.AppImage`, `NexIsland-Linux-${arch}.AppImage`],
    },
    { dir: "deb", suffix: ".deb", names: [`NexIsland-Linux-${version}-${debArch}.deb`] },
    { dir: "rpm", suffix: ".rpm", names: [`NexIsland-Linux-${version}-${arch}.rpm`] },
  ],
};

const packages = PACKAGES[process.platform];
if (!packages) {
  console.error(`Nothing to pack on ${process.platform}.`);
  process.exit(1);
}

/** The newest file in `dir` ending with `suffix`, in case an older build is still lying around. */
function newest(dir, suffix) {
  let files = [];
  try {
    files = readdirSync(dir).filter((f) => f.endsWith(suffix));
  } catch {
    return null;
  }
  if (files.length === 0) return null;
  return files
    .map((f) => join(dir, f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)[0];
}

for (const dir of outDirs) {
  mkdirSync(dir, { recursive: true });
}
const written = [];
for (const { dir, suffix, names } of packages) {
  const built = newest(join(bundleRoot, dir), suffix);
  if (!built) {
    console.warn(`Note: No *${suffix} in ${join(bundleRoot, dir)} (toolchain may be absent for this format).`);
    continue;
  }
  for (const name of names) {
    for (const targetDir of outDirs) {
      const dest = join(targetDir, name);
      copyFileSync(built, dest);
      written.push(dest);
    }
  }
}

console.log("\n  Packages ready\n");
for (const f of written) {
  const mb = (statSync(f).size / 1024 / 1024).toFixed(2);
  console.log(`  ${f}  (${mb} MB)`);
}
console.log();
