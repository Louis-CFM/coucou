// Mochi's session manager: the Claude Code sessions of the Claude Code Mochi
// uses (Settings → "Use for Mochi"), read straight from its transcripts.
//
// Claude Code keeps one transcript per session, `~/.claude/projects/<project>/
// <session-id>.jsonl`, every line a JSON record. Every session there is listed
// — terminal ones too — with its working folder and title, so Mochi can carry
// any of them on (`claude -p --resume`). For a WSL Claude Code the folder is
// reached through `\\wsl.localhost`.
//
// Deleting a session erases its transcript: the island asks for a second click
// first, and only a file named after a session id, inside `projects`, is ever
// removed.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use serde::Serialize;
use serde_json::Value;

use crate::local_claude::Backend;

/// The island's menu shows the most recent ones; older sessions stay on disk.
const MAX_LISTED: usize = 50;
/// The conversation view shows the end of a long session, not all of it.
const MAX_HISTORY: usize = 40;
/// Head and tail read to find a session's folder and title without loading a
/// transcript that can run to megabytes — over 9P for WSL, that matters.
const PEEK: u64 = 96 * 1024;

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    pub id: String,
    /// The working folder, as that Claude Code sees it (Linux path under WSL).
    pub cwd: String,
    pub title: String,
    /// Last change, milliseconds since the epoch.
    pub updated: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryItem {
    pub role: &'static str,
    pub text: String,
}

/// `~/.claude/projects` of the Claude Code Mochi uses.
fn projects_dir(backend: &Backend) -> Result<PathBuf, String> {
    match backend {
        Backend::Api => Err("Sessions need Claude Code: turn on \"Use for Mochi\" in Settings.".into()),
        Backend::Windows => Ok(crate::platform::home_dir().join(".claude").join("projects")),
        Backend::Wsl(distro) => Ok(crate::wsl::home_unc(distro)?.join(".claude").join("projects")),
    }
}

/// Session ids are UUIDs; nothing else is ever turned into a path.
pub fn is_session_id(id: &str) -> bool {
    id.len() == 36
        && id.chars().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) { c == '-' } else { c.is_ascii_hexdigit() }
        })
}

fn transcripts(projects: &Path) -> Vec<(PathBuf, u64)> {
    let mut out = Vec::new();
    let Ok(dirs) = std::fs::read_dir(projects) else { return out };
    for dir in dirs.flatten() {
        let Ok(files) = std::fs::read_dir(dir.path()) else { continue };
        for file in files.flatten() {
            let path = file.path();
            let is_session = path.extension().is_some_and(|e| e == "jsonl")
                && path.file_stem().and_then(|s| s.to_str()).is_some_and(is_session_id);
            if !is_session {
                continue;
            }
            let modified = file
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            out.push((path, modified));
        }
    }
    out
}

/// Reads `len` bytes from the start (or the end) of a file, cut back to whole lines.
fn peek(path: &Path, from_end: bool) -> String {
    let Ok(mut f) = std::fs::File::open(path) else { return String::new() };
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = if from_end { size.saturating_sub(PEEK) } else { 0 };
    if f.seek(SeekFrom::Start(start)).is_err() {
        return String::new();
    }
    let mut buf = Vec::new();
    let _ = f.take(PEEK).read_to_end(&mut buf);
    let text = String::from_utf8_lossy(&buf).into_owned();
    // A window into the middle of a file starts and ends on broken lines.
    let text = if start > 0 { text.split_once('\n').map(|x| x.1.to_string()).unwrap_or_default() } else { text };
    match text.rfind('\n') {
        Some(i) => text[..i].to_string(),
        None if start == 0 && (size as usize) <= buf.len() => text,
        None => String::new(),
    }
}

fn records(text: &str) -> impl Iterator<Item = Value> + '_ {
    text.lines().filter_map(|l| serde_json::from_str::<Value>(l).ok())
}

/// The words of a user message, or None for what isn't one the user typed:
/// tool results, meta lines, slash-command plumbing.
fn user_text(rec: &Value) -> Option<String> {
    if rec.get("isMeta").and_then(Value::as_bool) == Some(true)
        || rec.get("isSidechain").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let content = rec.get("message")?.get("content")?;
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return None,
    };
    let t = text.trim();
    let plumbing = t.starts_with("<command-") || t.starts_with("<local-command") || t.starts_with("Caveat:");
    (!t.is_empty() && !plumbing).then(|| t.to_string())
}

fn assistant_text(rec: &Value) -> Option<String> {
    if rec.get("isSidechain").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let parts = rec.get("message")?.get("content")?.as_array()?;
    let text = parts
        .iter()
        .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|p| p.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let t = text.trim();
    (!t.is_empty()).then(|| t.to_string())
}

fn one_line(s: &str, max: usize) -> String {
    let flat = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        flat
    } else {
        format!("{}…", flat.chars().take(max).collect::<String>())
    }
}

fn describe(path: &Path, updated: u64) -> Option<SessionInfo> {
    let id = path.file_stem()?.to_str()?.to_string();
    let head = peek(path, false);
    let mut cwd = None;
    let mut first_prompt = None;
    let mut title = None;
    for rec in records(&head) {
        if cwd.is_none() {
            cwd = rec.get("cwd").and_then(Value::as_str).map(str::to_string);
        }
        match rec.get("type").and_then(Value::as_str) {
            Some("user") if first_prompt.is_none() => first_prompt = user_text(&rec),
            Some("ai-title") => title = rec.get("aiTitle").and_then(Value::as_str).map(str::to_string),
            _ => {}
        }
    }
    // The title Claude Code keeps refining is near the end of the file.
    for rec in records(&peek(path, true)) {
        if rec.get("type").and_then(Value::as_str) == Some("ai-title") {
            if let Some(t) = rec.get("aiTitle").and_then(Value::as_str) {
                title = Some(t.to_string());
            }
        }
    }
    let cwd = cwd?;
    let title = title
        .or(first_prompt)
        .map(|t| one_line(&t, 60))
        .unwrap_or_else(|| "Untitled session".into());
    Some(SessionInfo { id, cwd, title, updated })
}

/// The most recent sessions, newest first.
pub fn list(backend: &Backend) -> Result<Vec<SessionInfo>, String> {
    let mut files = transcripts(&projects_dir(backend)?);
    files.sort_by(|a, b| b.1.cmp(&a.1));
    Ok(files
        .into_iter()
        .take(MAX_LISTED)
        .filter_map(|(p, t)| describe(&p, t))
        .collect())
}

fn find(backend: &Backend, id: &str) -> Result<PathBuf, String> {
    if !is_session_id(id) {
        return Err("Not a session id.".into());
    }
    let projects = projects_dir(backend)?;
    transcripts(&projects)
        .into_iter()
        .map(|(p, _)| p)
        .find(|p| p.file_stem().and_then(|s| s.to_str()) == Some(id))
        .ok_or_else(|| "That session is gone.".into())
}

/// What was said, user and assistant, without the tool calls in between.
pub fn history(backend: &Backend, id: &str) -> Result<Vec<HistoryItem>, String> {
    let text = std::fs::read_to_string(find(backend, id)?).map_err(|e| e.to_string())?;
    let mut items: Vec<HistoryItem> = Vec::new();
    for rec in records(&text) {
        let item = match rec.get("type").and_then(Value::as_str) {
            Some("user") => user_text(&rec).map(|text| HistoryItem { role: "user", text }),
            Some("assistant") => assistant_text(&rec).map(|text| HistoryItem { role: "assistant", text }),
            _ => None,
        };
        let Some(item) = item else { continue };
        // A turn is often several records; show it as one reply.
        match items.last_mut() {
            Some(last) if last.role == "assistant" && item.role == "assistant" => {
                last.text.push_str("\n\n");
                last.text.push_str(&item.text);
            }
            _ => items.push(item),
        }
    }
    let skip = items.len().saturating_sub(MAX_HISTORY);
    Ok(items.into_iter().skip(skip).collect())
}

/// Erases a session's transcript, and the folder Claude Code keeps beside it
/// for that session (subagents, tool output) if there is one.
pub fn delete(backend: &Backend, id: &str) -> Result<(), String> {
    let file = find(backend, id)?;
    let projects = projects_dir(backend)?;
    if !file.starts_with(&projects) {
        return Err("Refusing to delete outside Claude Code's projects folder.".into());
    }
    std::fs::remove_file(&file).map_err(|e| format!("Could not delete the session: {e}"))?;
    let side = file.with_extension("");
    if side.is_dir() && side.file_name().and_then(|s| s.to_str()) == Some(id) {
        let _ = std::fs::remove_dir_all(side);
    }
    Ok(())
}

/// The folder picker, for a new session in a folder of the user's choosing.
/// Returns the path as the backend's Claude Code will see it.
pub fn pick_folder(backend: &Backend, owner: Option<isize>) -> Result<Option<String>, String> {
    let Some(picked) = folder_dialog(owner) else { return Ok(None) };
    match backend {
        Backend::Api => Err("Sessions need Claude Code.".into()),
        Backend::Windows => Ok(Some(picked)),
        Backend::Wsl(distro) => crate::wsl::to_linux_path(distro, &picked).map(Some),
    }
}

/// No folder dialog of our own outside Windows yet: "New in a folder…" finds
/// nothing picked there, as if it were cancelled.
#[cfg(not(windows))]
fn folder_dialog(_owner: Option<isize>) -> Option<String> {
    None
}

/// The shell's own folder dialog, on a thread of its own: it needs a COM
/// apartment and runs a modal loop, neither of which belongs on the main thread.
#[cfg(windows)]
fn folder_dialog(owner: Option<isize>) -> Option<String> {
    use windows::core::w;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_INPROC_SERVER,
        COINIT_APARTMENTTHREADED,
    };
    use windows::Win32::UI::Shell::{
        FileOpenDialog, IFileOpenDialog, FOS_FORCEFILESYSTEM, FOS_PICKFOLDERS, SIGDN_FILESYSPATH,
    };

    std::thread::spawn(move || unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let picked = (|| {
            let dialog: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER).ok()?;
            let options = dialog.GetOptions().ok()?;
            dialog.SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM).ok()?;
            let _ = dialog.SetTitle(w!("A folder for a new Mochi session"));
            // Owned by the island, so it comes up above it rather than behind.
            let owner = owner.map(|h| HWND(h as *mut _));
            dialog.Show(owner).ok()?; // cancelled → Err
            let item = dialog.GetResult().ok()?;
            let raw = item.GetDisplayName(SIGDN_FILESYSPATH).ok()?;
            let path = raw.to_string().ok();
            CoTaskMemFree(Some(raw.0 as *const _));
            path
        })();
        CoUninitialize();
        picked
    })
    .join()
    .ok()
    .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_uuids_are_session_ids() {
        assert!(is_session_id("b015262a-3d5d-46cc-b71d-8f56527dee84"));
        assert!(!is_session_id("../../settings"));
        assert!(!is_session_id("b015262a3d5d46ccb71d8f56527dee84"));
        assert!(!is_session_id("b015262a-3d5d-46cc-b71d-8f56527dee8z"));
    }

    #[test]
    fn a_transcript_gives_its_folder_title_and_conversation() {
        let dir = std::env::temp_dir().join(format!("coucou-sessions-{}", std::process::id()));
        let project = dir.join("-home-me-proj");
        std::fs::create_dir_all(&project).unwrap();
        let id = "11111111-2222-3333-4444-555555555555";
        let lines = [
            r#"{"type":"permission-mode","permissionMode":"default","sessionId":"x"}"#,
            r#"{"type":"user","cwd":"/home/me/proj","isSidechain":false,"message":{"role":"user","content":"Fix the login bug please"}}"#,
            r#"{"type":"assistant","cwd":"/home/me/proj","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":"…"}]}}"#,
            r#"{"type":"assistant","cwd":"/home/me/proj","isSidechain":false,"message":{"content":[{"type":"tool_use","name":"Read"}]}}"#,
            r#"{"type":"user","cwd":"/home/me/proj","isSidechain":false,"message":{"content":[{"type":"tool_result","content":"…"}]}}"#,
            r#"{"type":"assistant","cwd":"/home/me/proj","isSidechain":false,"message":{"content":[{"type":"text","text":"Found it."}]}}"#,
            r#"{"type":"assistant","cwd":"/home/me/proj","isSidechain":false,"message":{"content":[{"type":"text","text":"Fixed in auth.ts."}]}}"#,
            r#"{"type":"user","cwd":"/home/me/proj","isMeta":true,"message":{"content":"<local-command-stdout>x</local-command-stdout>"}}"#,
            r#"{"type":"ai-title","aiTitle":"Fix login bug","sessionId":"x"}"#,
        ];
        std::fs::write(project.join(format!("{id}.jsonl")), lines.join("\n") + "\n").unwrap();
        std::fs::write(project.join("not-a-session.jsonl"), "{}\n").unwrap();

        let files = transcripts(&dir);
        assert_eq!(files.len(), 1, "only files named after a session id count");
        let info = describe(&files[0].0, files[0].1).unwrap();
        assert_eq!(info.cwd, "/home/me/proj");
        assert_eq!(info.title, "Fix login bug");

        // History without tool calls, thinking or meta lines; one reply per turn.
        let text = std::fs::read_to_string(&files[0].0).unwrap();
        let mut seen = Vec::new();
        for rec in records(&text) {
            match rec.get("type").and_then(Value::as_str) {
                Some("user") => seen.extend(user_text(&rec).map(|t| ("user", t))),
                Some("assistant") => seen.extend(assistant_text(&rec).map(|t| ("assistant", t))),
                _ => {}
            }
        }
        assert_eq!(
            seen,
            vec![
                ("user", "Fix the login bug please".to_string()),
                ("assistant", "Found it.".to_string()),
                ("assistant", "Fixed in auth.ts.".to_string()),
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
