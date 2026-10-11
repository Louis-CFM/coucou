// Remote continuation of OpenCode sessions, same shape as devin_sessions:
// the phone picks a past conversation and keeps chatting in it. OpenCode keeps
// everything in ~/.local/share/opencode/opencode.db — `session` rows (id,
// title, directory), `message` rows (role in the JSON blob), `part` rows
// (text/tool parts, also JSON). Read-only; resume runs
// `opencode run -s <id> <text>` in the session's directory under the user's
// real config — hooks included.

use std::path::PathBuf;

use rusqlite::{Connection, OpenFlags};
use serde_json::Value;

use crate::cli_chat;
use crate::platform;

pub use crate::devin_sessions::{ChatLine, SessionMeta};

fn db_path() -> Option<PathBuf> {
    let home = platform::home_dir();
    let candidates = [
        home.join(".local/share/opencode/opencode.db"),
        home.join(".config/opencode/opencode.db"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

fn open() -> Result<Connection, String> {
    let path = db_path().ok_or("No OpenCode store found — is OpenCode installed?")?;
    let conn =
        Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| e.to_string())?;
    conn.busy_timeout(std::time::Duration::from_millis(1500))
        .map_err(|e| e.to_string())?;
    Ok(conn)
}

/// Recent sessions, newest first — the phone's picker.
pub fn list_recent() -> Vec<SessionMeta> {
    let Ok(conn) = open() else { return Vec::new() };
    let mut stmt = match conn.prepare(
        "SELECT id, title, directory, time_updated FROM session \
         ORDER BY time_updated DESC LIMIT 96",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([], |r| {
        let id: String = r.get(0)?;
        Ok(SessionMeta {
            title: r.get::<_, Option<String>>(1)?.unwrap_or_else(|| id.clone()),
            id,
            dir: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            model: String::new(),
            last_activity_at: r.get::<_, Option<i64>>(3)?.unwrap_or(0) / 1000,
        })
    });
    match rows {
        Ok(it) => it.flatten().collect(),
        Err(_) => Vec::new(),
    }
}

/// The tail of a session: user prompts, assistant text parts, tool calls as
/// compact lines (OpenCode's `state.title` is already a one-line summary).
/// Messages and parts join on message_id, ordered by their own timestamps.
pub fn transcript(session_id: &str) -> Vec<ChatLine> {
    let Ok(conn) = open() else { return Vec::new() };
    let mut stmt = match conn.prepare(
        "SELECT m.data, p.data FROM message m \
         LEFT JOIN part p ON p.message_id = m.id \
         WHERE m.session_id = ?1 \
         ORDER BY m.time_created, p.time_created",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([session_id], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?))
    });
    let Ok(it) = rows else { return Vec::new() };
    let mut lines: Vec<ChatLine> = Vec::new();
    for (mraw, praw) in it.flatten() {
        let Ok(m) = serde_json::from_str::<Value>(&mraw) else { continue };
        let role = m.get("role").and_then(|r| r.as_str()).unwrap_or("");
        // The JOIN repeats m.data per part — only each part's own data matters.
        let Some(part) = praw.and_then(|s| serde_json::from_str::<Value>(&s).ok()) else {
            continue;
        };
        match part.get("type").and_then(|t| t.as_str()) {
            Some("text") => {
                let text = part.get("text").and_then(|t| t.as_str()).unwrap_or_default();
                let keep = match role {
                    "user" => is_real_user(text),
                    "assistant" => !text.trim().is_empty(),
                    _ => false,
                };
                if keep {
                    lines.push(ChatLine { role: role.into(), text: text.into(), name: None });
                }
            }
            Some("tool") => {
                let name = part.get("tool").and_then(|t| t.as_str()).unwrap_or("tool");
                let state = part.get("state");
                let input = state.and_then(|s| s.get("input"));
                let detail = state
                    .and_then(|s| s.get("title"))
                    .and_then(|t| t.as_str())
                    .filter(|s| !s.trim().is_empty())
                    .map(str::to_string)
                    .or_else(|| {
                        ["command", "filePath", "file_path", "path", "pattern", "url", "query"]
                            .iter()
                            .find_map(|k| input?.get(*k)?.as_str().map(str::to_string))
                    })
                    .or_else(|| {
                        input.and_then(|v| serde_json::to_string(v).ok())
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

/// Slash-command echoes and injected context aren't the user talking.
fn is_real_user(text: &str) -> bool {
    const NOISE: &[&str] = &["<local-command", "<command-", "<system-reminder", "<task-notification"];
    let t = text.trim_start();
    !t.is_empty() && !NOISE.iter().any(|p| t.starts_with(p))
}

/// The session's directory, else the private fallback folder.
fn session_dir(conn: &Connection, session_id: &str) -> Option<PathBuf> {
    let dir: Option<String> = conn
        .query_row(
            "SELECT directory FROM session WHERE id = ?1",
            [session_id],
            |r| r.get(0),
        )
        .ok()
        .flatten();
    dir.map(PathBuf::from)
        .filter(|p| p.is_dir())
        .or_else(|| cli_chat::workdir("opencode-chat").ok())
}

/// A phone-sent message inside a picked session:
/// `opencode run -s <id> <text>` under the user's real config.
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    let cli = cli_chat::find_cli(&["opencode"])
        .ok_or("OpenCode CLI not found. Install it, then run `opencode` once.")?;
    let conn = open()?;
    let dir = session_dir(&conn, session_id).ok_or("No folder to run the session in")?;
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["run", "-s", session_id, query]);
    let out = cli_chat::run(cmd, "the OpenCode CLI").await?;
    if out.status.success() {
        let text = cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stdout))
            .trim()
            .to_string();
        return if text.is_empty() { Err("No response text.".into()) } else { Ok(text) };
    }
    let stderr = cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stderr));
    Err(stderr
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("The OpenCode CLI failed.")
        .to_string())
}
