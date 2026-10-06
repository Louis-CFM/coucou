// Chat without an API key: ask Claude Code instead.
//
// `claude -p` runs on the user's own Claude Code login, so the island's chat
// works for anyone who has Claude Code, key or not. It is the fallback of
// claude.rs, not a second client: the same system prompt, the same answers.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

use serde_json::Value;

use crate::claude::{Chat, ChatContext, ChatReply, system_prompt};
use crate::platform;

/// The launcher's name on each platform (npm installs it as `claude.cmd`).
const LAUNCHERS: &[&str] = if cfg!(windows) { &["claude.exe", "claude.cmd"] } else { &["claude"] };

/// No API key: ask Claude Code instead (`claude -p`), on the user's own login.
/// Same system prompt; Read, WebSearch and WebFetch are pre-approved so it never
/// stops on a permission prompt, and `--setting-sources project` from a temp
/// directory keeps the user's hooks out, or every answer would show up in the
/// island as a session of its own.
pub async fn send(
    chat: &Chat,
    language: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let Some(exe) = LAUNCHERS.iter().find_map(|name| platform::find_on_path(name)) else {
        return Err(
            "API key missing. Open settings, or install Claude Code to use it instead.".into()
        );
    };

    let session = chat.cli_session.lock().unwrap().clone();
    let mut prompt = String::new();
    let mut add_dir = None;
    // File / window context rides along with the first message only.
    if session.is_none() {
        match &context {
            Some(ChatContext::File { name, path }) => {
                prompt.push_str(&format!("The user dropped the file \"{name}\" ({path}). Read it if the question needs it.\n\n"));
                add_dir = Path::new(path).parent().map(Path::to_path_buf);
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
    let system = system_prompt(language);

    // Known limit: there is no timeout, so a stuck `claude` keeps the island thinking.
    let out = tokio::task::spawn_blocking(move || {
        let mut cmd = Command::new(exe);
        cmd.args(["-p", "--output-format", "json", "--setting-sources", "project"])
            .args(["--allowedTools", "Read", "WebSearch", "WebFetch"])
            .args(["--append-system-prompt", &system]);
        if let Some(id) = &session {
            cmd.args(["--resume", id]);
        }
        if let Some(dir) = &add_dir {
            cmd.arg("--add-dir").arg(dir);
        }
        // The prompt goes in on stdin: the options above take lists and would swallow it.
        let mut child = platform::no_console(&mut cmd)
            .current_dir(std::env::temp_dir())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        child.stdin.take().expect("piped").write_all(prompt.as_bytes())?;
        child.wait_with_output()
    })
    .await
    .map_err(|e| e.to_string())?
    .map_err(|e| format!("Could not start Claude Code: {e}"))?;

    let reply: Value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    let text = reply.get("result").and_then(Value::as_str).unwrap_or("").trim();
    if !out.status.success() || reply.get("is_error") == Some(&Value::Bool(true)) || text.is_empty()
    {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let why =
            if !text.is_empty() { text } else { stderr.lines().next().unwrap_or("No response.") };
        return Err(format!("Claude Code: {why}"));
    }
    if let Some(id) = reply.get("session_id").and_then(Value::as_str) {
        *chat.cli_session.lock().unwrap() = Some(id.to_string());
    }
    Ok(ChatReply { text: text.to_string() })
}
