// Builds the coucou-hook relay into target/release/, where tauri.conf.json bundles it from.
//
//   node scripts/build-hook.mjs          full release profile (LTO, size-optimised): prebuild, pack
//   node scripts/build-hook.mjs --fast   same path, no LTO, no optimisation: predev
//
// The release profile makes the relay tiny and quick to start, which matters for what ships,
// not for a `tauri dev` session. Cargo keys its cache on the profile, so a --fast build can
// never be mistaken for the real one: `npm run build` / `npm run pack` rebuild it in full.

import { spawnSync } from "node:child_process";

const fast = process.argv.includes("--fast");
const env = { ...process.env };
if (fast) {
  env.CARGO_PROFILE_RELEASE_LTO = "false";
  env.CARGO_PROFILE_RELEASE_OPT_LEVEL = "0";
  env.CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  env.CARGO_PROFILE_RELEASE_STRIP = "false";
}

const { status, error } = spawnSync("cargo", ["build", "--release", "-p", "coucou-hook"], {
  stdio: "inherit",
  env,
  shell: process.platform === "win32",
});
if (error) {
  console.error(error.message);
  process.exit(1);
}
process.exit(status ?? 1);
