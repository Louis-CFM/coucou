// Builds coucou-hook into target/release. On Linux it is linked statically, so
// the same binary also runs on a remote host with an older glibc (remote agents).
import { execFileSync } from "node:child_process";
import { copyFileSync } from "node:fs";
import { join } from "node:path";

const cargo = (args, env = process.env) => execFileSync("cargo", args, { stdio: "inherit", env });

if (process.platform !== "linux") {
  cargo(["build", "--release", "-p", "coucou-hook"]);
  process.exit(0);
}

// With an explicit --target, RUSTFLAGS reach only the hook, not build scripts or proc macros.
const host = execFileSync("rustc", ["-vV"]).toString().match(/^host: (.+)$/m)[1];
const env = { ...process.env, RUSTFLAGS: `${process.env.RUSTFLAGS ?? ""} -C target-feature=+crt-static`.trim() };
cargo(["build", "--release", "-p", "coucou-hook", "--target", host], env);

const dir = process.env.CARGO_TARGET_DIR ?? "target";
copyFileSync(join(dir, host, "release", "coucou-hook"), join(dir, "release", "coucou-hook"));
