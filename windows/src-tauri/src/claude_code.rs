// Chat through the local Claude Code CLI (`claude -p`) instead of the API, so
// every turn counts against the user's Claude subscription (Pro / Max) and no
// API key is needed. Claude Code must be installed and signed in once with
// `claude` → /login.
//
// Multi-turn works through Claude Code's own sessions: the first turn returns a
// session_id, the next ones pass it back with --resume.

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::claude::{Chat, ChatContext, ChatReply, SYSTEM_PROMPT};
use crate::platform;

/// Web search plus a couple of fetches can take a while; past this, give up.
const TIMEOUT: Duration = Duration::from_secs(300);
/// Read-only tools only: Mochi can search the web and read the dropped file,
/// never run a command or touch a file.
const TOOLS: &str = "WebSearch,WebFetch,Read";

/// Where the `claude` launcher is, if anywhere.
pub fn find() -> Option<PathBuf> {
    if let Some(p) = platform::find_on_path("claude") {
        return Some(p);
    }
    // The native installer drops it in ~/.local/bin, which an app started at
    // login does not always have on its PATH yet.
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)?;
    let exe = if cfg!(windows) { "claude.exe" } else { "claude" };
    [home.join(".local").join("bin").join(exe), home.join(".claude").join("local").join(exe)]
        .into_iter()
        .find(|p| p.is_file())
}

/// Claude Code takes aliases that always point at the newest model the
/// subscription offers, so map the API model IDs from Settings onto them.
fn model_alias(model: &str) -> &str {
    for alias in ["opus", "sonnet", "haiku"] {
        if model.contains(alias) {
            return alias;
        }
    }
    model
}

/// One chat turn, same contract as claude::send.
pub async fn send(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let exe = find().ok_or_else(|| {
        "Claude Code not found. Install it, then run `claude` once to sign in.".to_string()
    })?;

    let session = chat.session_id();

    // File / window context rides along with the first message only.
    let mut prompt = String::new();
    let mut extra_dir: Option<PathBuf> = None;
    if session.is_none() {
        match &context {
            Some(ChatContext::File { name, path }) => {
                prompt.push_str(&format!(
                    "The user attached a file named \"{name}\". It is at {path} — read it with the Read tool before answering.\n\n"
                ));
                extra_dir = std::path::Path::new(path).parent().map(PathBuf::from);
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

    // Run from the inbox: no project there, so no CLAUDE.md or project
    // settings get pulled into the chat.
    let cwd = crate::files::inbox_dir();
    let _ = std::fs::create_dir_all(&cwd);

    let mut cmd = std::process::Command::new(exe);
    cmd.current_dir(&cwd)
        .args(["-p", "--output-format", "json"])
        .args(["--model", model_alias(model)])
        .args(["--system-prompt", SYSTEM_PROMPT])
        // Skip ~/.claude/settings.json: it holds Coucou's own hooks, and this
        // chat must not show up in the island as a Claude Code session.
        .args(["--setting-sources", "project"])
        .arg("--strict-mcp-config")
        .args(["--tools", TOOLS])
        .args(["--allowedTools", TOOLS])
        // An API key in the environment would take precedence over the
        // subscription login — the whole point here is to use the latter.
        .env_remove("ANTHROPIC_API_KEY");
    if let Some(dir) = extra_dir {
        cmd.arg("--add-dir").arg(dir);
    }
    if let Some(id) = &session {
        cmd.args(["--resume", id.as_str()]);
    }
    platform::no_console(&mut cmd);

    let mut cmd = tokio::process::Command::from(cmd);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = cmd.spawn().map_err(|e| format!("Could not start Claude Code: {e}"))?;
    // The prompt goes over stdin: no length limit, no quoting surprises.
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(prompt.as_bytes())
            .await
            .map_err(|e| format!("Could not talk to Claude Code: {e}"))?;
    }

    let output = tokio::time::timeout(TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| "Claude Code took too long to answer.".to_string())?
        .map_err(|e| format!("Claude Code failed: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let result = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .filter(|v| v.get("type").and_then(Value::as_str) == Some("result"));

    let Some(result) = result else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr.trim();
        let detail = if detail.is_empty() { stdout.trim() } else { detail };
        let detail: String = detail.chars().take(300).collect();
        return Err(if detail.is_empty() {
            format!("Claude Code exited with {}.", output.status)
        } else {
            format!("Claude Code: {detail}")
        });
    };

    let text = result
        .get("result")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();

    if result.get("is_error").and_then(Value::as_bool) == Some(true) {
        // Usually "please run /login" or a usage limit message — show it as is.
        return Err(if text.is_empty() { "Claude Code returned an error.".into() } else { text });
    }

    if let Some(id) = result.get("session_id").and_then(Value::as_str) {
        chat.set_session_id(id.to_string());
    }

    if text.is_empty() {
        return Err("No response text.".into());
    }
    Ok(ChatReply { text })
}

#[cfg(test)]
mod tests {
    use super::model_alias;

    #[test]
    fn api_model_ids_map_to_aliases() {
        assert_eq!(model_alias("claude-opus-5"), "opus");
        assert_eq!(model_alias("claude-sonnet-5"), "sonnet");
        assert_eq!(model_alias("claude-haiku-4-5"), "haiku");
        assert_eq!(model_alias("something-else"), "something-else");
    }
}
