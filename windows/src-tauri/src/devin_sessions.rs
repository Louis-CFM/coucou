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
    let Ok(conn) = open() else { return Vec::new() };
    let mut stmt = match conn.prepare(
        "SELECT id, title, working_directory, model, last_activity_at \
         FROM sessions WHERE hidden = 0 ORDER BY last_activity_at DESC LIMIT 96",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([], |r| {
        Ok(SessionMeta {
            id: r.get(0)?,
            title: r.get(1)?,
            dir: r.get(2)?,
            model: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
            last_activity_at: r.get(4)?,
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
    let Ok(conn) = open() else { return Vec::new() };
    let Some(session_id) = resolve_id(&conn, session_id) else {
        return Vec::new();
    };
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
         SELECT chat_message FROM chain ORDER BY depth DESC",
    ) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let rows = stmt.query_map([&session_id], |r| r.get::<_, String>(0));
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
    let cli = devin_chat::cli_path_pub()
        .ok_or("Devin CLI not found. Install it, then run `devin auth login`.")?;
    let dir = session_dir(session_id)
        .or_else(|| cli_chat::workdir("devin-chat").ok())
        .ok_or("No folder to run the session in")?;
    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args(["-p", query, "-r", session_id]);
    let out = cli_chat::run(cmd, "the Devin CLI").await?;
    devin_chat::parse_answer_pub(out.status.success(), &out.stdout, &out.stderr)
}
