// "Claude (your plan)": the chat through the Claude Code CLI on this PC, so a
// Pro or Max subscription answers instead of an API key.
//
// Each turn runs `claude -p` with the conversation so far on stdin and reads
// its stream-json output, forwarding the text as it is written. The CLI runs
// without tools (it answers, it never acts on the PC), without the user's
// settings (so Coucou's own hooks don't report the chat as an agent session),
// without MCP servers and without saving a session, in a folder of its own.

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::i18n::t;
use crate::island::WINDOW_LABEL;

pub const ID: &str = "claudecode";
pub const DEFAULT_MODEL: &str = "sonnet";

pub fn models() -> Vec<ModelInfo> {
    [("sonnet", "Claude Sonnet"), ("opus", "Claude Opus"), ("haiku", "Claude Haiku")]
        .iter()
        .map(|(id, label)| ModelInfo { id: id.to_string(), label: label.to_string() })
        .collect()
}

fn cli() -> Option<std::path::PathBuf> {
    crate::platform::find_on_path("claude").or_else(|| {
        let p = crate::platform::home_dir().join(".local").join("bin").join(if cfg!(windows) { "claude.exe" } else { "claude" });
        p.is_file().then_some(p)
    })
}

/// The whole conversation as one prompt: the CLI keeps no session between turns.
pub fn prompt(history: &[Value], question: &str) -> String {
    let mut out = String::new();
    for m in history {
        let who = if m["role"] == "assistant" { "Mochi" } else { "User" };
        if let Some(text) = m["content"].as_str() {
            out.push_str(&format!("{who}: {text}\n\n"));
        }
    }
    if out.is_empty() {
        question.to_string()
    } else {
        format!("The conversation so far:\n\n{out}User: {question}")
    }
}

/// One line of stream-json: a text delta, the final result, or nothing.
pub enum Line {
    Delta(String),
    Done { text: String, error: bool },
}

pub fn parse_line(line: &str) -> Option<Line> {
    let j: Value = serde_json::from_str(line).ok()?;
    match j["type"].as_str()? {
        "stream_event" => {
            let e = &j["event"];
            (e["type"] == "content_block_delta" && e["delta"]["type"] == "text_delta")
                .then(|| Line::Delta(e["delta"]["text"].as_str().unwrap_or_default().to_string()))
        }
        "result" => Some(Line::Done {
            text: j["result"].as_str().unwrap_or_default().to_string(),
            error: j["is_error"].as_bool().unwrap_or(false),
        }),
        _ => None,
    }
}

pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let Some(exe) = cli() else {
        return Err(t("Claude Code isn't installed. Install it from claude.com/code, run `claude` once and log in with your Claude account."));
    };
    let turn = chat.begin(ID);
    let question = crate::local_chat::user_text(turn.first, context.as_ref(), &query);
    let input = prompt(&turn.history, &question);
    let model = if model.is_empty() { DEFAULT_MODEL.to_string() } else { model.to_string() };
    let system = chat::system_prompt(false);
    let app2 = app.clone();

    let answer = tauri::async_runtime::spawn_blocking(move || -> Result<String, String> {
        let dir = std::env::temp_dir().join("coucou-chat");
        let _ = std::fs::create_dir_all(&dir);
        let mut cmd = Command::new(exe);
        cmd.args([
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model",
            &model,
            "--tools",
            "",
            "--setting-sources",
            "local",
            "--strict-mcp-config",
            "--no-session-persistence",
            "--append-system-prompt",
            &system,
        ])
        .current_dir(&dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
        crate::platform::no_console(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| format!("claude: {e}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(input.as_bytes());
        }
        let stdout = child.stdout.take().ok_or("claude: no output")?;
        let mut text = String::new();
        let mut last_emit = std::time::Instant::now();
        let mut done: Option<(String, bool)> = None;
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            match parse_line(&line) {
                Some(Line::Delta(d)) => {
                    text.push_str(&d);
                    // At most ~15 repaints a second, like the other providers.
                    if last_emit.elapsed().as_millis() >= 66 {
                        last_emit = std::time::Instant::now();
                        let _ = app2.emit_to(WINDOW_LABEL, "chat-delta", text.clone());
                    }
                }
                Some(Line::Done { text: r, error }) => done = Some((r, error)),
                None => {}
            }
        }
        let _ = child.wait();
        match done {
            Some((r, true)) if r.contains("/login") || r.to_lowercase().contains("not logged in") => {
                Err(t("Claude Code isn't logged in. Open a terminal, run `claude`, then type /login and sign in with your Claude account."))
            }
            Some((r, true)) => Err(r),
            Some((r, false)) if !r.is_empty() => Ok(r),
            _ if !text.is_empty() => Ok(text),
            _ => Err(t("No response text.")),
        }
    })
    .await
    .map_err(|e| e.to_string())??;

    let _ = app.emit_to(WINDOW_LABEL, "chat-delta", answer.clone());
    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(&turn, json!({ "role": "user", "content": question }), json!({ "role": "assistant", "content": answer }), &plain, &answer);
    Ok(ChatReply { text: answer })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deltas_and_the_result_are_read_from_stream_json() {
        let d = r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}}"#;
        assert!(matches!(parse_line(d), Some(Line::Delta(t)) if t == "Hi"));
        let r = r#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#;
        assert!(matches!(parse_line(r), Some(Line::Done { error: true, .. })));
        assert!(parse_line(r#"{"type":"system","subtype":"init"}"#).is_none());
        assert!(parse_line("not json").is_none());
    }

    #[test]
    fn the_history_rides_in_the_prompt() {
        assert_eq!(prompt(&[], "hi"), "hi");
        let h = [json!({"role":"user","content":"a"}), json!({"role":"assistant","content":"b"})];
        assert_eq!(prompt(&h, "c"), "The conversation so far:\n\nUser: a\n\nMochi: b\n\nUser: c");
    }
}
