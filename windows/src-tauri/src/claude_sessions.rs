// Remote continuation of Claude Code sessions, mirroring devin_sessions:
// the phone picks a past conversation and keeps chatting in it. Claude Code
// stores each session as ~/.claude/projects/<dir-slug>/<session-id>.jsonl —
// one JSON event per line, appended chronologically. We read the files
// read-only (the CLI can keep writing) and resume with
// `claude -p <text> --resume <id>` in the session's own folder, under the
// user's real config — hooks fire and the session shows live in the island.

use std::io::Read;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

use serde_json::Value;

use crate::cli_chat;
use crate::platform;

pub use crate::devin_sessions::{ChatLine, SessionMeta};

const PER_SESSION_CAP: usize = 96;

fn projects_dir() -> Option<PathBuf> {
    let dir = platform::home_dir().join(".claude").join("projects");
    dir.is_dir().then_some(dir)
}

/// All `*.jsonl` session files under ~/.claude/projects, newest first —
/// capped so a huge history never blocks the phone's picker.
fn session_files() -> Vec<PathBuf> {
    let Some(root) = projects_dir() else { return Vec::new() };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    for dir in std::fs::read_dir(&root).into_iter().flatten().flatten() {
        let dir = dir.path();
        if !dir.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let mt = entry.metadata().and_then(|m| m.modified()).unwrap_or(UNIX_EPOCH);
            files.push((mt, p));
        }
    }
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.truncate(PER_SESSION_CAP * 4);
    files.into_iter().map(|(_, p)| p).collect()
}

/// `<uuid>.jsonl` → the bare session id.
fn file_id(path: &PathBuf) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .to_string()
}

/// Find the jsonl for a session id (files are named by it).
fn find_file(session_id: &str) -> Option<PathBuf> {
    if !crate::cli_sessions::valid_id(session_id) {
        return None;
    }
    let name = format!("{session_id}.jsonl");
    let root = projects_dir()?;
    for dir in std::fs::read_dir(&root).into_iter().flatten().flatten() {
        let p = dir.path().join(&name);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// Stream a session file's head for the listing: hook noise can shove the
/// first real user prompt hundreds of KB into the file, so we keep scanning
/// chunks until the visitor says stop — not until a fixed byte count is hit.
/// Lines over 1MB are dropped mid-line so a giant blob never stalls the scan;
/// the whole scan stops at 12MB regardless.
fn scan_head(path: &PathBuf, mut visit: impl FnMut(&Value) -> bool) {
    const CHUNK: usize = 262_144;
    const LINE_MAX: usize = 1_048_576;
    const BUDGET: usize = 12 * 1_048_576;
    let Ok(mut f) = std::fs::File::open(path) else { return };
    let mut chunk = vec![0u8; CHUNK];
    let mut line: Vec<u8> = Vec::new();
    let mut skipping = false;
    let mut total = 0usize;
    'outer: while total < BUDGET {
        let n = f.read(&mut chunk).unwrap_or(0);
        if n == 0 {
            break;
        }
        total += n;
        for &b in &chunk[..n] {
            if skipping {
                if b == b'\n' {
                    skipping = false;
                    line.clear();
                }
                continue;
            }
            line.push(b);
            if b == b'\n' {
                if let Ok(v) = serde_json::from_slice::<Value>(line.trim_ascii()) {
                    if !visit(&v) {
                        break 'outer;
                    }
                }
                line.clear();
            } else if line.len() > LINE_MAX {
                skipping = true;
                line.clear();
            }
        }
    }
}

/// Recent sessions across every project, newest first — the phone's picker.
pub fn list_recent() -> Vec<SessionMeta> {
    session_files()
        .into_iter()
        .take(PER_SESSION_CAP)
        .map(|path| {
            let at = path
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            let mut title = String::new();
            let mut dir = String::new();
            scan_head(&path, |v| {
                if dir.is_empty() {
                    if let Some(c) = v.get("cwd").and_then(|c| c.as_str()) {
                        dir = c.to_string();
                    }
                }
                if title.is_empty() && v.get("type").and_then(|t| t.as_str()) == Some("summary") {
                    if let Some(s) = v.get("summary").and_then(|s| s.as_str()) {
                        title = s.to_string();
                    }
                }
                if title.is_empty() && v.get("type").and_then(|t| t.as_str()) == Some("user") {
                    let t = title_text(&message_text(&v));
                    if is_real_user(&t) {
                        title = t.chars().take(80).collect();
                    }
                }
                title.is_empty() || dir.is_empty()
            });
            SessionMeta {
                id: file_id(&path),
                title: if title.is_empty() { file_id(&path) } else { title },
                dir,
                model: String::new(),
                last_activity_at: at,
            }
        })
        .collect()
}

/// The tail of a session: user prompts, assistant answers, tool calls
/// (compact cards on the phone, same as Devin's). Sidechains (sub-agent
/// Task branches) and local-command chatter are filtered out.
pub fn transcript(session_id: &str) -> Vec<ChatLine> {
    find_file(session_id).map(|path| transcript_at(&path)).unwrap_or_default()
}

fn transcript_at(path: &std::path::Path) -> Vec<ChatLine> {
    let Some(raw) = crate::cli_sessions::read_tail_lossy(path, crate::cli_sessions::TRANSCRIPT_TAIL) else {
        return Vec::new();
    };
    let mut lines: Vec<ChatLine> = Vec::new();
    for line in raw.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if v.get("isSidechain").and_then(|s| s.as_bool()) == Some(true) {
            continue;
        }
        match v.get("type").and_then(|t| t.as_str()) {
            Some("user") => {
                let text = message_text(&v);
                if is_real_user(&text) {
                    lines.push(ChatLine { role: "user".into(), text, name: None });
                }
            }
            Some("assistant") => {
                let Some(parts) = v
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array())
                else {
                    continue;
                };
                for p in parts {
                    match p.get("type").and_then(|t| t.as_str()) {
                        Some("tool_use") => {
                            let name = p
                                .get("name")
                                .and_then(|n| n.as_str())
                                .unwrap_or("tool");
                            lines.push(ChatLine {
                                role: "tool".into(),
                                name: Some(name.into()),
                                text: tool_detail(p.get("input")),
                            });
                        }
                        Some("text") => {
                            let text = p
                                .get("text")
                                .and_then(|t| t.as_str())
                                .unwrap_or_default()
                                .to_string();
                            if !text.trim().is_empty() {
                                lines.push(ChatLine {
                                    role: "assistant".into(),
                                    text,
                                    name: None,
                                });
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    lines.split_at(lines.len().saturating_sub(40)).1.to_vec()
}

/// `message.content`: plain string or parts [{type:"text",text}|...].
fn message_text(v: &Value) -> String {
    let Some(c) = v.get("message").and_then(|m| m.get("content")) else {
        return String::new();
    };
    if let Some(s) = c.as_str() {
        return s.to_string();
    }
    c.as_array()
        .map(|parts| {
            parts
                .iter()
                .filter(|p| p.get("type").and_then(|t| t.as_str()) == Some("text"))
                .filter_map(|p| p.get("text").and_then(|t| t.as_str()))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// What a user message's title should be: paste wrappers are unwrapped (the
/// pasted prompt IS the title), image placeholders dropped — what's left is
/// the sentence the session started with.
fn title_text(text: &str) -> String {
    let t = text.trim_start();
    let t = if t.starts_with("<pasted_content") {
        t[t.find('>').map(|i| i + 1).unwrap_or(0)..]
            .trim_end_matches("</pasted_content>")
            .trim()
    } else {
        t
    };
    t.lines()
        .filter(|l| !l.trim_start().starts_with("[Image"))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// Slash-command echoes, hook noise and task-notification XML aren't the user
/// talking — Claude writes several of those as user-role messages.
fn is_real_user(text: &str) -> bool {
    const NOISE: &[&str] = &[
        "<local-command",
        "<command-",
        "<bash-",
        "<system-reminder",
        "<task-notification",
        "<pasted_content",
        "<ide_",
        "<skill",
        "[Image",
        "Base directory for this skill",
        "Caveat:",
    ];
    let t = text.trim_start();
    !t.is_empty() && !NOISE.iter().any(|p| t.starts_with(p))
}

/// One-line summary of a tool input — command first, then path-ish keys.
fn tool_detail(input: Option<&Value>) -> String {
    let Some(args) = input.and_then(|a| a.as_object()) else {
        return String::new();
    };
    let mut detail = args
        .get("command")
        .or_else(|| args.get("file_path"))
        .or_else(|| args.get("path"))
        .or_else(|| args.get("url"))
        .or_else(|| args.get("pattern"))
        .or_else(|| args.get("query"))
        .or_else(|| args.get("description"))
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| {
            args.values()
                .find_map(|v| v.as_str())
                .unwrap_or_default()
                .to_string()
        });
    if detail.chars().count() > 300 {
        detail = detail.chars().take(300).collect::<String>() + "…";
    }
    detail.trim().to_string()
}

/// The session's own working folder (every event carries `cwd`, so the file
/// head has it), falling back to the private chat dir if the folder is gone.
fn session_dir(path: &PathBuf) -> Option<PathBuf> {
    let mut cwd: Option<String> = None;
    scan_head(path, |v| {
        cwd = v.get("cwd").and_then(|c| c.as_str()).map(str::to_string);
        cwd.is_none()
    });
    cwd.map(PathBuf::from)
        .filter(|p| p.is_dir())
        .or_else(|| cli_chat::workdir("claude-chat").ok())
}

/// A phone-sent message inside a picked session: `claude -p <text> --resume
/// <id>` under the user's real config so hooks fire and the session appears
/// live in the island.
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = cli_chat::find_cli(&["claude", "claude-code"])
        .ok_or("Claude CLI not found. Install Claude Code, then run `claude` once.")?;
    let file = find_file(session_id).ok_or("Unknown session")?;
    let dir = session_dir(&file).ok_or("No folder to run the session in")?;
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["-p", prompt.as_str(), "--resume", session_id]);
    let out = cli_chat::run(cmd, "the Claude CLI").await?;
    crate::cli_sessions::answer(&out, "The Claude CLI")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_transcript_keeps_prompts_answers_and_tool_calls() {
        let dir = std::env::temp_dir().join(format!("coucou-claude-tr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.jsonl");
        let mut bytes = concat!(
            r#"{"type":"user","message":{"content":"fix the bug"}}"#, "\n",
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#, "\n",
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Done — café"},{"type":"tool_use","name":"Bash","input":{"command":"cargo test"}}]}}"#, "\n",
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"side"}]}}"#, "\n",
        )
        .to_string()
        .into_bytes();
        bytes.extend_from_slice(&[0xE2, 0x82]);
        std::fs::write(&path, bytes).unwrap();

        let got: Vec<(String, String)> = transcript_at(&path).into_iter().map(|l| (l.role, l.text)).collect();
        assert_eq!(
            got,
            vec![
                ("user".into(), "fix the bug".into()),
                ("assistant".into(), "Done — café".into()),
                ("tool".into(), "cargo test".into()),
            ]
        );
    }
}
