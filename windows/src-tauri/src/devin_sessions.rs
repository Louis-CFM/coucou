// Remote continuation of Devin CLI sessions: the phone picks a session from a
// list and keeps chatting in it. The list and the transcript come straight
// out of the CLI's own store (read-only SQLite — the CLI can keep writing
// while we read); a message resumes it with `devin -p <text> -r <id>`, which
// resolves the session globally and runs in the session's own folder.
//
// Unlike devin_chat (the island's private chat), no --config is passed: a
// resumed session keeps the user's real config, hooks included — so the
// session also shows up live in the island while the phone talks to it.

use std::path::PathBuf;

use rusqlite::{Connection, OpenFlags};
use serde::Serialize;

use crate::cli_chat;
use crate::devin_chat;

/// One row of the session picker.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionMeta {
    pub id: String,
    pub title: String,
    pub dir: String,
    pub model: String,
    pub last_activity_at: i64,
}

/// One chat line from a transcript — user/assistant text, or a tool call
/// (role "tool" carries `name`, the detail sits in `text`).
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatLine {
    pub role: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// `%APPDATA%\Devin\cli\sessions.db` on Windows; XDG/AppData fallbacks elsewhere.
fn db_path() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    #[cfg(windows)]
    if let Ok(roaming) = std::env::var("APPDATA") {
        candidates.push(PathBuf::from(roaming).join("Devin").join("cli").join("sessions.db"));
    }
    #[cfg(not(windows))]
    {
        let home = crate::platform::home_dir();
        candidates.push(home.join(".local/share/Devin/cli/sessions.db"));
        candidates.push(home.join(".config/devin/cli/sessions.db"));
        candidates.push(home.join("Library/Application Support/Devin/cli/sessions.db"));
    }
    candidates.into_iter().find(|p| p.is_file())
}

fn open() -> Result<Connection, String> {
    let path = db_path().ok_or("No Devin session store found — is the Devin CLI installed?")?;
    let conn = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| e.to_string())?;
    // The CLI writes constantly; give a busy reader a moment instead of failing.
    conn.busy_timeout(std::time::Duration::from_millis(1500))
        .map_err(|e| e.to_string())?;
    Ok(conn)
}

/// Recent sessions across every folder, newest first — the phone's picker.
pub fn list_recent() -> Vec<SessionMeta> {
    match open() {
        Ok(conn) => list_recent_in(&conn),
        Err(_) => Vec::new(), // no Devin installed: nothing to say
    }
}

fn list_recent_in(conn: &Connection) -> Vec<SessionMeta> {
    let mut stmt = match conn.prepare(
        "SELECT id, title, working_directory, model, last_activity_at \
         FROM sessions WHERE hidden = 0 ORDER BY last_activity_at DESC LIMIT 96",
    ) {
        Ok(s) => s,
        Err(err) => {
            crate::cli_sessions::log_once("devin sessions", &err.to_string());
            return Vec::new();
        }
    };
    let rows = stmt.query_map([], |r| {
        let id: String = r.get(0)?;
        Ok(SessionMeta {
            title: r
                .get::<_, Option<String>>(1)?
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(|| id.clone()),
            dir: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
            model: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            last_activity_at: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
            id,
        })
    });
    match rows {
        Ok(it) => it.flatten().collect(),
        Err(_) => Vec::new(),
    }
}

/// `devin -r` accepts id prefixes (that's what `devin list` prints), so we do
/// too — exact id first, then an unambiguous prefix.
fn resolve_id(conn: &Connection, session_id: &str) -> Option<String> {
    if let Ok(id) = conn.query_row("SELECT id FROM sessions WHERE id = ?1", [session_id], |r| r.get(0)) {
        return Some(id);
    }
    if session_id.len() < 4 || session_id.contains(['%', '_']) {
        return None;
    }
    let like = format!("{session_id}%");
    let mut stmt = conn
        .prepare("SELECT id FROM sessions WHERE id LIKE ?1 LIMIT 2")
        .ok()?;
    let ids: Vec<String> = stmt
        .query_map([like], |r| r.get(0))
        .ok()?
        .flatten()
        .collect();
    (ids.len() == 1).then(|| ids[0].clone())
}

/// The tail of a session's conversation — user prompts, agent answers and the
/// tool calls between them (the phone renders those as compact cards, like the
/// iOS "What it did" rows). Tool results are skipped: the calls already tell
/// the story, and outputs are huge.
///
/// message_nodes is a tree (branches re-share their history, so a flat ORDER BY
/// repeats messages). The real transcript is the path from the session's
/// main_chain_id leaf up to the root, read depth-first so it comes out
/// chronological. `chat_message` is a JSON blob {role, content, tool_calls?}.
pub fn transcript(session_id: &str) -> Vec<ChatLine> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Vec::new();
    }
    let Ok(conn) = open() else { return Vec::new() };
    let Some(session_id) = resolve_id(&conn, session_id) else {
        return Vec::new();
    };
    transcript_in(&conn, &session_id)
}

fn transcript_in(conn: &Connection, session_id: &str) -> Vec<ChatLine> {
    let mut stmt = match conn.prepare(
        "WITH RECURSIVE chain(node_id, parent_node_id, chat_message, depth) AS ( \
             SELECT m.node_id, m.parent_node_id, m.chat_message, 0 \
             FROM message_nodes m \
             WHERE m.session_id = ?1 AND m.node_id = COALESCE( \
                 (SELECT main_chain_id FROM sessions WHERE id = ?1), \
                 (SELECT MAX(node_id) FROM message_nodes WHERE session_id = ?1)) \
             UNION ALL \
             SELECT m.node_id, m.parent_node_id, m.chat_message, c.depth + 1 \
             FROM message_nodes m JOIN chain c ON m.node_id = c.parent_node_id \
             WHERE m.session_id = ?1 AND c.depth < 500 \
         ) \
         SELECT chat_message FROM chain \
         WHERE json_extract(chat_message, '$.role') IN ('user', 'assistant') \
         ORDER BY depth DESC",
    ) {
        Ok(s) => s,
        Err(err) => {
            crate::cli_sessions::log_once("devin transcript", &err.to_string());
            return Vec::new();
        }
    };
    let rows = stmt.query_map([session_id], |r| r.get::<_, String>(0));
    let Ok(it) = rows else { return Vec::new() };
    let mut lines: Vec<ChatLine> = Vec::new();
    for raw in it.flatten() {
        let Ok(msg) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };
        let Some(role) = msg.get("role").and_then(|r| r.as_str()) else {
            continue;
        };
        match role {
            "assistant" => {
                for call in msg
                    .get("tool_calls")
                    .and_then(|t| t.as_array())
                    .into_iter()
                    .flatten()
                {
                    let name = call
                        .get("name")
                        .and_then(|n| n.as_str())
                        .unwrap_or("tool");
                    lines.push(ChatLine {
                        role: "tool".into(),
                        name: Some(name.into()),
                        text: tool_detail(call.get("arguments")),
                    });
                }
                if let Some(text) = msg
                    .get("content")
                    .map(message_text)
                    .filter(|t| !t.trim().is_empty())
                {
                    lines.push(ChatLine { role: "assistant".into(), text, name: None });
                }
            }
            "user" => {
                if let Some(text) = msg
                    .get("content")
                    .map(message_text)
                    .filter(|t| !t.trim().is_empty())
                {
                    lines.push(ChatLine { role: "user".into(), text, name: None });
                }
            }
            _ => {}
        }
    }
    lines.split_at(lines.len().saturating_sub(40)).1.to_vec()
}

/// A one-line summary of a tool call's arguments — the command, then the
/// obvious path/query keys, then the first string value. Clipped so a giant
/// prompt can never blow the relay box up.
fn tool_detail(args: Option<&serde_json::Value>) -> String {
    let Some(args) = args.and_then(|a| a.as_object()) else {
        return String::new();
    };
    let mut detail = args
        .get("command")
        .or_else(|| args.get("file_path"))
        .or_else(|| args.get("path"))
        .or_else(|| args.get("url"))
        .or_else(|| args.get("pattern"))
        .or_else(|| args.get("query"))
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

/// `content` is either a plain string or an array of {type, text, …} parts.
fn message_text(content: &serde_json::Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    content
        .as_array()
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

/// Where a session's messages run — its own folder when it still exists.
fn session_dir(session_id: &str) -> Option<PathBuf> {
    let conn = open().ok()?;
    let id = resolve_id(&conn, session_id)?;
    let dir: String = conn
        .query_row(
            "SELECT working_directory FROM sessions WHERE id = ?1",
            [id],
            |r| r.get(0),
        )
        .ok()?;
    let p = PathBuf::from(dir);
    p.is_dir().then_some(p)
}

/// A phone-sent message inside a picked session. Same `devin -p` plumbing as
/// devin_chat, but resuming by id and under the user's real config — that is
/// the point: hooks fire, the session appears in the island, and its saved
/// permission mode applies.
pub async fn resume(session_id: &str, query: &str) -> Result<String, String> {
    if !crate::cli_sessions::valid_id(session_id) {
        return Err("Unknown session".into());
    }
    let cli = devin_chat::cli_path_pub()
        .ok_or("Devin CLI not found. Install it, then run `devin auth login`.")?;
    let dir = session_dir(session_id)
        .or_else(|| cli_chat::workdir("devin-chat").ok())
        .ok_or("No folder to run the session in")?;
    let mut cmd = cli_chat::command(&cli);
    let prompt = crate::cli_sessions::prompt_arg(query, &cli);
    cmd.current_dir(&dir).args(["-p", prompt.as_str(), "-r", session_id]);
    let out = cli_chat::run(cmd, "the Devin CLI").await?;
    devin_chat::parse_answer_pub(out.status.success(), &out.stdout, &out.stderr)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE sessions (id TEXT, title TEXT, working_directory TEXT, model TEXT,
                                   last_activity_at INTEGER, hidden INTEGER, main_chain_id INTEGER);
            CREATE TABLE message_nodes (node_id INTEGER, parent_node_id INTEGER, session_id TEXT, chat_message TEXT);
            INSERT INTO sessions VALUES ('s-1', NULL, NULL, NULL, NULL, 0, 4);
            INSERT INTO message_nodes VALUES (1, NULL, 's-1', '{"role":"user","content":"list files"}');
            INSERT INTO message_nodes VALUES (2, 1, 's-1', '{"role":"assistant","content":"","tool_calls":[{"name":"exec","arguments":{"command":"ls"}}]}');
            INSERT INTO message_nodes VALUES (3, 2, 's-1', '{"role":"tool","content":"a.txt b.txt"}');
            INSERT INTO message_nodes VALUES (4, 3, 's-1', '{"role":"assistant","content":"Two files."}');
            "#,
        )
        .unwrap();
        conn
    }

    #[test]
    fn a_session_without_a_title_is_still_listed() {
        let list = list_recent_in(&db());
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "s-1");
        assert_eq!(list[0].title, "s-1");
        assert_eq!(list[0].dir, "");
        assert_eq!(list[0].last_activity_at, 0);
    }

    #[test]
    fn tool_results_stay_out_of_the_transcript() {
        let got: Vec<(String, String)> =
            transcript_in(&db(), "s-1").into_iter().map(|l| (l.role, l.text)).collect();
        assert_eq!(
            got,
            vec![
                ("user".into(), "list files".into()),
                ("tool".into(), "ls".into()),
                ("assistant".into(), "Two files.".into()),
            ]
        );
    }
}
