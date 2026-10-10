// Claude Code as a chat provider: each turn runs the user's own `claude -p`,
// so the chat has their sign-in, MCP servers, skills, CLAUDE.md and hooks.
// Coucou holds no key and talks to nobody new.
//
// A conversation is one Claude Code session, resumed turn after turn. It runs
// in Coucou's own folder (claude-chat in the app's data) unless the user picks
// a project folder, so nothing lands in the home folder. COUCOU_CHAT=1 marks
// its hook events: the island shows its permission requests and nothing else.

use std::path::PathBuf;
use std::sync::Mutex;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::i18n::t;
use crate::island::WINDOW_LABEL;
use crate::settings::Settings;

pub const ID: &str = "claudecode";
/// No --model: whatever the user's Claude Code uses.
pub const DEFAULT_MODEL: &str = "default";
/// What `claude --model` takes as aliases (claude --help).
const MODELS: &[&str] = &["fable", "opus", "sonnet", "haiku"];
/// What `claude --effort` takes (claude --help).
pub const EFFORTS: &[&str] = &["low", "medium", "high", "xhigh", "max"];

/// Ends the turn that is running, if any (New chat).
static CANCEL: Mutex<Option<tokio::sync::oneshot::Sender<()>>> = Mutex::new(None);

pub fn models() -> Vec<ModelInfo> {
    let mut out = vec![ModelInfo { id: DEFAULT_MODEL.into(), label: t("Claude Code's default") }];
    out.extend(MODELS.iter().map(|m| ModelInfo { id: m.to_string(), label: capitalised(m) }));
    out
}

fn capitalised(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

pub fn cancel() {
    if let Some(tx) = CANCEL.lock().unwrap().take() {
        let _ = tx.send(());
    }
}

/// `claude` on PATH, or where its installers put it: a desktop launch often
/// leaves ~/.local/bin out of PATH.
fn binary() -> Option<PathBuf> {
    let home = crate::platform::home_dir();
    crate::platform::find_on_path("claude").or_else(|| {
        [home.join(".local/bin/claude"), home.join(".claude/local/claude")].into_iter().find(|p| p.is_file())
    })
}

/// The folder Claude Code works in: the one picked in Settings, else Coucou's own.
fn work_dir(settings: &Settings) -> Result<PathBuf, String> {
    let picked = settings.claude_code_dir.trim();
    if !picked.is_empty() {
        let dir = PathBuf::from(picked);
        if dir.is_absolute() && dir.is_dir() {
            return Ok(dir);
        }
        return Err(crate::i18n::tf("{path} is not a folder.", &[("path", picked)]));
    }
    let dir = crate::settings::local_dir().join("claude-chat");
    crate::platform::ensure_private_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    Ok(dir)
}

/// The arguments after `claude`. The question goes on stdin.
fn args(model: &str, effort: &str, resume: Option<&str>, extra_dir: Option<&str>) -> Vec<String> {
    let mut a: Vec<String> = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    a.extend(["--append-system-prompt".into(), chat::system_prompt(true)]);
    if model != DEFAULT_MODEL && MODELS.contains(&model) {
        a.extend(["--model".into(), model.into()]);
    }
    if EFFORTS.contains(&effort) {
        a.extend(["--effort".into(), effort.into()]);
    }
    if let Some(id) = resume {
        a.extend(["--resume".into(), id.into()]);
    }
    // A dropped file is in Coucou's inbox, outside the working folder.
    if let Some(dir) = extra_dir {
        a.extend(["--add-dir".into(), dir.into()]);
    }
    a
}

/// What one stream-json line means for the chat.
#[derive(Debug, PartialEq)]
enum Line {
    Session(String),
    /// Text to add to the answer.
    Text(String),
    /// A new text block after something else (a tool call): a paragraph break.
    Block,
    Done { error: Option<String>, result: String },
    Other,
}

fn parse(line: &str) -> Line {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return Line::Other };
    let s = |p: &str| v.pointer(p).and_then(Value::as_str);
    match (s("/type"), s("/subtype")) {
        (Some("system"), Some("init")) => s("/session_id").map(|id| Line::Session(id.into())).unwrap_or(Line::Other),
        (Some("stream_event"), _) => match s("/event/type") {
            Some("content_block_delta") if s("/event/delta/type") == Some("text_delta") => {
                Line::Text(s("/event/delta/text").unwrap_or_default().into())
            }
            Some("content_block_start") if s("/event/content_block/type") == Some("text") => Line::Block,
            _ => Line::Other,
        },
        (Some("result"), sub) => {
            let result = s("/result").unwrap_or_default().to_string();
            let failed = v.get("is_error").and_then(Value::as_bool).unwrap_or(false) || sub != Some("success");
            let error = failed.then(|| if result.is_empty() { sub.unwrap_or("error").to_string() } else { result.clone() });
            Line::Done { error, result }
        }
        _ => Line::Other,
    }
}

/// The session the conversation continues: kept on Claude Code's answers.
fn session_of(history: &[Value]) -> Option<String> {
    history.iter().rev().find_map(|m| m.get("session_id").and_then(Value::as_str)).map(String::from)
}

/// The question, with what Claude Code does not know yet: the dropped file or
/// window on the first turn, or the turns another provider answered before.
fn question(first: bool, history: &[Value], context: Option<&ChatContext>, query: &str) -> String {
    let mut text = String::new();
    if !first && session_of(history).is_none() {
        text.push_str("Earlier in this conversation:\n");
        for m in history {
            let who = if m["role"] == "user" { "User" } else { "Assistant" };
            text.push_str(&format!("{who}: {}\n", m["content"].as_str().unwrap_or_default()));
        }
        text.push('\n');
    }
    match context.filter(|_| first) {
        Some(ChatContext::File { name, path }) => text.push_str(&format!("File: {name} ({path})\n\n")),
        Some(ChatContext::Window { app_name, title, url }) => {
            text.push_str(&format!("{}\n\n", chat::window_line(app_name, title, url.as_deref())))
        }
        None => {}
    }
    text.push_str(query);
    text
}

pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    settings: &Settings,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let exe = binary().ok_or_else(|| t("Claude Code isn't installed (no `claude` command found)."))?;
    let dir = work_dir(settings)?;
    let turn = chat.begin(ID);
    let resume = session_of(&turn.history);
    let inbox = matches!(context, Some(ChatContext::File { .. }) if turn.first)
        .then(|| crate::files::inbox_dir().display().to_string());
    let prompt = question(turn.first, &turn.history, context.as_ref(), &query);

    let mut child = tokio::process::Command::new(&exe)
        .args(args(model, &settings.claude_code_effort, resume.as_deref(), inbox.as_deref()))
        .current_dir(&dir)
        .env("COUCOU_CHAT", "1")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("{}: {e}", exe.display()))?;
    let mut stdin = child.stdin.take().expect("piped");
    let _ = stdin.write_all(prompt.as_bytes()).await;
    drop(stdin);

    let (tx, mut cancelled) = tokio::sync::oneshot::channel();
    *CANCEL.lock().unwrap() = Some(tx);
    let stderr = drain_tail(child.stderr.take().expect("piped"));
    let mut lines = BufReader::new(child.stdout.take().expect("piped")).lines();
    let (mut session, mut answer, mut done) = (resume, String::new(), None);
    loop {
        // The next line, or None once New chat cancelled the turn.
        let mut next = Box::pin(lines.next_line());
        let line = std::future::poll_fn(|cx| {
            use std::future::Future;
            if std::pin::Pin::new(&mut cancelled).poll(cx).is_ready() {
                return std::task::Poll::Ready(None);
            }
            next.as_mut().poll(cx).map(Some)
        })
        .await;
        drop(next);
        let Some(line) = line else {
            stop(&mut child);
            return Err(t("Stopped."));
        };
        let Ok(Some(line)) = line else { break };
        match parse(&line) {
            Line::Session(id) => session = Some(id),
            Line::Text(more) => {
                answer.push_str(&more);
                let _ = app.emit_to(WINDOW_LABEL, "chat-delta", answer.trim());
            }
            Line::Block if !answer.is_empty() => answer.push_str("\n\n"),
            Line::Done { error, result } => done = Some((error, result)),
            _ => {}
        }
    }
    let _ = child.wait().await;

    let answer = match done {
        Some((Some(error), _)) => return Err(error),
        Some((None, result)) if answer.trim().is_empty() => result,
        Some(_) => answer.trim().to_string(),
        None => {
            // No result line: Claude Code's own words on stderr, as they are.
            let err = stderr.await.unwrap_or_default();
            let last = err.lines().rev().map(str::trim).find(|l| !l.is_empty()).unwrap_or_default().to_string();
            return Err(if last.is_empty() { t("No response text.") } else { last });
        }
    };
    if answer.is_empty() {
        return Err(t("No response text."));
    }
    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(
        &turn,
        json!({ "role": "user", "content": plain }),
        json!({ "role": "assistant", "content": answer, "session_id": session }),
        &plain,
        &answer,
    );
    Ok(ChatReply { text: answer })
}

/// What a turn keeps of stderr: its end, for the error message.
const STDERR_KEPT: usize = 8 * 1024;

/// Reads `stderr` as it comes, so a chatty one never fills the pipe and stalls the
/// turn; keeps only its last `STDERR_KEPT` bytes.
fn drain_tail<R>(mut stderr: R) -> tokio::task::JoinHandle<String>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    tokio::spawn(async move {
        let mut kept: Vec<u8> = Vec::new();
        let mut buf = [0u8; 4096];
        while let Ok(n) = stderr.read(&mut buf).await {
            if n == 0 {
                break;
            }
            kept.extend_from_slice(&buf[..n]);
            if kept.len() > STDERR_KEPT {
                kept.drain(..kept.len() - STDERR_KEPT);
            }
        }
        String::from_utf8_lossy(&kept).into_owned()
    })
}

/// Asks Claude Code to stop, so it can end its MCP servers; only its own PID.
fn stop(child: &mut tokio::process::Child) {
    #[cfg(target_os = "linux")]
    if let Some(pid) = child.id() {
        unsafe { libc::kill(pid as i32, libc::SIGTERM) };
        return;
    }
    let _ = child.start_kill();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn a_chatty_stderr_does_not_stall_the_answer() {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            // More than a pipe buffer on stderr before the answer reaches stdout.
            let mut child = tokio::process::Command::new("sh")
                .args(["-c", "head -c 300000 /dev/zero | tr '\\0' x >&2; echo >&2; echo >&2 last words; echo answer"])
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            let tail = drain_tail(child.stderr.take().unwrap());
            let mut out = String::new();
            let mut stdout = child.stdout.take().unwrap();
            let read = tokio::time::timeout(std::time::Duration::from_secs(5), stdout.read_to_string(&mut out)).await;
            assert!(read.is_ok(), "stdout ended");
            assert_eq!(out, "answer\n");
            let err = tail.await.unwrap();
            assert!(err.len() <= STDERR_KEPT);
            assert!(err.trim_end().ends_with("last words"));
        });
    }

    /// Lines as `claude -p --output-format stream-json --verbose
    /// --include-partial-messages` 2.1.296 writes them, trimmed.
    const SAMPLE: &[&str] = &[
        r#"{"type":"system","subtype":"init","cwd":"/x","session_id":"ff0b3fc3-cf07-4a7d-8081-484fc71bedad","tools":["Bash"]}"#,
        r#"{"type":"system","subtype":"status","status":"requesting","session_id":"ff0b3fc3-cf07-4a7d-8081-484fc71bedad"}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"ff0b"}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi there"}},"session_id":"ff0b"}"#,
        r#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}},"session_id":"ff0b"}"#,
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi there!"}]},"session_id":"ff0b"}"#,
        r#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
        r#"{"type":"result","subtype":"success","is_error":false,"result":"Hi there!","session_id":"ff0b3fc3-cf07-4a7d-8081-484fc71bedad"}"#,
    ];

    #[test]
    fn the_stream_gives_the_session_the_text_and_the_end() {
        let parsed: Vec<Line> = SAMPLE.iter().map(|l| parse(l)).collect();
        assert_eq!(parsed[0], Line::Session("ff0b3fc3-cf07-4a7d-8081-484fc71bedad".into()));
        assert_eq!(parsed[2], Line::Block);
        assert_eq!(parsed[3], Line::Text("Hi there".into()));
        assert_eq!(parsed[4], Line::Text("!".into()));
        assert_eq!(parsed[5], Line::Other);
        assert_eq!(parsed[7], Line::Done { error: None, result: "Hi there!".into() });
        assert_eq!(parse("not json"), Line::Other);
    }

    #[test]
    fn a_failed_turn_says_why_in_claude_codes_words() {
        let line = r#"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#;
        assert_eq!(parse(line), Line::Done { error: Some("Invalid API key · Please run /login".into()), result: "Invalid API key · Please run /login".into() });
        let line = r#"{"type":"result","subtype":"error_max_turns","is_error":false}"#;
        assert!(matches!(parse(line), Line::Done { error: Some(e), .. } if e == "error_max_turns"));
    }

    #[test]
    fn only_known_models_and_efforts_reach_the_command_line() {
        let a = args("opus", "high", Some("abc"), None);
        assert!(a.windows(2).any(|w| w == ["--model", "opus"]));
        assert!(a.windows(2).any(|w| w == ["--effort", "high"]));
        assert!(a.windows(2).any(|w| w == ["--resume", "abc"]));
        let b = args(DEFAULT_MODEL, "", None, None);
        assert!(!b.iter().any(|x| x == "--model" || x == "--effort" || x == "--resume"));
        let c = args("--dangerously-skip-permissions", "--x", None, None);
        assert!(!c.iter().any(|x| x.starts_with("--dangerously") || x == "--x"));
    }

    #[test]
    fn a_conversation_resumes_its_session_or_brings_earlier_turns_along() {
        let ours = vec![json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a","session_id":"s1"})];
        assert_eq!(session_of(&ours).as_deref(), Some("s1"));
        assert_eq!(question(false, &ours, None, "next"), "next");
        let other = vec![json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"})];
        assert_eq!(question(false, &other, None, "next"), "Earlier in this conversation:\nUser: q\nAssistant: a\n\nnext");
        let file = ChatContext::File { name: "a.txt".into(), path: "/in/a.txt".into() };
        assert_eq!(question(true, &[], Some(&file), "read it"), "File: a.txt (/in/a.txt)\n\nread it");
    }
}
