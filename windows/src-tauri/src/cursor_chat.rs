// Chat through the Cursor CLI (`agent`), on the user's own Cursor plan.
//
// Cursor has no public chat API, and calling its private endpoints breaks its
// terms. The CLI is the supported way: `agent login` once in a browser, then
// headless `agent -p` runs. It always runs Cursor's agent harness, so it is
// slower than a raw model call; `--mode ask` keeps it read-only.
//
// The conversation lives in the CLI: `--resume <id>` continues the session this
// module stores on the shared Chat (cli_sessions), so history never crosses
// into another provider's wire format.

use std::process::Stdio;

use serde::Deserialize;

use crate::chat::ChatContext;
use crate::cli_chat::{self, CliStatus};
use crate::{platform, secrets};

pub const DEFAULT_MODEL: &str = "auto";

#[derive(Deserialize)]
struct CliResult {
    #[serde(default)]
    is_error: bool,
    #[serde(default)]
    result: String,
    session_id: Option<String>,
}

fn cli_path() -> Option<std::path::PathBuf> {
    cli_chat::find_cli(&["agent", "cursor-agent"])
}

/// One chat turn. `first` starts a fresh conversation (system prompt and the
/// file or window context ride along); `session` is the id `--resume` picks up.
/// Answers with the reply text and the session id to resume, when the CLI
/// gave one.
pub async fn send(
    model: String,
    system_prompt: &str,
    first: bool,
    session: Option<String>,
    query: String,
    context: Option<ChatContext>,
) -> Result<(String, Option<String>), String> {
    let cli = cli_path().ok_or("Cursor CLI not found. Install it, then run `agent login`.")?;
    let prompt =
        cli_chat::build_prompt(&system_prompt, first && session.is_none(), context.as_ref(), &query, "Cursor")?;

    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(cli_chat::workdir("cursor-chat")?)
        .args(["-p", "--output-format", "json", "--mode", "ask", "--trust"]);
    if !model.is_empty() {
        cmd.args(["--model", &model]);
    }
    if let Some(id) = session {
        cmd.args(["--resume", &id]);
    }
    // The key goes through the environment, never argv: other users can read
    // argv in `ps`. Without it the CLI uses the `agent login` session — the plan.
    if let Some(key) = secrets::get("cursor-api-key") {
        cmd.env("CURSOR_API_KEY", key);
    }
    // `--` so a message starting with "-" is never read as an option.
    cmd.arg("--").arg(prompt);

    let out = cli_chat::run(cmd, "the Cursor CLI").await?;
    parse_result(&out.stdout, &out.stderr)
}

/// (answer, session id) from the CLI's JSON, or the CLI's own error message.
fn parse_result(stdout: &[u8], stderr: &[u8]) -> Result<(String, Option<String>), String> {
    let stdout = String::from_utf8_lossy(stdout);
    let last = stdout.lines().rev().find(|l| l.trim_start().starts_with('{'));
    if let Some(r) = last.and_then(|l| serde_json::from_str::<CliResult>(l).ok()) {
        let text = r.result.trim().to_string();
        if r.is_error {
            return Err(if text.is_empty() { "Cursor returned an error.".into() } else { text });
        }
        if text.is_empty() {
            return Err("No response text.".into());
        }
        return Ok((text, r.session_id));
    }
    let stderr = String::from_utf8_lossy(stderr);
    let msg = [stderr.trim(), stdout.trim()]
        .into_iter()
        .find(|s| !s.is_empty())
        .unwrap_or("Cursor CLI failed.");
    Err(msg.chars().take(300).collect())
}

/// Whether the CLI is installed and signed in, for the settings window.
pub async fn status() -> CliStatus {
    let Some(cli) = cli_path() else { return CliStatus::missing() };
    let mut cmd = cli_chat::command(&cli);
    cmd.arg("status");
    let text = match cli_chat::run(cmd, "the Cursor CLI").await {
        Ok(out) => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        Err(err) => err,
    };
    let text = cli_chat::strip_ansi(&text);
    let logged_in = text.to_lowercase().contains("logged in as");
    CliStatus::found(&cli, text, logged_in)
}

/// Opens the browser sign-in. Returns at once; the settings window polls status.
pub fn login() -> Result<(), String> {
    let cli = cli_path().ok_or("Cursor CLI not found.")?;
    let mut cmd = std::process::Command::new(cli);
    cmd.arg("login").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    platform::no_console(&mut cmd).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// (id, label) pairs from `agent models`.
pub async fn models() -> Vec<(String, String)> {
    let Some(cli) = cli_path() else { return Vec::new() };
    let mut cmd = cli_chat::command(&cli);
    cmd.arg("models");
    match cli_chat::run(cmd, "the Cursor CLI").await {
        Ok(out) => parse_models(&cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stdout))),
        Err(_) => Vec::new(),
    }
}

fn parse_models(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| l.trim().split_once(" - "))
        .filter(|(id, _)| !id.is_empty() && !id.contains(' '))
        .map(|(id, label)| (id.to_string(), label.trim().to_string()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_answer_and_session_from_the_cli_json() {
        let ok = br#"{"type":"result","subtype":"success","is_error":false,"result":"oi","session_id":"abc"}"#;
        assert_eq!(parse_result(ok, b""), Ok(("oi".into(), Some("abc".into()))));

        let failed = br#"{"type":"result","is_error":true,"result":"quota exceeded"}"#;
        assert_eq!(parse_result(failed, b""), Err("quota exceeded".into()));

        // Not JSON at all: the CLI's own message is what the user needs.
        assert_eq!(
            parse_result(b"Cannot use this model: x.\n", b""),
            Err("Cannot use this model: x.".into())
        );
        assert_eq!(parse_result(b"", b"Not authenticated\n"), Err("Not authenticated".into()));
    }

    #[test]
    fn lists_models_and_skips_headers() {
        let text = "Available models\n\nauto - Auto (current, default)\ncomposer-2.5 - Composer 2.5\n";
        assert_eq!(
            parse_models(text),
            vec![
                ("auto".into(), "Auto (current, default)".into()),
                ("composer-2.5".into(), "Composer 2.5".into()),
            ]
        );
    }
}
