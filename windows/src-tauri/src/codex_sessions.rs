// Remote continuation of Codex CLI sessions, same shape as devin_sessions:
// the phone picks a past conversation and keeps chatting in it. Codex writes
// each thread as ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl — the
// first line is session_meta {session_id, cwd}, then response_item lines with
// the messages. Read-only; resume runs `codex exec resume <id> <text>` in the
// session's own folder under the user's real config — hooks included.

use std::io::Read;
use std::path::{Path, PathBuf};

/// Longest session_meta line read (it carries AGENTS.md and can be long).
const META_MAX: u64 = 4 * 1024 * 1024;
use std::time::UNIX_EPOCH;

use serde_json::Value;

use crate::cli_chat;
use crate::platform;

pub use crate::devin_sessions::{ChatLine, SessionMeta};

const PER_SESSION_CAP: usize = 96;
/// Rollouts frequently fork/append — several files can share one session id,
/// so the picker scans a multiple of the cap to fill it.
const SCAN_BUDGET: usize = PER_SESSION_CAP * 8;

fn sessions_dir() -> Option<PathBuf> {
    let dir = platform::home_dir().join(".codex").join("sessions");
    dir.is_dir().then_some(dir)
}

/// Every rollout-*.jsonl under the dated tree, newest first — untruncated so
/// resume/transcript can reach sessions older than the picker's window.
fn session_files() -> Vec<PathBuf> {
    let Some(root) = sessions_dir() else { return Vec::new() };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else if p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                n.starts_with("rollout-") && n.ends_with(".jsonl")
            }) {
                let mt = entry.metadata().and_then(|m| m.modified()).unwrap_or(UNIX_EPOCH);
                files.push((mt, p));
            }
        }
    }
    files.sort_by(|a, b| b.0.cmp(&a.0));
    files.into_iter().map(|(_, p)| p).collect()
}

/// The rollout's thread id — what `codex exec resume` takes. Forks share the
/// parent's session_id, so we list the session once (newest file wins).
fn session_id_of(path: &Path) -> Option<String> {
    let v = serde_json::from_str::<Value>(&crate::cli_sessions::first_line(path, META_MAX)?).ok()?;
    v.pointer("/payload/session_id")
        .or_else(|| v.pointer("/payload/id"))
        .and_then(|s| s.as_str())
        .map(str::to_string)
}

fn file_for(session_id: &str) -> Option<PathBuf> {
    session_files()
        .into_iter()
        .find(|p| session_id_of(p).as_deref() == Some(session_id))
}

/// The file head: session_meta is line 1, the first real prompt soon after.
fn head(path: &PathBuf) -> String {
    let Ok(mut f) = std::fs::File::open(path) else {
        return String::new();
    };
    let mut buf = vec![0u8; 262144];
    let n = f.read(&mut buf).unwrap_or(0);
    String::from_utf8_lossy(&buf[..n]).to_string()
}

/// Recent sessions across every folder, newest first — the phone's picker.
pub fn list_recent() -> Vec<SessionMeta> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for path in session_files().into_iter().take(SCAN_BUDGET) {
        if out.len() >= PER_SESSION_CAP {
            break;
        }
        let Some(id) = session_id_of(&path) else { continue };
        if !seen.insert(id.clone()) {
            continue; // a fork/subagent rollout of a session we already listed
        }
        let at = path
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let mut title = String::new();
        let mut dir = String::new();
        for line in head(&path).lines() {
            let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
            let p = v.get("payload").unwrap_or(&Value::Null);
            if dir.is_empty() {
                if let Some(c) = p.get("cwd").and_then(|c| c.as_str()) {
                    dir = c.to_string();
                }
            }
            if title.is_empty()
                && p.get("type").and_then(|t| t.as_str()) == Some("message")
                && p.get("role").and_then(|r| r.as_str()) == Some("user")
            {
                let t = message_text(p);
                if is_real_user(&t) {
                    title = t.chars().take(80).collect();
                }
            }
            if !title.is_empty() && !dir.is_empty() {
                break;
            }
        }
        out.push(SessionMeta {
            id,
            title: if title.is_empty() { file_stamp(&path) } else { title },
            dir,
            last_activity_at: at,
        });
    }
    out
}

/// Fallback title for sessions with no plain-text prompt (exec runs carry the
/// task inside <skill>/<image> wrappers): "Codex 10/10 21:57" from the stamp.
fn file_stamp(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .trim_start_matches("rollout-");
    let b = stem.as_bytes();
    let dated = b.len() >= 16
        && b[..16].iter().enumerate().all(|(i, c)| match i {
            4 | 7 | 13 => *c == b'-',
            10 => *c == b'T',
            _ => c.is_ascii_digit(),
        });
    if dated {
        format!("Codex {}/{} {}:{}", &stem[5..7], &stem[8..10], &stem[11..13], &stem[14..16])
    } else {
        format!("Codex {stem}")
    }
}

/// The tail of a session: user prompts, assistant answers, tool calls as
/// compact lines. Only `response_item` `message`/`function_call` payloads —
/// the event_msg copies are the same items, duplicated.
pub fn transcript(session_id: &str) -> Vec<ChatLine> {
    let Some(path) = file_for(session_id) else {
        return Vec::new();
    };
    let Some(raw) = crate::cli_sessions::read_tail_lossy(&path, crate::cli_sessions::TRANSCRIPT_TAIL) else {
        return Vec::new();
    };
    let mut lines: Vec<ChatLine> = Vec::new();
    for line in raw.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
        let outer = v.get("type").and_then(|t| t.as_str());
        // A turn that died (usage limit, auth, aborted run) — surface the
        // reason so the phone doesn't stare at an empty transcript.
        if outer == Some("event_msg") {
            let p = v.get("payload").cloned().unwrap_or(Value::Null);
            if p.get("type").and_then(|t| t.as_str()) == Some("task_complete") {
                if let Some(err) = p
                    .pointer("/error/message")
                    .and_then(|m| m.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                {
                    lines.push(ChatLine {
                        role: "assistant".into(),
                        text: format!("(run ended: {})", err.chars().take(200).collect::<String>()),
                        name: None,
                    });
                }
            }
            continue;
        }
        if outer != Some("response_item") {
            continue;
        }
        let p = v.get("payload").cloned().unwrap_or(Value::Null);
        match p.get("type").and_then(|t| t.as_str()) {
            Some("message") => {
                let role = p.get("role").and_then(|r| r.as_str()).unwrap_or("");
                let text = message_text(&p);
                let keep = match role {
                    "user" => is_real_user(&text),
                    "assistant" => !text.trim().is_empty(),
                    _ => false,
                };
                if keep {
                    lines.push(ChatLine { role: role.into(), text, name: None });
                }
            }
            Some("function_call") | Some("custom_tool_call") | Some("local_shell_call") => {
                let name = p.get("name").and_then(|n| n.as_str()).unwrap_or("tool");
                let detail = p
                    .get("arguments")
                    .or_else(|| p.get("input"))
                    .and_then(|a| {
                        if let Some(s) = a.as_str() {
                            // arguments come as a JSON string — pull the command out of it
                            serde_json::from_str::<Value>(s)
                                .ok()
                                .and_then(|v| {
                                    v.get("command")
                                        .or_else(|| v.get("file_path"))
                                        .or_else(|| v.get("path"))
                                        .and_then(|c| c.as_str())
                                        .map(str::to_string)
                                        .or_else(|| {
                                            v.as_array().map(|arr| {
                                                arr.iter()
                                                    .filter_map(|x| x.as_str())
                                                    .collect::<Vec<_>>()
                                                    .join(" ")
                                            })
                                        })
                                })
                                .or_else(|| Some(s.to_string()))
                        } else {
                            a.get("command")
                                .or_else(|| a.get("file_path"))
                                .or_else(|| a.get("path"))
                                .and_then(|c| c.as_str())
                                .map(str::to_string)
                        }
                    })
                    .unwrap_or_default();
                let mut detail = detail.trim().to_string();
                if detail.chars().count() > 300 {
                    detail = detail.chars().take(300).collect::<String>() + "…";
                }
                lines.push(ChatLine { role: "tool".into(), name: Some(name.into()), text: detail });
            }
            _ => {}
        }
    }
    lines.split_at(lines.len().saturating_sub(40)).1.to_vec()
}

/// message.content parts: {type: "input_text"/"output_text"/"text", text}.
fn message_text(p: &Value) -> String {
    p.get("content")
        .and_then(|c| c.as_array())
        .map(|parts| {
            parts
                .iter()
                .filter_map(|p| p.get("text").and_then(|t| t.as_str()))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Exec-run wrappers and pasted-content envelopes aren't the user talking —
/// the actual prompt sits inside <skill>/<image> args, never in plain text.
fn is_real_user(text: &str) -> bool {
    const NOISE: &[&str] = &[
        "<local-command",
        "<command-",
        "<system-reminder",
        "<task-notification",
        "<pasted_content",
        "<environment_context",
        "<image",
        "<skill",
        "<instructions",
        "<user_instructions",
        "<collaboration",
        "<mcp",
        "<persistent",
        "Caveat:",
    ];
    let t = text.trim_start();
    !t.is_empty() && !NOISE.iter().any(|p| t.starts_with(p))
}

/// The session's folder from its session_meta line, else the private dir.
fn session_dir(path: &Path) -> Option<PathBuf> {
    let line = crate::cli_sessions::first_line(path, META_MAX)?;
    let dir = serde_json::from_str::<Value>(&line)
        .ok()?
        .pointer("/payload/cwd")
        .and_then(|c| c.as_str())
        .map(PathBuf::from);
    dir
        .filter(|p| p.is_dir())
        .or_else(|| cli_chat::workdir("codex-chat").ok())
}

/// A phone-sent message inside a picked session:
/// `codex exec resume <session_id> <text>` under the user's real config.
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = cli_chat::find_cli(&["codex", "codex-cli"])
        .ok_or("Codex CLI not found. Install it, then run `codex login`.")?;
    let file = file_for(session_id).ok_or("Unknown session")?;
    let dir = session_dir(&file).ok_or("No folder to run the session in")?;
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["exec", "resume", session_id, prompt.as_str()]);
    let out = cli_chat::run(cmd, "the Codex CLI").await?;
    crate::cli_sessions::answer(&out, "The Codex CLI")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn rollout_names_become_short_titles_and_odd_names_never_panic() {
        assert_eq!(file_stamp(Path::new("rollout-2026-10-10T21-57-47-0199a.jsonl")), "Codex 10/10 21:57");
        assert_eq!(file_stamp(Path::new("rollout-éééééééééé.jsonl")), "Codex éééééééééé");
        assert_eq!(file_stamp(Path::new("rollout-short.jsonl")), "Codex short");
    }

    #[test]
    fn a_session_whose_meta_line_is_huge_keeps_its_id() {
        let dir = std::env::temp_dir().join(format!("coucou-codex-meta-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rollout-2026-01-01T00-00-00-aaa.jsonl");
        let meta = format!(r#"{{"payload":{{"id":"aaa","cwd":"/p","instructions":"{}"}}}}"#, "i".repeat(150_000));
        std::fs::write(&path, format!("{meta}\n")).unwrap();
        assert_eq!(session_id_of(&path).as_deref(), Some("aaa"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
