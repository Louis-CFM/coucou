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
//! Usage: `coucou-hook <EventName>` (the name is also read from the JSON).

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Budget for getting a pipe connection. Beyond this Claude Code wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);

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

/// Normalize Gemini CLI / Antigravity / opencode event names to the Claude-like
/// names the island already handles. Claude names pass through unchanged.
fn normalize_event(name: &str) -> String {
    match name {
        // Gemini CLI
        "BeforeTool" | "BeforeToolSelection" => "PreToolUse".to_string(),
        "AfterTool" => "PostToolUse".to_string(),
        "AfterModel" => "PostToolUse".to_string(),
        "BeforeAgent" | "AfterAgent" => "SubagentStop".to_string(),
        "SessionStart" | "startup" => "SessionStart".to_string(),
        "SessionEnd" | "exit" => "SessionEnd".to_string(),
        // Antigravity CLI (`agy`): Pre/PostToolUse and Stop already match;
        // invocations map to prompt/activity so the pill breathes per turn.
        "PreInvocation" => "UserPromptSubmit".to_string(),
        "PostInvocation" => "PostToolUse".to_string(),
        // opencode plugin (already normalized by the plugin, kept for safety)
        "session.created" => "SessionStart".to_string(),
        "session.deleted" => "SessionEnd".to_string(),
        "session.idle" => "Stop".to_string(),
        "session.error" => "StopFailure".to_string(),
        "tool.execute.before" | "permission.asked" => "PreToolUse".to_string(),
        "tool.execute.after" => "PostToolUse".to_string(),
        other => other.to_string(),
    }
}

fn normalize_source(source: &str) -> String {
    match source.to_lowercase().as_str() {
        "gemini" | "geminicli" | "gemini-cli" => "geminiCli".to_string(),
        "agy" | "antigravity" | "antigravity-cli" => "antigravity".to_string(),
        "opencode" | "open-code" => "opencode".to_string(),
        "generic" | "genericcli" | "cli" => "genericCli".to_string(),
        "claude" | "claudecode" | "claude-code" | "" => "claudeCode".to_string(),
        other => other.to_string(),
    }
}

/// Antigravity wraps tool data as `toolCall: {name, args}` and identifies the
/// session as `conversationId`. Map both onto the Claude-like fields the
/// island reads (`tool_name`, `tool_input`, `session_id`); existing fields win.
fn normalize_tool_fields(map: &mut serde_json::Map<String, serde_json::Value>) {
    use serde_json::Value;
    if map.contains_key("tool_name") {
        return;
    }
    let tool = map.get("toolCall").cloned().unwrap_or(Value::Null);
    let name = tool
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| {
            map.get("tool")
                .and_then(Value::as_str)
                .map(str::to_string)
        });
    if let Some(name) = name.filter(|s| !s.is_empty()) {
        map.insert("tool_name".into(), Value::String(name));
    }
    if !map.contains_key("tool_input") {
        if let Some(args) = tool.get("args").cloned().filter(|a| a.is_object()) {
            // Flatten the args Antigravity tools actually use so the island's
            // step label finds them: run_command's CommandLine → command.
            let mut flat = serde_json::Map::new();
            for (k, v) in args.as_object().unwrap() {
                flat.insert(k.clone(), v.clone());
            }
            for (k, v) in [
                ("CommandLine", "command"),
                ("FilePath", "file_path"),
                ("Path", "path"),
                ("Url", "url"),
                ("Query", "query"),
                ("Pattern", "pattern"),
            ] {
                if let Some(val) = args.get(k).cloned() {
                    flat.insert(v.to_string(), val);
                }
            }
            map.insert("tool_input".into(), Value::Object(flat));
        }
    }
    if !map.contains_key("session_id") {
        for key in ["conversationId", "conversation_id", "sessionId", "GEMINI_SESSION_ID"] {
            if let Some(id) = map.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()) {
                map.insert("session_id".into(), Value::String(id.to_string()));
                break;
            }
        }
    }
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

    // Parse argv, supporting both call shapes:
    //   "coucou-hook.exe [--agent <name>] [<EventName>]"      (upstream)
    //   "coucou-hook.exe [<EventName>] [<source>] [--agent <name>]" (this fork)
    // --agent tags the payload with coucou_agent so the app routes to the
    // right pill; the positional source (claude/gemini/agy/opencode) tags it
    // with source. Absent or invalid names are validated downstream, not here.
    // Env COUCOU_SOURCE overrides argv — useful for matchers that share
    // the same command line.
    let mut agent = String::new();
    let mut arg_event = String::new();
    let mut arg_source = String::new();
    {
        let mut it = std::env::args().skip(1);
        while let Some(arg) = it.next() {
            if arg == "--agent" {
                agent = it.next().unwrap_or_default();
            } else if arg_event.is_empty() {
                arg_event = arg;
            } else if arg_source.is_empty() {
                arg_source = arg;
            }
        }
    }
    // Which agent this hook was installed for. Absent means Claude Code,
    // so existing hook commands keep working unchanged.
    if !agent.is_empty() {
        map.insert("coucou_agent".into(), serde_json::Value::String(agent));
    }
    let mut event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or(arg_event);
    // Normalize Gemini CLI event names to the Claude-like names the island
    // already understands. Unknown names pass through untouched.
    event = normalize_event(&event);
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    // Antigravity/Gemini field shapes → island field shapes.
    normalize_tool_fields(map);

    if !map.contains_key("source") {
        let source = std::env::var("COUCOU_SOURCE")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or(arg_source);
        let source = normalize_source(&source);
        map.insert("source".into(), serde_json::Value::String(source));
    }

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
        // Gemini/Antigravity expose the session id via environment.
        ("session_id", "GEMINI_SESSION_ID"),
    ] {
        if !map.contains_key(key) {
            let value = std::env::var(var).unwrap_or_default();
            if !value.is_empty() {
                map.insert(key.into(), serde_json::Value::String(value));
            }
        }
    }

    truncate_strings(&mut payload);

    let mut line = payload.to_string();
    line.push('\n');
    Some((line, event))
}

/// Caps every string in the payload. A single Write can carry a whole file.
fn truncate_strings(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::String(s) => {
            if s.len() > MAX_FIELD_LEN {
                // Cut on a char boundary; a lone byte index can split UTF-8.
                let mut end = MAX_FIELD_LEN;
                while end > 0 && !s.is_char_boundary(end) {
                    end -= 1;
                }
                s.truncate(end);
                s.push('…');
            }
        }
        serde_json::Value::Array(items) => items.iter_mut().for_each(truncate_strings),
        serde_json::Value::Object(map) => map.values_mut().for_each(truncate_strings),
        _ => {}
    }
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
    fn long_strings_are_cut_on_a_char_boundary() {
        let mut v = serde_json::json!({ "tool_input": { "content": "é".repeat(4000) } });
        truncate_strings(&mut v);
        let s = v["tool_input"]["content"].as_str().unwrap();
        assert!(s.len() <= MAX_FIELD_LEN + 4);
        assert!(s.ends_with('…'));
    }
}
