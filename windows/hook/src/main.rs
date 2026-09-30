//! coucou-hook — relay for Claude Code and Codex lifecycle hooks.
//!
//! Reads the hook JSON on stdin, adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<sid>`.
//!
//! Hard rule: **never block the agent session unless a visible permission card
//! receives a decision.**
//! * If the pipe does not exist — Coucou is closed — we exit 0 immediately with
//!   nothing on stdout, and the session carries on untouched.
//! * Every step runs under a deadline enforced by the main thread, so a pipe that
//!   accepts the connection and then stops reading cannot wedge the session
//!   either: we abandon the worker and exit.
//! * Only `PermissionRequest` waits for an answer, because approving from the
//!   island is the whole point. No answer means empty stdout, and the normal
//!   provider approval UI takes over exactly as if Coucou were not installed.
//!
//! Usage: `coucou-hook <claude|codex> <EventName>`. The old one-argument
//! `coucou-hook <EventName>` form remains Claude-compatible.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Budget for getting a pipe connection. Beyond this the provider continues.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);

/// `ERROR_PIPE_BUSY` — every instance is serving someone else right now. This is
/// the one error worth retrying: the server exists and a slot will free up.
const ERROR_PIPE_BUSY: i32 = 231;

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output, or a transcript path). The island never shows them.
const DROPPED_FIELDS: &[&str] = &["tool_response", "transcript_path", "agent_transcript_path"];
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;
/// Keep stdin bounded even if a broken hook caller sends an unexpected payload.
const MAX_STDIN_BYTES: usize = 1 << 20;
/// Never truncate or alter a pending permission target. Oversized requests fall
/// back to the agent's normal approval UI instead of being decided from a preview.
const MAX_APPROVAL_BYTES: usize = 64 << 10;
const MAX_RELAY_BYTES: usize = 256 << 10;

const CLAUDE_EVENTS: &[&str] = &[
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
];
const CODEX_EVENTS: &[&str] = &[
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Stop",
    "SubagentStart",
    "SubagentStop",
    "Interrupt",
    "PreCompact",
    "PostCompact",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Provider {
    Claude,
    Codex,
}

impl Provider {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    fn supports(self, event: &str) -> bool {
        match self {
            Self::Claude => CLAUDE_EVENTS.contains(&event),
            Self::Codex => CODEX_EVENTS.contains(&event),
        }
    }
}

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
/// there is nothing to talk to, and waiting would only delay the provider.
/// Open and authenticate a named pipe. The production caller supplies only the
/// current-user Coucou pipe; tests inject a unique, temporary pipe name.
fn connect_at(path: &str) -> Option<std::fs::File> {
    use std::os::windows::io::AsRawHandle;
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
        {
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
    let Some((provider, expected_event)) = provider_event_from_args() else {
        std::process::exit(0)
    };
    let Some((payload, event)) = read_event(provider, &expected_event) else {
        std::process::exit(0)
    };

    let waits_for_answer = event == "PermissionRequest";
    let budget = if waits_for_answer {
        DECISION_BUDGET
    } else {
        FIRE_AND_FORGET_BUDGET
    };

    // The worker owns every blocking call. If it overruns the budget we simply
    // stop listening and exit: the process dying takes the pipe handle with it.
    // (No catch_unwind here — the release profile is panic = "abort", so it would
    // be dead code. `talk` is written to have nothing to panic on instead.)
    let (tx, rx) = mpsc::channel::<Option<String>>();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&payload, waits_for_answer));
    });

    if let Ok(Some(decision)) = rx.recv_timeout(budget) {
        if let Some(json) = decision_json(provider, &decision) {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{json}");
            let _ = out.flush();
        }
    }
    // Nothing printed: the provider asks for approval as if we were not here.
    std::process::exit(0);
}

/// The documented PermissionRequest output. Anything we do not recognise prints
/// nothing at all rather than guessing — silence is the safe answer.
/// See https://code.claude.com/docs/en/hooks
fn decision_json(provider: Provider, decision: &str) -> Option<String> {
    let behavior = match decision.trim() {
        // Claude retains its historical Always action; Codex supports only a
        // one-request allow or deny, so never translate Always into approval.
        "allow" => r#"{"behavior":"allow"}"#.to_string(),
        "always" if provider == Provider::Claude => r#"{"behavior":"allow"}"#.to_string(),
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#.to_string(),
        _ => return None,
    };
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#
    ))
}

/// Parse explicit provider invocations while preserving the former Claude-only
/// invocation. Anything ambiguous or unknown exits without talking to Coucou.
fn provider_event_from_args() -> Option<(Provider, String)> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    parse_invocation(&args)
}

fn parse_invocation(args: &[String]) -> Option<(Provider, String)> {
    match args {
        [event] if CLAUDE_EVENTS.contains(&event.as_str()) => {
            Some((Provider::Claude, event.clone()))
        }
        [provider, event] => {
            let provider = Provider::parse(provider)?;
            provider.supports(event).then(|| (provider, event.clone()))
        }
        _ => None,
    }
}

/// Reads stdin with a hard cap and normalizes a validated event for the relay.
fn read_event(provider: Provider, expected_event: &str) -> Option<(String, String)> {
    let cwd = std::env::current_dir()
        .ok()
        .map(|cwd| cwd.to_string_lossy().to_string());
    let terminal = [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
    ]
    .into_iter()
    .filter_map(|(key, var)| std::env::var(var).ok().map(|value| (key, value)))
    .collect::<Vec<_>>();
    read_event_from(
        std::io::stdin(),
        provider,
        expected_event,
        cwd.as_deref(),
        &terminal,
    )
}

fn read_event_from(
    reader: impl Read,
    provider: Provider,
    expected_event: &str,
    cwd: Option<&str>,
    terminal: &[(&str, String)],
) -> Option<(String, String)> {
    let mut raw = Vec::new();
    if reader
        .take((MAX_STDIN_BYTES + 1) as u64)
        .read_to_end(&mut raw)
        .is_err()
        || raw.is_empty()
        || raw.len() > MAX_STDIN_BYTES
    {
        return None;
    }
    normalize_event(&raw, provider, expected_event, cwd, terminal)
}

/// Parse and normalize a hook event. This is kept independent of the process
/// environment so malformed inputs and provider isolation can be tested.
fn normalize_event(
    raw: &[u8],
    provider: Provider,
    expected_event: &str,
    cwd: Option<&str>,
    terminal: &[(&str, String)],
) -> Option<(String, String)> {
    let raw = raw.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(raw);
    let mut payload = serde_json::from_slice::<serde_json::Value>(raw).ok()?;
    let map = payload.as_object_mut()?;

    let event = match map.get("hook_event_name") {
        Some(serde_json::Value::String(name)) if !name.is_empty() => {
            if name != expected_event {
                return None;
            }
            name.clone()
        }
        Some(serde_json::Value::String(_)) | None | Some(serde_json::Value::Null) => {
            expected_event.to_string()
        }
        Some(_) => return None,
    };
    if !provider.supports(&event) {
        return None;
    }
    map.insert(
        "hook_event_name".into(),
        serde_json::Value::String(event.clone()),
    );
    map.insert(
        "provider".into(),
        serde_json::Value::String(provider.name().into()),
    );

    // Codex Stop keeps the latest assistant response under its own field name.
    // Expose the same display field the island already uses for Claude.
    if provider == Provider::Codex && event == "Stop" && !map.contains_key("message") {
        if let Some(message) = map
            .get("last_assistant_message")
            .and_then(|value| value.as_str())
        {
            map.insert(
                "message".into(),
                serde_json::Value::String(message.to_string()),
            );
        }
    }

    // Codex includes the full PostToolUse response, which can contain command
    // output or an MCP payload. Retain only compact outcome metadata before the
    // response is discarded below.
    if provider == Provider::Codex && event == "PostToolUse" {
        if let Some(response) = map.get("tool_response").cloned() {
            add_tool_result_metadata(map, &response);
        }
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
        if let Some(cwd) = cwd {
            map.insert("cwd".into(), serde_json::Value::String(cwd.to_string()));
        }
    }

    // Which terminal the session runs in. Unlike macOS, Coucou on Windows accepts
    // events from every terminal, so this is context only — never a filter.
    for (key, value) in terminal {
        if provider == Provider::Codex && *key == "session_pid" {
            continue;
        }
        if !map.contains_key(*key) {
            map.insert((*key).into(), serde_json::Value::String(value.clone()));
        }
    }

    if event == "PermissionRequest" {
        // The approval target must reach the visible card byte-for-byte. Decline
        // oversized requests so the agent's regular prompt remains authoritative.
        if payload.to_string().len() > MAX_APPROVAL_BYTES {
            return None;
        }
    } else {
        truncate_strings(&mut payload);
    }

    let mut line = payload.to_string();
    if line.len() + 1 > MAX_RELAY_BYTES {
        return None;
    }
    line.push('\n');
    Some((line, event))
}

fn add_tool_result_metadata(
    map: &mut serde_json::Map<String, serde_json::Value>,
    response: &serde_json::Value,
) {
    let exit_code =
        find_number(response, &["exit_code", "exitCode"]).and_then(|number| number.as_i64());
    let explicit_error = find_bool(response, &["is_error", "isError"]) == Some(true)
        || find_bool(response, &["success", "ok"]) == Some(false)
        || find_status(response)
            .is_some_and(|status| matches!(status.as_str(), "error" | "failed"))
        || has_error_field(response, "error");
    let failed = explicit_error || exit_code.is_some_and(|code| code != 0);
    let succeeded = !failed
        && (exit_code == Some(0)
            || find_bool(response, &["success", "ok"]) == Some(true)
            || find_status(response)
                .is_some_and(|status| matches!(status.as_str(), "ok" | "success" | "succeeded")));
    if failed {
        map.insert(
            "tool_status".into(),
            serde_json::Value::String("failed".into()),
        );
        map.insert("tool_error".into(), serde_json::Value::Bool(true));
    } else if succeeded {
        map.insert(
            "tool_status".into(),
            serde_json::Value::String("succeeded".into()),
        );
    }
    if let Some(code) = exit_code {
        map.insert(
            "tool_exit_code".into(),
            serde_json::Value::Number(code.into()),
        );
    }
}

fn find_number<'a>(value: &'a serde_json::Value, names: &[&str]) -> Option<&'a serde_json::Number> {
    match value {
        serde_json::Value::Object(map) => {
            for name in names {
                if let Some(serde_json::Value::Number(number)) = map.get(*name) {
                    return Some(number);
                }
            }
            map.values().find_map(|child| find_number(child, names))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find_number(child, names)),
        _ => None,
    }
}

fn find_bool(value: &serde_json::Value, names: &[&str]) -> Option<bool> {
    match value {
        serde_json::Value::Object(map) => {
            for name in names {
                if let Some(serde_json::Value::Bool(boolean)) = map.get(*name) {
                    return Some(*boolean);
                }
            }
            map.values().find_map(|child| find_bool(child, names))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find_bool(child, names)),
        _ => None,
    }
}

fn find_status(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(serde_json::Value::String(status)) = map.get("status") {
                return Some(status.to_ascii_lowercase());
            }
            map.values().find_map(find_status)
        }
        serde_json::Value::Array(items) => items.iter().find_map(find_status),
        _ => None,
    }
}

fn has_error_field(value: &serde_json::Value, name: &str) -> bool {
    match value {
        serde_json::Value::Object(map) => {
            map.get(name).is_some_and(|value| match value {
                serde_json::Value::Null => false,
                serde_json::Value::Bool(value) => *value,
                serde_json::Value::String(value) => !value.trim().is_empty(),
                serde_json::Value::Number(value) => value.as_i64().is_some_and(|n| n != 0),
                serde_json::Value::Array(values) => !values.is_empty(),
                serde_json::Value::Object(values) => !values.is_empty(),
            }) || map.values().any(|child| has_error_field(child, name))
        }
        serde_json::Value::Array(items) => items.iter().any(|child| has_error_field(child, name)),
        _ => false,
    }
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
    talk_at(&pipe_path(), payload, waits_for_answer)
}

/// The same bounded client path as production, parameterized privately so the
/// test harness can exercise it against an isolated mock named pipe.
fn talk_at(path: &str, payload: &str, waits_for_answer: bool) -> Option<String> {
    let mut pipe = connect_at(path)?;

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
    use std::os::windows::io::FromRawHandle;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::thread::JoinHandle;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows::Win32::Storage::FileSystem::PIPE_ACCESS_DUPLEX;
    use windows::Win32::System::Pipes::{
        ConnectNamedPipe, CreateNamedPipeW, PIPE_READMODE_BYTE, PIPE_TYPE_BYTE, PIPE_WAIT,
    };

    static TEST_PIPE_COUNTER: AtomicU64 = AtomicU64::new(1);

    #[test]
    fn decision_json_matches_the_documented_shape() {
        assert_eq!(
            decision_json(Provider::Codex, "allow").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        );
        assert_eq!(
            decision_json(Provider::Codex, "deny").unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#
        );
        assert!(decision_json(Provider::Claude, "always")
            .unwrap()
            .contains(r#""behavior":"allow""#));
        assert!(decision_json(Provider::Codex, "always").is_none());
    }

    #[test]
    fn anything_unrecognised_prints_nothing() {
        assert!(decision_json(Provider::Codex, "").is_none());
        assert!(decision_json(Provider::Codex, "maybe").is_none());
        // The shape the app used to send must not be mistaken for a decision.
        assert!(decision_json(Provider::Codex, r#"{"permissionDecision":"allow"}"#).is_none());
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
    fn explicit_invocations_reject_unknown_providers_and_events() {
        assert_eq!(
            parse_invocation(&["codex".into(), "Interrupt".into()]),
            Some((Provider::Codex, "Interrupt".into()))
        );
        assert_eq!(
            parse_invocation(&["PreToolUse".into()]),
            Some((Provider::Claude, "PreToolUse".into()))
        );
        assert!(parse_invocation(&["other".into(), "PreToolUse".into()]).is_none());
        assert!(parse_invocation(&["codex".into(), "Notification".into()]).is_none());
        assert!(parse_invocation(&["codex".into()]).is_none());
    }

    #[test]
    fn codex_stop_is_normalized_and_keeps_session_and_turn_ids() {
        let raw = br#"{"hook_event_name":"Stop","session_id":"session-1","turn_id":"turn-2","last_assistant_message":"finished"}"#;
        let (line, event) = normalize_event(raw, Provider::Codex, "Stop", None, &[]).unwrap();
        let payload: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(event, "Stop");
        assert_eq!(payload["provider"], "codex");
        assert_eq!(payload["session_id"], "session-1");
        assert_eq!(payload["turn_id"], "turn-2");
        assert_eq!(payload["message"], "finished");
    }

    #[test]
    fn codex_post_tool_use_keeps_only_compact_failure_metadata() {
        let raw = format!(
            r#"{{"hook_event_name":"PostToolUse","turn_id":"turn","tool_response":{{"exit_code":7,"stdout":"{}"}}}}"#,
            "large output".repeat(1000)
        );
        let (line, _) =
            normalize_event(raw.as_bytes(), Provider::Codex, "PostToolUse", None, &[]).unwrap();
        let payload: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(payload["tool_status"], "failed");
        assert_eq!(payload["tool_error"], true);
        assert_eq!(payload["tool_exit_code"], 7);
        assert!(payload.get("tool_response").is_none());
        assert!(line.len() < 2_000);

        let success =
            br#"{"hook_event_name":"PostToolUse","tool_response":{"exit_code":0,"error":false}}"#;
        let (line, _) =
            normalize_event(success, Provider::Codex, "PostToolUse", None, &[]).unwrap();
        let payload: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(payload["tool_status"], "succeeded");
        assert!(payload.get("tool_error").is_none());
    }

    #[test]
    fn approval_targets_are_never_truncated_or_misrouted() {
        let command = "é".repeat(3000);
        let raw = serde_json::json!({
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": { "command": command },
            "session_id": "s",
            "turn_id": "t"
        })
        .to_string();
        let (line, _) = normalize_event(
            raw.as_bytes(),
            Provider::Codex,
            "PermissionRequest",
            None,
            &[],
        )
        .unwrap();
        let payload: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(payload["tool_input"]["command"].as_str().unwrap(), command);
        assert!(
            normalize_event(raw.as_bytes(), Provider::Codex, "PreToolUse", None, &[]).is_none()
        );

        let huge = serde_json::json!({
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": { "command": "x".repeat(MAX_APPROVAL_BYTES) }
        })
        .to_string();
        assert!(normalize_event(
            huge.as_bytes(),
            Provider::Codex,
            "PermissionRequest",
            None,
            &[]
        )
        .is_none());
    }

    #[test]
    fn codex_rejects_claude_only_events_and_mismatched_payload_names() {
        let raw = br#"{"hook_event_name":"Notification"}"#;
        assert!(normalize_event(raw, Provider::Codex, "Notification", None, &[]).is_none());
        let mismatched = br#"{"hook_event_name":"Stop"}"#;
        assert!(normalize_event(mismatched, Provider::Codex, "Interrupt", None, &[]).is_none());
    }

    #[test]
    fn named_pipe_round_trip_forwards_codex_stdin_and_returns_allow_or_deny_json() {
        for answer in ["allow", "deny"] {
            let (pipe, server) = mock_pipe(Some(answer));
            let input = br#"{"hook_event_name":"PermissionRequest","session_id":"session-smoke","turn_id":"turn-smoke","tool_name":"Bash","tool_input":{"command":"git status --short"}}"#;
            let output = relay_from_stdin_for_test(
                &["codex".into(), "PermissionRequest".into()],
                input,
                &pipe,
            )
            .expect("a valid explicit decision should return hook JSON");

            let received = server
                .join()
                .expect("mock pipe thread")
                .expect("received relay event");
            assert_eq!(received["provider"], "codex");
            assert_eq!(received["hook_event_name"], "PermissionRequest");
            assert_eq!(received["session_id"], "session-smoke");
            assert_eq!(received["turn_id"], "turn-smoke");
            assert_eq!(received["tool_input"]["command"], "git status --short");
            let json: serde_json::Value = serde_json::from_str(&output).unwrap();
            assert_eq!(
                json["hookSpecificOutput"]["hookEventName"],
                "PermissionRequest"
            );
            assert_eq!(json["hookSpecificOutput"]["decision"]["behavior"], answer);
        }
    }

    #[test]
    fn absent_pipe_and_unanswered_permission_fail_open_without_stdout() {
        let input = br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo safe"}}"#;

        // The isolated name is not created: this follows the production path
        // used while Coucou is closed and must print no approval JSON.
        let absent = unique_pipe_name();
        assert!(relay_from_stdin_for_test(
            &["codex".into(), "PermissionRequest".into()],
            input,
            &absent,
        )
        .is_none());

        let (pipe, server) = mock_pipe(None);
        assert!(relay_from_stdin_for_test(
            &["codex".into(), "PermissionRequest".into()],
            input,
            &pipe,
        )
        .is_none());
        let received = server
            .join()
            .expect("mock pipe thread")
            .expect("event forwarded");
        assert_eq!(received["hook_event_name"], "PermissionRequest");
    }

    #[test]
    fn unknown_provider_is_rejected_before_any_pipe_connection_or_output() {
        let input = br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo safe"}}"#;
        let pipe = unique_pipe_name();
        assert!(relay_from_stdin_for_test(
            &["unknown".into(), "PermissionRequest".into()],
            input,
            &pipe,
        )
        .is_none());
        assert!(parse_invocation(&["codex".into(), "Notification".into()]).is_none());
    }

    fn relay_from_stdin_for_test(args: &[String], input: &[u8], pipe: &str) -> Option<String> {
        let (provider, expected_event) = parse_invocation(args)?;
        let (payload, event) = read_event_from(
            std::io::Cursor::new(input),
            provider,
            &expected_event,
            None,
            &[],
        )?;
        let decision = talk_at(pipe, &payload, event == "PermissionRequest")?;
        decision_json(provider, &decision)
    }

    fn unique_pipe_name() -> String {
        let counter = TEST_PIPE_COUNTER.fetch_add(1, Ordering::Relaxed);
        format!(r"\\.\pipe\coucou-smoke-{}-{counter}", std::process::id())
    }

    fn mock_pipe(
        answer: Option<&'static str>,
    ) -> (String, JoinHandle<Result<serde_json::Value, String>>) {
        let name = unique_pipe_name();
        let server_name = name.clone();
        let (ready_tx, ready_rx) = mpsc::channel();
        let server = std::thread::spawn(move || {
            let wide: Vec<u16> = server_name.encode_utf16().chain(Some(0)).collect();
            let handle = unsafe {
                CreateNamedPipeW(
                    PCWSTR(wide.as_ptr()),
                    PIPE_ACCESS_DUPLEX,
                    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                    1,
                    4096,
                    4096,
                    2_000,
                    None,
                )
            };
            if handle == INVALID_HANDLE_VALUE {
                let _ = ready_tx.send(Err("CreateNamedPipeW failed".to_string()));
                return Err("CreateNamedPipeW failed".to_string());
            }
            let _ = ready_tx.send(Ok(()));
            if let Err(err) = unsafe { ConnectNamedPipe(handle, None) } {
                // A client can open the instance between creation and this
                // call; Win32 reports ERROR_PIPE_CONNECTED in that case.
                if err.code().0 as u32 != 0x8007_0217 {
                    unsafe {
                        let _ = CloseHandle(handle);
                    }
                    return Err(format!("ConnectNamedPipe failed: {err}"));
                }
            }
            let mut file = unsafe { std::fs::File::from_raw_handle(handle.0 as _) };
            let mut bytes = Vec::new();
            let mut chunk = [0u8; 1024];
            loop {
                match file.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => {
                        bytes.extend_from_slice(&chunk[..n]);
                        if bytes.contains(&b'\n') {
                            break;
                        }
                    }
                    Err(err) => return Err(format!("pipe read failed: {err}")),
                }
            }
            let end = bytes
                .iter()
                .position(|byte| *byte == b'\n')
                .unwrap_or(bytes.len());
            let payload = serde_json::from_slice(&bytes[..end])
                .map_err(|err| format!("invalid relayed payload: {err}"))?;
            if let Some(answer) = answer {
                file.write_all(format!("{answer}\n").as_bytes())
                    .map_err(|err| format!("pipe reply failed: {err}"))?;
            }
            Ok(payload)
        });
        ready_rx
            .recv()
            .expect("mock pipe creation result")
            .expect("mock pipe created");
        (name, server)
    }
}
