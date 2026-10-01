//! coucou-hook — the relay Claude Code runs on every hook event.
//!
//! Reads the hook JSON on stdin, adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<sid>`.
//!
//! Hard rule (docs/CLAUDE.md): **never block Claude Code.**
//! * If the pipe does not exist — Coucou is closed — we exit 0 immediately with
//!   nothing on stdout, and the session carries on untouched.
//! * Every step runs under a deadline enforced by the main thread, so a pipe that
//!   accepts the connection and then stops reading cannot wedge the session
//!   either: we abandon the worker and exit.
//! * Only `PermissionRequest` waits for an answer, because approving from the
//!   island is the whole point. No answer means empty stdout, and Claude Code
//!   asks in the terminal exactly as if Coucou were not installed.
//!
//! Usage:
//! * `coucou-hook <EventName>` — Claude Code. The name is also read from the JSON.
//! * `coucou-hook --cursor` — Cursor agent hooks. Ordinary work (reads, edits
//!   inside the project, sandboxed commands) is allowed straight away. Coucou
//!   asks only when Cursor itself would: a command that cannot stay in the
//!   sandbox, a file delete, or a change outside the workspace. No click on
//!   one of those means deny.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Budget for getting a pipe connection. Beyond this Claude Code wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);
/// Cursor hooks that only observe. Long enough to hand the event over, short
/// enough that a missing pipe cannot sit on a tool call.
const CURSOR_BUDGET: Duration = Duration::from_millis(800);
/// How long a Cursor permission may stay on screen. Same budget as Claude Code.
/// The hooks.json timeout is longer (120 s) and `failClosed`, so if this
/// process is killed first the tool is blocked rather than allowed.
const CURSOR_DECISION_BUDGET: Duration = Duration::from_secs(110);

/// `ERROR_PIPE_BUSY` — every instance is serving someone else right now. This is
/// the one error worth retrying: the server exists and a slot will free up.
const ERROR_PIPE_BUSY: i32 = 231;

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output). The island never shows them.
const DROPPED_FIELDS: &[&str] = &["tool_response", "transcript_path"];
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;

mod win;

/// `\\.\pipe\coucou-<sid>`. The SID keeps two accounts on the same machine from
/// ever meeting on the same pipe; the name falls back to the user name only if
/// the SID cannot be read at all, which should not happen.
fn pipe_path() -> String {
    let key = win::current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

/// Opens the pipe. Retries only while the server is busy: any other error means
/// there is nothing to talk to, and waiting would only delay Claude Code.
fn connect() -> Option<std::fs::File> {
    use std::os::windows::io::AsRawHandle;
    let path = pipe_path();
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match std::fs::OpenOptions::new().read(true).write(true).open(&path) {
            Ok(file) => {
                let handle = windows::Win32::Foundation::HANDLE(file.as_raw_handle());
                // Somebody else's server on our pipe name gets nothing from us.
                return win::pipe_server_is_same_user(handle).then_some(file);
            }
            Err(err) => {
                if err.raw_os_error() != Some(ERROR_PIPE_BUSY) || Instant::now() >= deadline {
                    return None;
                }
                std::thread::sleep(Duration::from_millis(15));
            }
        }
    }
}

fn main() {
    if std::env::args().skip(1).any(|arg| arg == "--cursor") {
        run_cursor();
    }

    let Some((payload, event)) = read_event() else { std::process::exit(0) };

    let waits_for_answer = event == "PermissionRequest";
    let budget = if waits_for_answer { DECISION_BUDGET } else { FIRE_AND_FORGET_BUDGET };

    // The worker owns every blocking call. If it overruns the budget we simply
    // stop listening and exit: the process dying takes the pipe handle with it.
    // (No catch_unwind here — the release profile is panic = "abort", so it would
    // be dead code. `talk` is written to have nothing to panic on instead.)
    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&payload, waits_for_answer));
    });

    if let Ok(Some(decision)) = rx.recv_timeout(budget) {
        if let Some(json) = decision_json(&decision) {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{json}");
            let _ = out.flush();
        }
    }
    // Nothing printed: Claude Code asks in the terminal, as if we were not here.
    std::process::exit(0);
}

/// Fields Cursor puts on the payload that Coucou must not keep: an email
/// address, a transcript, or a whole tool result.
const CURSOR_DROPPED: &[&str] = &["user_email", "transcript_path", "tool_output"];

/// Printed when the event cannot be read. Covers both permission hooks
/// (`preToolUse`, `subagentStart`) and `beforeSubmitPrompt`: an empty or
/// invalid stdout on those events blocks the agent.
const CURSOR_SAFE: &str = r#"{"permission":"allow","continue":true}"#;
const CURSOR_ALLOW: &str = r#"{"permission":"allow"}"#;
const CURSOR_DENY: &str = r#"{"permission":"deny","user_message":"Denied from Coucou","agent_message":"Denied from Coucou"}"#;

struct CursorEvent {
    line: Option<String>,
    /// Printed when we are not waiting on a click. Also the fallback if a wait
    /// produces nothing: silence on these hooks blocks the agent.
    reply: &'static str,
    wait: bool,
}

/// Cursor mode. Always exits. A permission with nobody to answer it is denied.
fn run_cursor() -> ! {
    let mut raw = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut raw);
    let prepared = if raw.is_empty() {
        CursorEvent { line: None, reply: CURSOR_SAFE, wait: false }
    } else {
        prepare_cursor(&raw)
    };

    let reply = if prepared.wait {
        match prepared.line {
            Some(payload) => wait_cursor_decision(&payload),
            None => CURSOR_DENY.to_string(),
        }
    } else {
        if let Some(payload) = prepared.line {
            let (tx, rx) = mpsc::channel::<()>();
            std::thread::spawn(move || {
                let _ = talk(&payload, false);
                let _ = tx.send(());
            });
            let _ = rx.recv_timeout(CURSOR_BUDGET);
        }
        prepared.reply.to_string()
    };

    let mut out = std::io::stdout();
    let _ = writeln!(out, "{reply}");
    let _ = out.flush();
    std::process::exit(0);
}

/// Same moments Claude's PermissionRequest covers, expressed with what Cursor
/// actually sends. Edits inside the project are ordinary work.
///
/// Shell is decided on `beforeShellExecution`, where `sandbox` says whether
/// Cursor would ask. Waiting on `preToolUse` Shell as well would ask twice.
fn cursor_waits(event: &str, map: &serde_json::Map<String, serde_json::Value>) -> bool {
    match event {
        // `sandbox: false` is a command that needs full access. Cursor asks
        // before those. A sandboxed command, or one with no flag, is not an ask.
        "beforeShellExecution" => map.get("sandbox").and_then(|v| v.as_bool()) == Some(false),
        "preToolUse" => pre_tool_needs_permission(map),
        _ => false,
    }
}

fn pre_tool_needs_permission(map: &serde_json::Map<String, serde_json::Value>) -> bool {
    let tool = map.get("tool_name").and_then(|v| v.as_str()).unwrap_or("");
    match tool {
        // File-deletion protection: Cursor does not delete on its own.
        "Delete" => true,
        // External-file protection: a write outside the workspace.
        "Write" | "Edit" | "StrReplace" | "MultiEdit" | "EditNotebook" | "NotebookEdit" => {
            path_outside_workspace(map)
        }
        _ => false,
    }
}

fn tool_path(map: &serde_json::Map<String, serde_json::Value>) -> &str {
    let Some(input) = map.get("tool_input").and_then(|v| v.as_object()) else {
        return "";
    };
    for key in ["path", "file_path", "target_file"] {
        if let Some(path) = input.get(key).and_then(|v| v.as_str()) {
            if !path.is_empty() {
                return path;
            }
        }
    }
    ""
}

fn is_absolute(path: &str) -> bool {
    let slash = path.replace('/', "\\");
    slash.starts_with("\\\\")
        || path.starts_with('/')
        || (slash.len() >= 3 && slash.as_bytes()[1] == b':' && slash.as_bytes()[2] == b'\\')
}

fn normalize_path(path: &str) -> String {
    let mut s = path.replace('/', "\\");
    while s.len() > 3 && s.ends_with('\\') {
        s.pop();
    }
    s.to_ascii_lowercase()
}

/// True only when the path is absolute and sits under none of the workspace
/// roots. A relative path, or a payload with no roots, is project work.
fn path_outside_workspace(map: &serde_json::Map<String, serde_json::Value>) -> bool {
    let path = tool_path(map);
    if !is_absolute(path) {
        return false;
    }
    let Some(roots) = map.get("workspace_roots").and_then(|v| v.as_array()) else {
        return false;
    };
    let path_n = normalize_path(path);
    let mut compared = false;
    for root in roots {
        let Some(root) = root.as_str().filter(|s| !s.is_empty()) else { continue };
        compared = true;
        let root_n = normalize_path(root);
        if path_n == root_n || path_n.starts_with(&(root_n + "\\")) {
            return false;
        }
    }
    compared
}

/// The word Coucou wrote back. Only an explicit allow lets the tool run.
fn cursor_decision_json(decision: &str) -> String {
    match decision.trim() {
        "allow" | "always" => CURSOR_ALLOW.to_string(),
        _ => CURSOR_DENY.to_string(),
    }
}

/// Waits for a click. No pipe, no ack, no click: deny, so the tool does not run
/// without an answer.
fn wait_cursor_decision(payload: &str) -> String {
    let (tx, rx) = mpsc::channel::<Option<String>>();
    let owned = payload.to_string();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&owned, true));
    });
    let word = match rx.recv_timeout(CURSOR_DECISION_BUDGET) {
        Ok(Some(word)) => word,
        _ => "deny".to_string(),
    };
    cursor_decision_json(&word)
}

/// Stdout Cursor actually enforces when we are not waiting. Anything else is
/// `{}` — never a follow-up. See https://cursor.com/docs/hooks
fn cursor_reply(event: &str) -> &'static str {
    match event {
        // beforeShellExecution must be a permission object. `{}` does not match
        // the schema, and Cursor then blocks the command.
        "preToolUse" | "subagentStart" | "beforeShellExecution" => CURSOR_ALLOW,
        "beforeSubmitPrompt" => r#"{"continue":true}"#,
        _ => "{}",
    }
}

/// Builds the line forwarded to Coucou and the stdout Cursor must see.
fn prepare_cursor(raw: &[u8]) -> CursorEvent {
    let text = raw.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(raw);
    let mut payload = match serde_json::from_slice::<serde_json::Value>(text) {
        Ok(value) if value.is_object() => value,
        _ => return CursorEvent { line: None, reply: CURSOR_SAFE, wait: false },
    };
    let Some(map) = payload.as_object_mut() else {
        return CursorEvent { line: None, reply: CURSOR_SAFE, wait: false };
    };

    for field in CURSOR_DROPPED {
        map.remove(*field);
    }

    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let wait = cursor_waits(&event, map);
    if wait {
        map.insert("await_decision".into(), serde_json::Value::Bool(true));
    }
    map.insert("source".into(), serde_json::Value::String("cursor".into()));

    let cwd_missing = map
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(str::is_empty)
        .unwrap_or(true);
    if cwd_missing {
        // User hooks run from ~/.cursor, so the process cwd is not the project.
        // CURSOR_PROJECT_DIR is the workspace; current_dir is only a last resort.
        let cwd = std::env::var("CURSOR_PROJECT_DIR")
            .ok()
            .filter(|s| !s.is_empty())
            .or_else(|| {
                std::env::current_dir()
                    .ok()
                    .map(|p| p.to_string_lossy().into_owned())
            });
        if let Some(cwd) = cwd {
            map.insert("cwd".into(), serde_json::Value::String(cwd));
        }
    }

    truncate_strings(&mut payload);
    let mut line = payload.to_string();
    line.push('\n');
    CursorEvent { line: Some(line), reply: cursor_reply(&event), wait }
}

/// The documented PermissionRequest output. Anything we do not recognise prints
/// nothing at all rather than guessing — silence is the safe answer.
/// See https://code.claude.com/docs/en/hooks
fn decision_json(decision: &str) -> Option<String> {
    let behavior = match decision.trim() {
        // "always" still answers a plain allow; remembering it is the island's
        // business, not Claude Code's.
        "allow" | "always" => r#"{"behavior":"allow"}"#.to_string(),
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#.to_string(),
        _ => return None,
    };
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#
    ))
}

/// Reads stdin and returns the payload to forward plus the event name.
fn read_event() -> Option<(String, String)> {
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_err() || raw.is_empty() {
        return None;
    }
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }

    let mut payload = serde_json::from_slice::<serde_json::Value>(&raw).ok()?;
    let map = payload.as_object_mut()?;

    // The event name is passed as argv[1] by the hook command; the JSON usually
    // carries it too. Trust argv when the JSON is missing it.
    let arg_event = std::env::args().nth(1).unwrap_or_default();
    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or(arg_event);
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    for field in DROPPED_FIELDS {
        map.remove(*field);
    }

    let cwd_missing = map
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(str::is_empty)
        .unwrap_or(true);
    if cwd_missing {
        if let Ok(cwd) = std::env::current_dir() {
            map.insert(
                "cwd".into(),
                serde_json::Value::String(cwd.to_string_lossy().to_string()),
            );
        }
    }

    // Which terminal the session runs in. Unlike macOS, Coucou on Windows accepts
    // events from every terminal, so this is context only — never a filter.
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
    ] {
        if !map.contains_key(key) {
            let value = std::env::var(var).unwrap_or_default();
            map.insert(key.into(), serde_json::Value::String(value));
        }
    }

    truncate_strings(&mut payload);

    let mut line = payload.to_string();
    line.push('\n');
    Some((line, event))
}

/// Caps every string in the payload. A single Write can carry a whole file.
/// `output` keeps its tail: a test run prints the PASS / FAIL line last.
fn truncate_strings(value: &mut serde_json::Value) {
    truncate_node(value, false);
}

fn truncate_node(value: &mut serde_json::Value, tail: bool) {
    match value {
        serde_json::Value::String(s) => clip_string(s, tail),
        serde_json::Value::Array(items) => {
            for item in items {
                truncate_node(item, tail);
            }
        }
        serde_json::Value::Object(map) => {
            for (key, child) in map.iter_mut() {
                truncate_node(child, tail || key == "output");
            }
        }
        _ => {}
    }
}

fn clip_string(s: &mut String, tail: bool) {
    if s.len() <= MAX_FIELD_LEN {
        return;
    }
    if tail {
        let mut start = s.len().saturating_sub(MAX_FIELD_LEN);
        while start < s.len() && !s.is_char_boundary(start) {
            start += 1;
        }
        s.replace_range(..start, "");
        s.insert(0, '…');
        return;
    }
    // Cut on a char boundary; a lone byte index can split UTF-8.
    let mut end = MAX_FIELD_LEN;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s.truncate(end);
    s.push('…');
}

/// Connect, send, and — for a permission request — wait for the island's word.
fn talk(payload: &str, waits_for_answer: bool) -> Option<String> {
    let mut pipe = connect()?;

    if pipe.write_all(payload.as_bytes()).is_err() {
        return None;
    }
    let _ = pipe.flush();

    if !waits_for_answer {
        return None;
    }

    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let answer = String::from_utf8_lossy(&buf).trim().to_string();
    (!answer.is_empty()).then_some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decision_json_matches_the_documented_shape() {
        assert_eq!(
            decision_json("allow").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        );
        assert_eq!(
            decision_json("deny").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#
        );
        // "always" is an island concept; Claude Code just gets an allow.
        assert!(decision_json("always").unwrap().contains(r#""behavior":"allow""#));
    }

    #[test]
    fn anything_unrecognised_prints_nothing() {
        assert!(decision_json("").is_none());
        assert!(decision_json("maybe").is_none());
        // The shape the app used to send must not be mistaken for a decision.
        assert!(decision_json(r#"{"permissionDecision":"allow"}"#).is_none());
    }

    #[test]
    fn cursor_replies_allow_and_never_a_followup() {
        assert_eq!(cursor_reply("preToolUse"), r#"{"permission":"allow"}"#);
        assert_eq!(cursor_reply("subagentStart"), r#"{"permission":"allow"}"#);
        assert_eq!(cursor_reply("beforeSubmitPrompt"), r#"{"continue":true}"#);
        assert_eq!(cursor_reply("stop"), "{}");
        assert_eq!(cursor_reply("sessionStart"), "{}");
        assert!(!cursor_reply("stop").contains("followup"));
        assert!(!cursor_reply("preToolUse").contains("deny"));
    }

    #[test]
    fn cursor_payload_drops_private_fields_and_marks_its_source() {
        let raw = br#"{"hook_event_name":"preToolUse","user_email":"a@b.c","transcript_path":"t","tool_output":"huge","tool_name":"Shell","cwd":"C:/repo"}"#;
        let prepared = prepare_cursor(raw);
        // A Shell preToolUse is not itself the permission ask.
        assert!(!prepared.wait);
        assert_eq!(prepared.reply, CURSOR_ALLOW);
        let line = prepared.line.expect("a valid event is forwarded");
        let v: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(v["source"], "cursor");
        assert_eq!(v["tool_name"], "Shell");
        assert!(v.get("await_decision").is_none());
        assert!(v.get("user_email").is_none());
        assert!(v.get("transcript_path").is_none());
        assert!(v.get("tool_output").is_none());
    }

    #[test]
    fn a_read_is_forwarded_without_waiting_for_a_click() {
        let raw = br#"{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"path":"a.ts"}}"#;
        let prepared = prepare_cursor(raw);
        assert!(!prepared.wait);
        assert_eq!(prepared.reply, CURSOR_ALLOW);
        let v: serde_json::Value = serde_json::from_str(prepared.line.unwrap().trim()).unwrap();
        assert!(v.get("await_decision").is_none());
    }

    #[test]
    fn a_cursor_deny_is_the_documented_permission_object() {
        assert_eq!(
            cursor_decision_json("deny"),
            r#"{"permission":"deny","user_message":"Denied from Coucou","agent_message":"Denied from Coucou"}"#
        );
        assert_eq!(cursor_decision_json("allow"), CURSOR_ALLOW);
        assert_eq!(cursor_decision_json("deny"), CURSOR_DENY);
        // Anything that is not an explicit allow must not let the tool run.
        assert_eq!(cursor_decision_json("maybe"), CURSOR_DENY);
        assert_eq!(cursor_decision_json(""), CURSOR_DENY);
    }

    #[test]
    fn asks_only_where_cursor_itself_would() {
        let parsed = |raw: &str| {
            serde_json::from_str::<serde_json::Value>(raw)
                .unwrap()
                .as_object()
                .unwrap()
                .clone()
        };
        let unsandboxed = parsed(r#"{"sandbox":false,"command":"rm -rf build"}"#);
        let sandboxed = parsed(r#"{"sandbox":true,"command":"npm test"}"#);
        assert!(cursor_waits("beforeShellExecution", &unsandboxed));
        assert!(!cursor_waits("beforeShellExecution", &sandboxed));
        assert!(!cursor_waits("beforeShellExecution", &parsed(r#"{"command":"npm test"}"#)));

        assert!(cursor_waits("preToolUse", &parsed(r#"{"tool_name":"Delete"}"#)));
        assert!(!cursor_waits(
            "preToolUse",
            &parsed(r#"{"tool_name":"StrReplace","tool_input":{"path":"C:/repo/a.ts"},"workspace_roots":["C:/repo"]}"#)
        ));
        assert!(cursor_waits(
            "preToolUse",
            &parsed(r#"{"tool_name":"Write","tool_input":{"path":"D:/secrets/.env"},"workspace_roots":["C:/repo"]}"#)
        ));
        assert!(!cursor_waits("preToolUse", &parsed(r#"{"tool_name":"Read"}"#)));
        assert!(!cursor_waits("preToolUse", &parsed(r#"{"tool_name":"Shell"}"#)));
        assert!(!cursor_waits("preToolUse", &parsed(r#"{"tool_name":"Grep"}"#)));
        assert!(!cursor_waits("stop", &parsed(r#"{"tool_name":"Shell"}"#)));
    }

    #[test]
    fn cursor_garbage_still_allows_the_action() {
        let prepared = prepare_cursor(b"not json");
        assert!(prepared.line.is_none());
        assert!(!prepared.wait);
        assert_eq!(prepared.reply, CURSOR_SAFE);
    }

    #[test]
    fn long_strings_are_cut_on_a_char_boundary() {
        let mut v = serde_json::json!({ "tool_input": { "content": "é".repeat(4000) } });
        truncate_strings(&mut v);
        let s = v["tool_input"]["content"].as_str().unwrap();
        assert!(s.len() <= MAX_FIELD_LEN + 4);
        assert!(s.ends_with('…'));
    }

    #[test]
    fn command_output_keeps_its_tail() {
        let mut v = serde_json::json!({ "output": format!("HEAD{}", "z".repeat(4000)) });
        truncate_strings(&mut v);
        let s = v["output"].as_str().unwrap();
        assert!(s.starts_with('…'));
        assert!(s.ends_with('z'));
        assert!(!s.contains("HEAD"));
    }
}
