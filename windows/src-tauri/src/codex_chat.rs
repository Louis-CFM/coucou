// Chat through the Codex CLI (`codex exec`), on the user's own ChatGPT sign-in.
//
// `codex exec` runs non-interactively; `-s read-only` sandboxes every command
// the model tries, so a chat turn can read but never write. `-o` writes the
// final message to a file and `--json` streams the run's events — the
// `thread.started` id is the resume token, `codex exec resume <id>` picks the
// conversation back up.
//
// Two walls keep a chat turn out of the island's own session feed: the user's
// hooks (including Coucou's) live in ~/.codex/hooks.json, so `--disable hooks`
// turns them off for the run, and it all happens in a private folder of ours.
// A failed turn still exits 0 — `turn.failed` in the event stream is the
// error, an empty -o file its symptom.

use std::process::Stdio;

use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::chat::ChatContext;
use crate::cli_chat::{self, CliStatus};

fn cli_path() -> Option<std::path::PathBuf> {
    cli_chat::find_cli(&["codex", "codex-cli"])
}

/// One chat turn. `first` starts a fresh conversation; `session` is the
/// thread id `resume` picks up ("-" falls back to the folder's latest, like
/// Kiro's). The prompt goes in on stdin — `-` says read it there — so it
/// never runs into the ~32k argv cap a file context can hit.
pub async fn send(
    model: String,
    _first: bool,
    session: Option<String>,
    query: String,
    context: Option<ChatContext>,
) -> Result<(String, Option<String>), String> {
    let cli =
        cli_path().ok_or("Codex CLI not found. Install it, then run `codex login`.")?;
    let prompt = cli_chat::build_prompt(session.is_none(), context.as_ref(), &query, "Codex", true)?;

    let dir = cli_chat::workdir("codex-chat")?;
    let last_file = dir.join("last.txt");
    let _ = std::fs::remove_file(&last_file);

    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args([
        "exec",
        "--disable",
        "hooks",
        "-s",
        "read-only",
        "-C",
        &dir.to_string_lossy(),
        "--skip-git-repo-check",
        "--color",
        "never",
        "--json",
        "-o",
        &last_file.to_string_lossy(),
    ]);
    if !model.is_empty() {
        cmd.args(["-m", &model]);
    }
    match session.as_deref() {
        Some("-") => cmd.args(["resume", "--last"]),
        Some(id) => cmd.args(["resume", id]),
        None => &mut cmd,
    };
    // `-` reads the prompt from stdin, and it can never be read as an option.
    cmd.arg("-").stdin(Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("Could not start the Codex CLI: {e}"))?;
    child
        .stdin
        .take()
        .expect("stdin is piped")
        .write_all(prompt.as_bytes())
        .await
        .map_err(|e| e.to_string())?;
    let out = match tokio::time::timeout(cli_chat::TIMEOUT, child.wait_with_output()).await {
        Ok(out) => out.map_err(|e| e.to_string())?,
        Err(_) => return Err("ChatGPT took too long to answer.".into()),
    };

    let text = std::fs::read_to_string(&last_file).unwrap_or_default();
    let _ = std::fs::remove_file(&last_file);
    parse_result(&out.stdout, &out.stderr, &text)
}

/// (answer, thread id) from the run. The `-o` file is the answer; the event
/// stream supplies the thread id and, on a failed turn, the error message.
fn parse_result(
    stdout: &[u8],
    stderr: &[u8],
    last_message: &str,
) -> Result<(String, Option<String>), String> {
    let mut thread = None;
    let mut failure = None;
    for line in String::from_utf8_lossy(stdout).lines() {
        let Ok(ev) = serde_json::from_str::<Value>(line) else { continue };
        match ev.get("type").and_then(Value::as_str) {
            Some("thread.started") => {
                thread = ev.get("thread_id").and_then(Value::as_str).map(str::to_string)
            }
            Some("turn.failed") => {
                failure = ev
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            }
            Some("error") => {
                failure = ev.get("message").and_then(Value::as_str).map(str::to_string)
            }
            _ => {}
        }
    }
    let text = last_message.trim();
    if !text.is_empty() {
        return Ok((text.to_string(), thread));
    }
    let why = failure.unwrap_or_else(|| {
        let err = cli_chat::strip_ansi(&String::from_utf8_lossy(stderr));
        err.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("No response.").to_string()
    });
    Err(format!("ChatGPT: {}", why.chars().take(300).collect::<String>()))
}

/// Whether the CLI is installed and signed in, for the settings window.
/// `codex login status` answers "Logged in using ChatGPT" — its own line is
/// the status label.
pub async fn status() -> CliStatus {
    let Some(cli) = cli_path() else { return CliStatus::missing() };
    let mut cmd = cli_chat::command(&cli);
    cmd.args(["login", "status"]);
    let (logged_in, label) = match cli_chat::run(cmd, "the Codex CLI").await {
        Ok(out) => {
            let text = cli_chat::strip_ansi(&format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            ));
            let line = text
                .lines()
                .map(str::trim)
                .find(|l| l.contains("Logged in"))
                .unwrap_or("")
                .to_string();
            (text.contains("Logged in"), if line.is_empty() { "not signed in".into() } else { line })
        }
        Err(err) => (false, err),
    };
    CliStatus::found(&cli, label, logged_in)
}

/// `codex` has no model-list command: "" keeps the user's own configured
/// model, the rest are the IDs `-m` accepts.
pub fn models() -> Vec<(String, String)> {
    vec![
        (String::new(), "Default".into()),
        ("gpt-5.6-sol".into(), "GPT-5.6 Sol".into()),
        ("gpt-5.5".into(), "GPT-5.5".into()),
        ("gpt-5.5-codex".into(), "GPT-5.5 Codex".into()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    const EVENTS: &[u8] = br#"{"type":"thread.started","thread_id":"t-1"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"hi"}}
{"type":"turn.completed","usage":{"x":1}}
"#;

    #[test]
    fn the_last_message_file_is_the_answer_and_the_thread_resumes() {
        assert_eq!(
            parse_result(EVENTS, b"", "the answer\n"),
            Ok(("the answer".into(), Some("t-1".into())))
        );
        // No thread.started → no resume token.
        assert_eq!(parse_result(b"{}", b"", "ok"), Ok(("ok".into(), None)));
    }

    #[test]
    fn a_failed_turn_reports_its_own_error_even_on_exit_zero() {
        let events = br#"{"type":"thread.started","thread_id":"t-1"}
{"type":"error","message":"usage limit, try again at 1:50 PM"}
{"type":"turn.failed","error":{"message":"usage limit, try again at 1:50 PM"}}
"#;
        assert_eq!(
            parse_result(events, b"", ""),
            Err("ChatGPT: usage limit, try again at 1:50 PM".into())
        );
        // Nothing in the stream either → stderr's first line.
        assert_eq!(parse_result(b"", b"boom\n", ""), Err("ChatGPT: boom".into()));
        assert_eq!(parse_result(b"", b"", ""), Err("ChatGPT: No response.".into()));
    }
}
