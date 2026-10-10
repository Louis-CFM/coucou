// Chat without an API key: ask Claude Code itself (`claude -p`).
//
// It runs on the user's own Claude Code login, so the island's chat works for
// anyone who has Claude Code, key or not. Read, WebSearch and WebFetch are
// pre-approved so it never stops on a permission prompt — and it cannot run
// anything else.
//
// Two walls keep a chat turn from looking like a session in the island:
// `--setting-sources project` keeps the user's settings — and with them the
// Coucou hook — out of the process, and it runs in a private empty folder of
// our own instead of any project.

use std::process::Stdio;

use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::chat::{self, ChatContext};
use crate::cli_chat::{self, CliStatus};

/// The launcher's names, in the order found (`claude.exe` is the native
/// install, `claude.cmd` the npm one — Rust quotes it safely since 1.77).
const NAMES: &[&str] = &["claude", "claude-code"];

fn cli_path() -> Option<std::path::PathBuf> {
    cli_chat::find_cli(NAMES)
}

/// One chat turn. `first` starts a fresh conversation; `session` is the id
/// `--resume` picks up. The answer comes back with the session id to resume.
///
/// Unlike the other CLI providers the system prompt is not part of the
/// message: it goes out through `--append-system-prompt`, so the resumed
//  conversation does not carry it in a turn a user could read back.
pub async fn send(
    model: String,
    first: bool,
    session: Option<String>,
    query: String,
    context: Option<ChatContext>,
) -> Result<(String, Option<String>), String> {
    let cli = cli_path().ok_or(
        "Claude Code not found. Install it, or add an API key in Settings to chat through the API.",
    )?;

    // The file or window rides along with the first message only.
    let mut prompt = String::new();
    if first && session.is_none() {
        match context.as_ref() {
            Some(ChatContext::File { name, path }) => {
                let text = std::fs::metadata(path)
                    .ok()
                    .filter(|m| m.len() <= 200_000)
                    .and_then(|_| std::fs::read_to_string(path).ok())
                    .ok_or("Only text files can be sent for now.")?;
                prompt.push_str(&format!("File: {name}\nFile contents:\n{text}\n\n"));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                prompt.push_str(&chat::window_line(app_name, title, url.as_deref()));
                prompt.push_str("\n\n");
            }
            None => {}
        }
    }
    prompt.push_str(&query);

    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(cli_chat::workdir("claude-chat")?)
        .args(["-p", "--output-format", "json", "--setting-sources", "project"])
        .args(["--allowedTools", "Read", "WebSearch", "WebFetch"])
        .args(["--append-system-prompt", &chat::system_prompt(true)]);
    if !model.is_empty() {
        cmd.args(["--model", &model]);
    }
    if let Some(id) = session {
        cmd.args(["--resume", &id]);
    }
    // The prompt goes in on stdin: the option list above would swallow it.
    cmd.stdin(Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("Could not start Claude Code: {e}"))?;
    child
        .stdin
        .take()
        .expect("stdin is piped")
        .write_all(prompt.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let out = match tokio::time::timeout(cli_chat::TIMEOUT, child.wait_with_output()).await {
        Ok(out) => out.map_err(|e| e.to_string())?,
        Err(_) => return Err("Claude Code took too long to answer.".into()),
    };

    parse_result(&out.stdout, &out.stderr, out.status.success())
}

/// (answer, session id) from the CLI's JSON, or its own error line.
fn parse_result(stdout: &[u8], stderr: &[u8], ok: bool) -> Result<(String, Option<String>), String> {
    let reply: Value = serde_json::from_slice(stdout).unwrap_or(Value::Null);
    let text = reply.get("result").and_then(Value::as_str).unwrap_or("").trim();
    if !ok || reply.get("is_error") == Some(&Value::Bool(true)) || text.is_empty() {
        let stderr = cli_chat::strip_ansi(&String::from_utf8_lossy(stderr));
        let why = if !text.is_empty() { text } else { stderr.lines().next().unwrap_or("No response.") };
        return Err(format!("Claude Code: {}", why.chars().take(300).collect::<String>()));
    }
    let session = reply.get("session_id").and_then(Value::as_str).map(str::to_string);
    Ok((text.to_string(), session))
}

/// Whether the CLI is installed and signed in, for the settings window.
/// `claude` has no status command: the version proves it runs, and a saved
/// login lives in ~/.claude/.credentials.json — only its existence is read.
pub async fn status() -> CliStatus {
    let Some(cli) = cli_path() else { return CliStatus::missing() };
    let mut cmd = cli_chat::command(&cli);
    cmd.arg("--version");
    let version = match cli_chat::run(cmd, "Claude Code").await {
        Ok(out) => cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stdout))
            .lines()
            .next()
            .unwrap_or("")
            .trim()
            .to_string(),
        Err(err) => err,
    };
    let creds = crate::platform::home_dir().join(".claude").join(".credentials.json");
    CliStatus::found(&cli, version, creds.is_file())
}

/// `claude -p` has no `--list-models`: the aliases it accepts, plus "" — the
/// user's own configured model — for the picker.
pub fn models() -> Vec<(String, String)> {
    vec![
        (String::new(), "Default".into()),
        ("sonnet".into(), "Sonnet".into()),
        ("opus".into(), "Opus".into()),
        ("haiku".into(), "Haiku".into()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_answer_and_session_from_the_cli_json() {
        let ok = br#"{"is_error":false,"result":"oi","session_id":"abc"}"#;
        assert_eq!(parse_result(ok, b"", true), Ok(("oi".into(), Some("abc".into()))));

        let failed = br#"{"is_error":true,"result":"quota exceeded"}"#;
        assert_eq!(parse_result(failed, b"", false), Err("Claude Code: quota exceeded".into()));
        assert_eq!(parse_result(b"", b"not logged in\n", false), Err("Claude Code: not logged in".into()));
        assert_eq!(parse_result(b"{}", b"", true), Err("Claude Code: No response.".into()));
    }
}
