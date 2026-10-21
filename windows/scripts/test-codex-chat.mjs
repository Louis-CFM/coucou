// Run the real stdio transport tests without linking Tauri or speech libraries.
// Uses only serde_json, already an application dependency. No login or inference.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const windows = resolve(fileURLToPath(new URL("..", import.meta.url)));
const dir = join(windows, "target/codex-chat-tests");
mkdirSync(join(dir, "src"), { recursive: true });
writeFileSync(join(dir, "Cargo.toml"), `[package]\nname = "coucou-codex-protocol-tests"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\n[dependencies]\nserde_json = { version = "1", features = ["preserve_order"] }\n`);
writeFileSync(join(dir, "Cargo.lock"), readFileSync(join(windows, "Cargo.lock")));
const protocol = JSON.stringify(join(windows, "src-tauri/src/codex_chat/protocol.rs"));
writeFileSync(join(dir, "src/lib.rs"), `
#[allow(dead_code)]
mod platform {
    pub fn ensure_private_dir(dir: &std::path::Path) -> std::io::Result<()> {
        std::fs::create_dir_all(dir)
    }
    pub fn no_console(cmd: &mut std::process::Command) -> &mut std::process::Command {
        #[cfg(windows)] {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x08000000);
        }
        cmd
    }
}
#[allow(dead_code)]
mod codex_chat {
    #[path = ${protocol}]
    mod protocol;
}
`);
const smoke = process.argv.includes("--smoke");
const live = process.argv.includes("--live");
if (smoke && live) throw new Error("Choose --smoke or --live, not both.");
const smokeHome = join(dir, "smoke-home");
if (smoke) {
  mkdirSync(smokeHome, { recursive: true });
  // A required, unusable extension must be disabled by the production config
  // overrides before thread creation. It cannot launch anything even on failure.
  writeFileSync(join(smokeHome, "config.toml"), '[mcp_servers."coucou.test"]\ncommand = "coucou-nonexistent-test-server"\nrequired = true\n');
}
const filter = smoke ? "installed_cli_protocol_without_inference" : "installed_cli_chatgpt_conversation";
const result = spawnSync("cargo", ["test", "--manifest-path", join(dir, "Cargo.toml"), ...(smoke || live ? [filter, "--", "--ignored"] : [])], {
  cwd: windows,
  env: { ...process.env, COUCOU_CODEX_FIXTURE: join(windows, "tests/fixtures/codex-app-server.rs"), ...(smoke ? { CODEX_HOME: smokeHome } : {}) },
  stdio: "inherit",
});
if (result.error) throw result.error;
process.exitCode = result.status ?? 1;
