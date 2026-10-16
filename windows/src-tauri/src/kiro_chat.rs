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

use serde::Deserialize;

use crate::chat::ChatContext;
use crate::cli_chat::{self, CliStatus};

pub const DEFAULT_MODEL: &str = "auto";

fn cli_path() -> Option<std::path::PathBuf> {
    cli_chat::find_cli(&["kiro-cli"])
}

/// One chat turn. `started` is whether this chat already owns the private
/// folder's latest conversation — it decides whether `--resume` goes out.
/// Answers with the reply text and "-" once the folder's conversation is ours
/// (the "session" the shared Chat stores is only this marker).
pub async fn send(
    model: String,
    system_prompt: String,
    started: bool,
    query: String,
    context: Option<ChatContext>,
) -> Result<(String, Option<String>), String> {
    let cli = cli_path().ok_or("Kiro CLI not found. Install it, then run `kiro-cli login`.")?;
    let prompt = cli_chat::build_prompt(&system_prompt, !started, context.as_ref(), &query, "Kiro")?;

    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(cli_chat::workdir("kiro-chat")?).args([
        "chat", "--agent-engine", "v1", "--no-interactive", "--trust-tools=", "--wrap", "never",
    ]);
    if !model.is_empty() {
        cmd.args(["--model", &model]);
    }
    if started {
        cmd.arg("--resume");
    }
    // `--` so a message starting with "-" is never read as an option.
    cmd.arg("--").arg(prompt);

    let out = cli_chat::run(cmd, "the Kiro CLI").await?;
    let text = parse_answer(out.status.success(), &out.stdout, &out.stderr)?;
    Ok((text, Some("-".into())))
}

/// The answer from stdout, or the CLI's `error: …` line.
fn parse_answer(ok: bool, stdout: &[u8], stderr: &[u8]) -> Result<String, String> {
    if ok {
        let text = cli_chat::strip_ansi(&String::from_utf8_lossy(stdout));
        let text = text.trim_start();
        let text = text.strip_prefix('>').unwrap_or(text).trim();
        return if text.is_empty() { Err("No response text.".into()) } else { Ok(text.to_string()) };
    }
    let stderr = cli_chat::strip_ansi(&String::from_utf8_lossy(stderr));
    let msg = stderr
        .lines()
        .find_map(|l| l.trim().strip_prefix("error:"))
        .or_else(|| stderr.lines().map(str::trim).rfind(|l| !l.is_empty()))
        .unwrap_or("Kiro CLI failed.");
    Err(msg.trim().chars().take(300).collect())
}

/// Whether the CLI is installed and signed in, for the settings window.
pub async fn status() -> CliStatus {
    let Some(cli) = cli_path() else { return CliStatus::missing() };
    let mut cmd = cli_chat::command(&cli);
    cmd.arg("whoami");
    let (logged_in, text) = match cli_chat::run(cmd, "the Kiro CLI").await {
        Ok(out) => (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string()),
        Err(err) => (false, err),
    };
    let first = cli_chat::strip_ansi(&text).lines().next().unwrap_or("").trim().to_string();
    CliStatus::found(&cli, first, logged_in)
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
    let mut cmd = cli_chat::command(&cli);
    cmd.args(["chat", "--list-models", "--format", "json"]);
    match cli_chat::run(cmd, "the Kiro CLI").await {
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
