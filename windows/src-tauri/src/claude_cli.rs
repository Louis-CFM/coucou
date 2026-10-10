// Chat through the user's own Claude Code CLI (`claude -p`): it answers with
// the login Claude Code already has, so a Pro or Max subscription is enough and
// no API key is needed.
//
// One process per turn. The earlier turns ride along in the prompt (the
// conversation lives in chat.rs, not in a Claude Code session), tools are
// switched off so a chat question can never touch the disk or the shell, and
// the answer streams to the island as `chat-delta` events like local_chat.rs.

use std::path::PathBuf;
use std::process::Stdio;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::i18n::t;
use crate::island::WINDOW_LABEL;

pub const ID: &str = "claudecode";
pub const DEFAULT_MODEL: &str = "sonnet";

/// The island is told about new text at most this often.
const DELTA_INTERVAL: Duration = Duration::from_millis(1000 / 15);
/// A turn that has not finished by now is cut: the process is killed with it.
const TURN_TIMEOUT: Duration = Duration::from_secs(300);
const MAX_ANSWER: usize = 4 * 1024 * 1024;
/// A text file is sent inline up to this many characters; the rest is cut.
const MAX_INLINE_CHARS: usize = 24_000;

/// The aliases `claude --model` accepts: they follow the newest model of each size.
pub fn models() -> Vec<ModelInfo> {
    [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        .into_iter()
        .map(|(id, label)| ModelInfo { id: id.into(), label: label.into() })
        .collect()
}

/// `claude` on the PATH, or where the native installer puts it.
fn binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join("claude");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    let home = PathBuf::from(std::env::var_os("HOME")?);
    let link = home.join(".local/bin/claude");
    if link.is_file() {
        return Some(link);
    }
    let mut versions: Vec<PathBuf> = std::fs::read_dir(home.join(".local/share/claude/versions"))
        .ok()?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_file())
        .collect();
    versions.sort_by_key(|p| version_key(p));
    versions.pop()
}

/// `2.1.270` sorts after `2.1.241`: compare the numbers, not the characters.
fn version_key(path: &std::path::Path) -> Vec<u64> {
    path.file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .split('.')
        .map(|part| part.parse().unwrap_or(0))
        .collect()
}

/// The earlier turns and the new question as one prompt.
fn prompt(history: &[Value], question: &str) -> String {
    if history.is_empty() {
        return question.to_string();
    }
    let mut text = String::from("Conversation so far:\n\n");
    for turn in history {
        let who = if turn["role"] == "assistant" { "Assistant" } else { "User" };
        text.push_str(&format!("{who}: {}\n\n", turn["content"].as_str().unwrap_or_default()));
    }
    text.push_str(&format!("Now the user asks:\n\n{question}"));
    text
}

/// What the user typed, plus the file or window they dropped on Mochi.
fn question(first: bool, context: Option<&ChatContext>, query: &str) -> String {
    match context.filter(|_| first) {
        Some(ChatContext::File { name, path }) => match read_text_prefix(path) {
            Some(text) => {
                let shown: String = text.chars().take(MAX_INLINE_CHARS).collect();
                format!("File: {name}\n\n```\n{shown}\n```\n\n{query}")
            }
            None => format!("File: {name} (binary, not shown)\n\n{query}"),
        },
        Some(ChatContext::Window { app_name, title, url }) => {
            format!("{}\n\n{query}", chat::window_line(app_name, title, url.as_deref()))
        }
        None => query.to_string(),
    }
}

/// The start of a text file, at most `MAX_INLINE_CHARS` characters' worth of bytes: a huge
/// file is never read whole. `None` for a missing, unreadable or binary file. A multi-byte
/// character cut by the byte limit is dropped, not mistaken for binary.
fn read_text_prefix(path: &str) -> Option<String> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path).ok()?.take(MAX_INLINE_CHARS as u64 * 4).read_to_end(&mut bytes).ok()?;
    match std::str::from_utf8(&bytes) {
        Ok(text) => Some(text.to_string()),
        Err(e) if e.error_len().is_none() => std::str::from_utf8(&bytes[..e.valid_up_to()]).ok().map(str::to_string),
        Err(_) => None,
    }
}

/// One line of `--output-format stream-json`: the text it adds, if any.
fn delta_text(line: &str) -> Option<String> {
    let v: Value = serde_json::from_str(line).ok()?;
    if v["type"] != "stream_event" {
        return None;
    }
    let delta = &v["event"]["delta"];
    if delta["type"] != "text_delta" {
        return None;
    }
    delta["text"].as_str().map(str::to_string)
}

fn is_message_start(line: &str) -> bool {
    serde_json::from_str::<Value>(line)
        .map(|v| v["type"] == "stream_event" && v["event"]["type"] == "message_start")
        .unwrap_or(false)
}

/// The final `result` line: the full answer, or the error Claude Code ended on.
fn final_result(line: &str) -> Option<Result<String, String>> {
    let v: Value = serde_json::from_str(line).ok()?;
    if v["type"] != "result" {
        return None;
    }
    let text = v["result"].as_str().unwrap_or_default().to_string();
    if v["is_error"].as_bool().unwrap_or(false) {
        return Some(Err(if text.is_empty() { "Claude Code failed.".into() } else { text }));
    }
    Some(Ok(text))
}

// ── The user's memory ─────────────────────────────────────────────────────────
//
// With "Chat memory" on and a notes folder on disk, the chat is given what the
// user's other Claude sessions know: the folder's MEMORY.md index goes into the
// prompt, the notes can be read on demand, and new ones can be written, in that
// folder and nowhere else (the permission rules below deny everything else).
// COUCOU_MEMORY_DIR names the folder; the default is the Obsidian vault's
// `.agent/memory`.

const MAX_INDEX_BYTES: usize = 30_000;

/// The memory folder, when it exists.
pub fn memory_dir() -> Option<PathBuf> {
    let dir = match std::env::var_os("COUCOU_MEMORY_DIR").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(std::env::var_os("HOME")?).join("Documents/Obsidian Vault/.agent/memory"),
    };
    dir.is_dir().then_some(dir)
}

/// The system prompt with the memory instructions and index added.
fn memory_prompt(base: &str, dir: &std::path::Path, writable: bool) -> String {
    let mut index = std::fs::read_to_string(dir.join("MEMORY.md")).unwrap_or_default();
    if index.len() > MAX_INDEX_BYTES {
        let mut cut = MAX_INDEX_BYTES;
        while !index.is_char_boundary(cut) {
            cut -= 1;
        }
        index.truncate(cut);
    }
    let saving = if writable {
        "When you learn something worth keeping (a preference, a decision, the state of a project), save it: first check the index \
for a note on it and update that, otherwise create one note per fact in the same folder, as a file with this frontmatter \
(name, description, type: user | feedback | project | reference) and then the content, and add or update its one line in MEMORY.md \
(`- [Title](file.md) — one-line hook`). Never write anywhere but that folder, and tell the user when you saved something."
    } else {
        "The notes are read-only in this chat, because it contains a file or window the user did not write: do not try to save anything."
    };
    format!(
        "{base}\n\n\
You share the user's persistent memory with their other Claude sessions: Markdown notes in {dir}. \
Its index, MEMORY.md, is below. Before answering anything that may depend on what is known about the user, \
their projects or their preferences, Read the notes the index points to. {saving}\n\n\
--- MEMORY.md ---\n{index}",
        dir = dir.display(),
    )
}

/// The `claude` arguments for a chat with memory: one folder is readable, and writable only when
/// `writable`. Every rule names the folder (`//` = absolute path); a bare `Read` would allow every
/// file the user can read. Grep and Glob are left out: their rules do not take the folder.
fn memory_args(dir: &std::path::Path, writable: bool) -> Vec<String> {
    let rule = format!("/{}/**", dir.display());
    let mut args: Vec<String> = vec![
        "--tools".into(),
        if writable { "Read,Write,Edit" } else { "Read" }.into(),
        "--permission-mode".into(),
        "dontAsk".into(),
        "--add-dir".into(),
        dir.display().to_string(),
        "--allowedTools".into(),
        format!("Read({rule})"),
    ];
    if writable {
        args.push(format!("Edit({rule})"));
    }
    args
}

pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    model: &str,
    memory: bool,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let bin = binary().ok_or_else(|| t("Claude Code is not installed: run `claude` once in a terminal to log in."))?;
    let turn = chat.begin(ID);
    let asked = question(turn.first, context.as_ref(), &query);
    let user = json!({ "role": "user", "content": asked });
    let input = prompt(&turn.history, &asked);

    let memory_dir = memory.then(memory_dir).flatten();
    // Writing is off once the conversation has taken in a file or window the user did not write.
    let writable = !turn.untrusted;
    let system = match &memory_dir {
        Some(dir) => memory_prompt(&chat::system_prompt(false), dir, writable),
        None => chat::system_prompt(false),
    };

    let mut cmd = Command::new(bin);
    cmd.args([
        "-p",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--setting-sources", "",
        "--strict-mcp-config",
        "--system-prompt",
    ])
    .arg(&system);
    match &memory_dir {
        // The folder is the working directory and the only place that can be read; it is the only
        // place that can be written, and only while nothing untrusted is in the conversation.
        Some(dir) => {
            cmd.current_dir(dir).args(memory_args(dir, writable));
        }
        None => {
            cmd.args(["--tools", ""]);
        }
    }
    cmd
    .args(["--model", if model.is_empty() { DEFAULT_MODEL } else { model }])
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::null())
    .kill_on_drop(true);

    let mut child = cmd.spawn().map_err(|e| format!("Could not start Claude Code: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("Claude Code has no input.")?;
    stdin.write_all(input.as_bytes()).await.map_err(|e| e.to_string())?;
    drop(stdin);

    let stdout = child.stdout.take().ok_or("Claude Code has no output.")?;
    let mut lines = BufReader::new(stdout).lines();

    let read = async {
        let mut streamed = String::new();
        let mut last_emit = Instant::now() - DELTA_INTERVAL;
        let mut finished: Option<Result<String, String>> = None;
        while let Some(line) = lines.next_line().await.map_err(|e| e.to_string())? {
            if is_message_start(&line) {
                // A new message after a tool call: only the latest one is shown.
                streamed.clear();
            } else if let Some(piece) = delta_text(&line) {
                if streamed.len() + piece.len() <= MAX_ANSWER {
                    streamed.push_str(&piece);
                }
                if last_emit.elapsed() >= DELTA_INTERVAL {
                    let _ = app.emit_to(WINDOW_LABEL, "chat-delta", &streamed);
                    last_emit = Instant::now();
                }
            } else if let Some(done) = final_result(&line) {
                finished = Some(done);
            }
        }
        let _ = app.emit_to(WINDOW_LABEL, "chat-delta", &streamed);
        match finished {
            Some(Ok(text)) if !text.is_empty() => Ok(text),
            Some(Ok(_)) => Ok(streamed),
            Some(Err(e)) => Err(e),
            None => Ok(streamed),
        }
    };
    let answer = tokio::time::timeout(TURN_TIMEOUT, read)
        .await
        .map_err(|_| t("Claude Code took too long."))??;
    let _ = child.wait().await;

    if answer.trim().is_empty() {
        return Err(t("No response text."));
    }
    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(&turn, user, json!({ "role": "assistant", "content": answer }), &plain, &answer);
    Ok(ChatReply { text: answer })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_sort_by_number() {
        let a = version_key(std::path::Path::new("/x/2.1.241"));
        let b = version_key(std::path::Path::new("/x/2.1.270"));
        let c = version_key(std::path::Path::new("/x/2.1.9"));
        assert!(b > a);
        assert!(a > c);
    }

    #[test]
    fn stream_lines_give_text_and_the_final_result() {
        let delta = r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#;
        assert_eq!(delta_text(delta).as_deref(), Some("Hi"));
        assert_eq!(delta_text(r#"{"type":"system"}"#), None);
        let done = r#"{"type":"result","is_error":false,"result":"Hi there"}"#;
        assert_eq!(final_result(done), Some(Ok("Hi there".into())));
        let bad = r#"{"type":"result","is_error":true,"result":"Not logged in"}"#;
        assert_eq!(final_result(bad), Some(Err("Not logged in".into())));
    }

    #[test]
    fn a_new_message_is_recognised() {
        assert!(is_message_start(r#"{"type":"stream_event","event":{"type":"message_start"}}"#));
        assert!(!is_message_start(r#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#));
        assert!(!is_message_start("not json"));
    }

    #[test]
    fn the_memory_prompt_has_the_index_and_the_folder() {
        let dir = std::env::temp_dir().join(format!("coucou-mem-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("MEMORY.md"), "- [A](a.md) — hook\n").unwrap();
        let p = memory_prompt("You are Mochi.", &dir, true);
        assert!(p.starts_with("You are Mochi."));
        assert!(p.contains(&dir.display().to_string()));
        assert!(p.ends_with("- [A](a.md) — hook\n"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn memory_rules_always_name_the_folder() {
        let dir = std::path::Path::new("/home/u/Notes Vault/.agent/memory");
        for writable in [true, false] {
            let args = memory_args(dir, writable);
            let allowed = &args[args.iter().position(|a| a == "--allowedTools").unwrap() + 1..];
            assert!(allowed.iter().all(|a| a.contains("//home/u/Notes Vault/.agent/memory/**")), "{allowed:?}");
            assert!(!allowed.iter().any(|a| a == "Read" || a == "Grep" || a == "Glob" || a.starts_with("Write(")), "{allowed:?}");
        }
    }

    #[test]
    fn untrusted_conversations_cannot_write() {
        let dir = std::path::Path::new("/m");
        let ro = memory_args(dir, false);
        assert!(ro.iter().any(|a| a == "Read") && !ro.iter().any(|a| a.contains("Edit") || a.contains("Write")));
        let rw = memory_args(dir, true);
        assert!(rw.iter().any(|a| a == "Read,Write,Edit") && rw.iter().any(|a| a.starts_with("Edit(")));
        let dir = std::env::temp_dir().join(format!("coucou-memro-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(memory_prompt("b", &dir, false).contains("read-only"));
        assert!(!memory_prompt("b", &dir, false).contains("save it"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_dropped_file_is_read_in_bounded_form() {
        let path = std::env::temp_dir().join(format!("coucou-read-{}.txt", std::process::id()));
        std::fs::write(&path, "é".repeat(MAX_INLINE_CHARS * 3)).unwrap();
        let text = read_text_prefix(path.to_str().unwrap()).unwrap();
        assert!(text.len() <= MAX_INLINE_CHARS * 4 && text.chars().all(|c| c == 'é'));
        std::fs::write(&path, [0u8, 159, 146, 150]).unwrap();
        assert!(read_text_prefix(path.to_str().unwrap()).is_none());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn the_prompt_carries_earlier_turns() {
        assert_eq!(prompt(&[], "hi"), "hi");
        let history = vec![json!({"role":"user","content":"a"}), json!({"role":"assistant","content":"b"})];
        let p = prompt(&history, "c");
        assert!(p.contains("User: a") && p.contains("Assistant: b") && p.ends_with("c"));
    }
}
