// Chat through the Kiro CLI (`kiro-cli`), on the user's own Kiro plan.
//
// Like the Cursor CLI: `kiro-cli login` once, then headless
// `kiro-cli chat --no-interactive` runs. `--trust-tools=` trusts no tool, so
// the agent can only answer.
//
// The text output is used, not `--output-format stream-json`: that one needs
// the v2 engine, which does not resume conversations yet. On the v1 engine
// `--resume` picks the folder's latest conversation, so the chat runs in a
// private folder of its own and a reset just skips `--resume` once.

use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde::Deserialize;
use tokio::process::Command;

use crate::claude::{ChatContext, ChatReply};
use crate::cursor_chat::{build_prompt, find_cli, strip_ansi, CursorStatus};
use crate::platform;

pub const DEFAULT_MODEL: &str = "auto";
const TIMEOUT: Duration = Duration::from_secs(120);

/// Whether the folder's latest conversation is this chat's.
#[derive(Default)]
pub struct KiroChat {
    started: Mutex<bool>,
}

impl KiroChat {
    pub fn reset(&self) {
        *self.started.lock().unwrap() = false;
    }
}

fn cli_path() -> Option<std::path::PathBuf> {
    find_cli(&["kiro-cli"])
}

fn workdir() -> Result<std::path::PathBuf, String> {
    let dir = crate::settings::local_dir().join("kiro-chat");
    platform::ensure_private_dir(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn command(cli: &std::path::Path) -> Command {
    let mut cmd = Command::new(cli);
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

async fn run(mut cmd: Command) -> Result<std::process::Output, String> {
    let child = cmd.spawn().map_err(|e| format!("Could not start the Kiro CLI: {e}"))?;
    match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Ok(out) => out.map_err(|e| e.to_string()),
        Err(_) => Err("Kiro took too long to answer.".into()),
    }
}

/// One chat turn.
pub async fn send(
    chat: &KiroChat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let cli = cli_path().ok_or("Kiro CLI not found. Install it, then run `kiro-cli login`.")?;
    let started = *chat.started.lock().unwrap();
    let prompt = build_prompt(!started, context, &query, "Kiro")?;

    let mut cmd = command(&cli);
    cmd.current_dir(workdir()?).args([
        "chat", "--agent-engine", "v1", "--no-interactive", "--trust-tools=", "--wrap", "never",
        "--model", model,
    ]);
    if started {
        cmd.arg("--resume");
    }
    // `--` so a message starting with "-" is never read as an option.
    cmd.arg("--").arg(prompt);

    let out = run(cmd).await?;
    let text = parse_answer(out.status.success(), &out.stdout, &out.stderr)?;
    *chat.started.lock().unwrap() = true;
    Ok(ChatReply { text })
}

/// The answer from stdout, or the CLI's `error: …` line.
fn parse_answer(ok: bool, stdout: &[u8], stderr: &[u8]) -> Result<String, String> {
    if ok {
        let text = strip_ansi(&String::from_utf8_lossy(stdout));
        let text = text.trim_start();
        let text = text.strip_prefix('>').unwrap_or(text).trim();
        return if text.is_empty() { Err("No response text.".into()) } else { Ok(text.to_string()) };
    }
    let stderr = strip_ansi(&String::from_utf8_lossy(stderr));
    let msg = stderr
        .lines()
        .find_map(|l| l.trim().strip_prefix("error:"))
        .or_else(|| stderr.lines().map(str::trim).filter(|l| !l.is_empty()).last())
        .unwrap_or("Kiro CLI failed.");
    Err(msg.trim().chars().take(300).collect())
}

/// Whether the CLI is installed and signed in, for the settings window.
pub async fn status() -> CursorStatus {
    let Some(cli) = cli_path() else {
        return CursorStatus { cli: None, status: String::new(), logged_in: false };
    };
    let mut cmd = command(&cli);
    cmd.arg("whoami");
    let (logged_in, text) = match run(cmd).await {
        Ok(out) => (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string()),
        Err(err) => (false, err),
    };
    let first = strip_ansi(&text).lines().next().unwrap_or("").trim().to_string();
    CursorStatus { logged_in, status: first, cli: Some(cli.to_string_lossy().to_string()) }
}

#[derive(Deserialize)]
struct ModelList {
    models: Vec<Model>,
}

#[derive(Deserialize)]
struct Model {
    model_id: String,
    model_name: String,
}

/// (id, label) pairs from `kiro-cli chat --list-models`.
pub async fn models() -> Vec<(String, String)> {
    let Some(cli) = cli_path() else { return Vec::new() };
    let mut cmd = command(&cli);
    cmd.args(["chat", "--list-models", "--format", "json"]);
    match run(cmd).await {
        Ok(out) => parse_models(&out.stdout),
        Err(_) => Vec::new(),
    }
}

fn parse_models(json: &[u8]) -> Vec<(String, String)> {
    serde_json::from_slice::<ModelList>(json)
        .map(|l| l.models.into_iter().map(|m| (m.model_id, m.model_name)).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_answer_or_the_cli_error() {
        let ok = b"\x1b[m> \x1b[0m\x1b[1m## Fruits\x1b[0m\n\n- Apple\x1b[0m";
        assert_eq!(parse_answer(true, ok, b""), Ok("## Fruits\n\n- Apple".into()));
        assert_eq!(parse_answer(true, b"\x1b[m> \x1b[0m", b""), Err("No response text.".into()));

        let err = b"\x1b[mWARNING: \x1b[0m--trust-tools arg\nerror: Model 'x' does not exist.\n";
        assert_eq!(parse_answer(false, b"", err), Err("Model 'x' does not exist.".into()));
        assert_eq!(parse_answer(false, b"", b"Not logged in\n"), Err("Not logged in".into()));
    }

    #[test]
    fn lists_models_from_the_cli_json() {
        let json = br#"{"models":[{"model_name":"auto","description":"x","model_id":"auto"},
            {"model_name":"claude-sonnet-5","model_id":"claude-sonnet-5","rate_multiplier":1.3}]}"#;
        assert_eq!(
            parse_models(json),
            vec![("auto".into(), "auto".into()), ("claude-sonnet-5".into(), "claude-sonnet-5".into())]
        );
        assert!(parse_models(b"not json").is_empty());
    }
}
