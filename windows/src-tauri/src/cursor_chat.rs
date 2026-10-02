// Chat through the Cursor CLI (`agent`), on the user's own Cursor plan.
//
// Cursor has no public chat API, and calling its private endpoints breaks its
// terms. The CLI is the supported way: `agent login` once in a browser, then
// headless `agent -p` runs. It always runs Cursor's agent harness, so it is
// slower than a raw model call; `--mode ask` keeps it read-only.
//
// Runs in a private, empty folder so the agent has nothing of the user's to
// read, and the same folder every time because `--resume` is scoped to it.

use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::claude::{ChatContext, ChatReply, SYSTEM_PROMPT};
use crate::{platform, secrets};

pub const DEFAULT_MODEL: &str = "auto";
const TIMEOUT: Duration = Duration::from_secs(120);
const MAX_INLINE_TEXT: u64 = 200_000;

/// The CLI session the next turn resumes; None until the first answer.
#[derive(Default)]
pub struct CursorChat {
    session: Mutex<Option<String>>,
}

impl CursorChat {
    pub fn reset(&self) {
        *self.session.lock().unwrap() = None;
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorStatus {
    /// Path of the CLI, or None when it is not installed.
    pub cli: Option<String>,
    /// What `agent status` says, e.g. "Logged in as …".
    pub status: String,
    pub logged_in: bool,
}

#[derive(Deserialize)]
struct CliResult {
    #[serde(default)]
    is_error: bool,
    #[serde(default)]
    result: String,
    session_id: Option<String>,
}

fn cli_path() -> Option<std::path::PathBuf> {
    platform::find_on_path("agent").or_else(|| platform::find_on_path("cursor-agent"))
}

fn workdir() -> Result<std::path::PathBuf, String> {
    let dir = crate::settings::local_dir().join("cursor-chat");
    platform::ensure_private_dir(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn command(cli: &std::path::Path) -> Command {
    let mut cmd = Command::new(cli);
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    // Through the environment, never argv: other users can read argv in `ps`.
    // Without a key the CLI uses the `agent login` session, i.e. the plan.
    if let Some(key) = secrets::get("cursor-api-key") {
        cmd.env("CURSOR_API_KEY", key);
    }
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

async fn run(mut cmd: Command) -> Result<std::process::Output, String> {
    let child = cmd.spawn().map_err(|e| format!("Could not start the Cursor CLI: {e}"))?;
    match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Ok(out) => out.map_err(|e| e.to_string()),
        Err(_) => Err("Cursor took too long to answer.".into()),
    }
}

/// One chat turn.
pub async fn send(
    chat: &CursorChat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let cli = cli_path().ok_or("Cursor CLI not found. Install it, then run `agent login`.")?;
    let session = chat.session.lock().unwrap().clone();

    let mut prompt = String::new();
    if session.is_none() {
        prompt.push_str(SYSTEM_PROMPT);
        prompt.push_str("\n\n");
        match &context {
            Some(ChatContext::File { name, path }) => {
                let text = inline_text(path)
                    .ok_or("Only text files can be sent to Cursor for now.")?;
                prompt.push_str(&format!("File: {name}\nFile contents:\n{text}\n\n"));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                prompt.push_str(&format!("Context — App: {app_name}, Window: {title}"));
                if let Some(url) = url {
                    prompt.push_str(&format!(", URL: {url}"));
                }
                prompt.push_str("\n\n");
            }
            None => {}
        }
    }
    prompt.push_str(&query);

    let mut cmd = command(&cli);
    cmd.current_dir(workdir()?)
        .args(["-p", "--output-format", "json", "--mode", "ask", "--trust", "--model", model]);
    if let Some(id) = &session {
        cmd.args(["--resume", id]);
    }
    // `--` so a message starting with "-" is never read as an option.
    cmd.arg("--").arg(prompt);

    let out = run(cmd).await?;
    let parsed = parse_result(&out.stdout, &out.stderr)?;
    if let Some(id) = parsed.1 {
        *chat.session.lock().unwrap() = Some(id);
    }
    Ok(ChatReply { text: parsed.0 })
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
    let msg = [stderr.trim(), stdout.trim()].into_iter().find(|s| !s.is_empty()).unwrap_or("Cursor CLI failed.");
    Err(msg.chars().take(300).collect())
}

fn inline_text(path: &str) -> Option<String> {
    if std::fs::metadata(path).ok()?.len() > MAX_INLINE_TEXT {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

/// Whether the CLI is installed and signed in, for the settings window.
pub async fn status() -> CursorStatus {
    let Some(cli) = cli_path() else {
        return CursorStatus { cli: None, status: String::new(), logged_in: false };
    };
    let mut cmd = command(&cli);
    cmd.arg("status");
    let text = match run(cmd).await {
        Ok(out) => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        Err(err) => err,
    };
    let text = strip_ansi(&text);
    CursorStatus {
        logged_in: text.to_lowercase().contains("logged in as"),
        status: text,
        cli: Some(cli.to_string_lossy().to_string()),
    }
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
    let mut cmd = command(&cli);
    cmd.arg("models");
    match run(cmd).await {
        Ok(out) => parse_models(&strip_ansi(&String::from_utf8_lossy(&out.stdout))),
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

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
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
        assert_eq!(strip_ansi("\u{1b}[32m✓\u{1b}[0m Logged in"), "✓ Logged in");
    }
}
