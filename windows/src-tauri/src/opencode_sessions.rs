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
        Err(err) => {
            crate::cli_sessions::log_once("opencode sessions", &err.to_string());
            return Vec::new();
        }
    };
    let rows = stmt.query_map([], |r| {
        let id: String = r.get(0)?;
        Ok(SessionMeta {
            title: r.get::<_, Option<String>>(1)?.unwrap_or_else(|| id.clone()),
            id,
            dir: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
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
    if !crate::cli_sessions::valid_id(session_id) {
        return Vec::new();
    }
    let Ok(conn) = open() else { return Vec::new() };
    transcript_in(&conn, session_id)
}

fn transcript_in(conn: &Connection, session_id: &str) -> Vec<ChatLine> {
    // The newest parts first, a bounded number, with only the role of their
    // message: a long session's thousands of parts and tool outputs stay in the DB.
    let mut stmt = match conn.prepare(
        "SELECT json_extract(m.data, '$.role'), p.data FROM part p \
         JOIN message m ON m.id = p.message_id \
         WHERE m.session_id = ?1 \
         ORDER BY m.time_created DESC, p.time_created DESC \
         LIMIT 400",
    ) {
        Ok(s) => s,
        Err(err) => {
            crate::cli_sessions::log_once("opencode transcript", &err.to_string());
            return Vec::new();
        }
    };
    let rows = stmt.query_map([session_id], |r| {
        Ok((r.get::<_, Option<String>>(0)?, r.get::<_, String>(1)?))
    });
    let Ok(it) = rows else { return Vec::new() };
    let rows: Vec<(Option<String>, String)> = it.flatten().collect();
    let mut lines: Vec<ChatLine> = Vec::new();
    for (role, praw) in rows.into_iter().rev() {
        let role = role.unwrap_or_default();
        let role = role.as_str();
        let Ok(part) = serde_json::from_str::<Value>(&praw) else { continue };
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
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = cli_chat::find_cli(&["opencode"])
        .ok_or("OpenCode CLI not found. Install it, then run `opencode` once.")?;
    let conn = open()?;
    let dir = session_dir(&conn, session_id).ok_or("No folder to run the session in")?;
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["run", "-s", session_id, prompt.as_str()]);
    let out = cli_chat::run(cmd, "the OpenCode CLI").await?;
    crate::cli_sessions::answer(&out, "The OpenCode CLI")
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    #[test]
    fn only_the_last_parts_are_read() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE part (id TEXT, message_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO message VALUES ('m1','ses_1',1,'{"role":"user"}'), ('m2','ses_1',2,'{"role":"assistant"}');
            INSERT INTO part VALUES ('p1','m1',1,'{"type":"text","text":"run the tests"}');
            INSERT INTO part VALUES ('p2','m2',2,'{"type":"tool","tool":"bash","state":{"title":"npm test"}}');
            INSERT INTO part VALUES ('p3','m2',3,'{"type":"text","text":"All green."}');
            "#,
        )
        .unwrap();
        let got: Vec<(String, String)> =
            transcript_in(&conn, "ses_1").into_iter().map(|l| (l.role, l.text)).collect();
        assert_eq!(
            got,
            vec![
                ("user".into(), "run the tests".into()),
                ("tool".into(), "npm test".into()),
                ("assistant".into(), "All green.".into()),
            ]
        );

        // A long session: still answers, still ends on its newest line.
        for i in 0..450 {
            conn.execute(
                "INSERT INTO part VALUES (?1, 'm2', ?2, ?3)",
                params![format!("x{i}"), 10 + i, format!(r#"{{"type":"text","text":"line {i}"}}"#)],
            )
            .unwrap();
        }
        let lines = transcript_in(&conn, "ses_1");
        assert_eq!(lines.len(), 40);
        assert_eq!(lines.last().unwrap().text, "line 449");
    }
}
