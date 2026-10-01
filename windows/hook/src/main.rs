//! coucou-hook — the local relay for Claude Code and opt-in Codex events.
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
const MAX_INPUT_BYTES: usize = 1 << 20;
const MAX_DECISION_BYTES: usize = 32;

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
    connect_to(&pipe_path())
}

fn connect_to(path: &str) -> Option<std::fs::File> {
    use std::os::windows::io::AsRawHandle;
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    loop {
        match std::fs::OpenOptions::new().read(true).write(true).open(path) {
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
    let started = Instant::now();
    // Stdin is a blocking operation too. A producer that never closes it must
    // not hold up an agent, and oversized JSON must not allocate without limit.
    let (input_tx, input_rx) = mpsc::channel();
    std::thread::spawn(move || { let _ = input_tx.send(read_event()); });
    let Ok(Some((payload, event))) = input_rx.recv_timeout(FIRE_AND_FORGET_BUDGET) else {
        std::process::exit(0);
    };

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

    if let Ok(Some(decision)) = rx.recv_timeout(budget.saturating_sub(started.elapsed())) {
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

/// Reads stdin and returns the payload to forward plus the event name.
fn read_event() -> Option<(String, String)> {
    let mut raw = Vec::new();
    if std::io::stdin().take((MAX_INPUT_BYTES + 1) as u64).read_to_end(&mut raw).is_err()
        || raw.is_empty() || raw.len() > MAX_INPUT_BYTES {
        return None;
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (codex, arg_event) = invocation(&args)?;
    normalize_event(&raw, codex, &arg_event)
}

/// Old `coucou-hook Event` commands keep working. The provider is never guessed.
fn invocation(args: &[String]) -> Option<(bool, String)> {
    match args.first().map(String::as_str) {
        Some("--codex") => Some((true, args.get(1).cloned().unwrap_or_default())),
        Some("--provider") => {
            let codex = match args.get(1).map(String::as_str) {
                Some("codex") => true,
                Some("claude") => false,
                _ => return None,
            };
            Some((codex, args.get(2).cloned().unwrap_or_default()))
        }
        Some(flag) if flag.starts_with("--") => None,
        _ => Some((false, args.first().cloned().unwrap_or_default())),
    }
}

fn normalize_event(raw: &[u8], codex: bool, arg_event: &str) -> Option<(String, String)> {
    if raw.len() > MAX_INPUT_BYTES { return None; }
    let raw = raw.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(raw);
    let mut payload = serde_json::from_slice::<serde_json::Value>(raw).ok()?;
    let map = payload.as_object_mut()?;
    map.insert("agent_provider".into(), serde_json::Value::String(if codex { "codex" } else { "claude" }.into()));
    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| arg_event.to_string());
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    for field in DROPPED_FIELDS {
        map.remove(*field);
    }
    // An approval must never describe only a truncated prefix of the action.
    // Leave long approval inputs to the agent's ordinary, complete prompt.
    if event == "PermissionRequest" && !map.values().all(strings_fit) { return None; }

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

fn strings_fit(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::String(s) => s.len() <= MAX_FIELD_LEN,
        serde_json::Value::Array(items) => items.iter().all(strings_fit),
        serde_json::Value::Object(map) => map.values().all(strings_fit),
        _ => true,
    }
}

/// Connect, send, and — for a permission request — wait for the island's word.
fn talk(payload: &str, waits_for_answer: bool) -> Option<String> {
    talk_on_pipe(connect()?, payload, waits_for_answer)
}

fn talk_on_pipe(mut pipe: std::fs::File, payload: &str, waits_for_answer: bool) -> Option<String> {

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
                if buf.len() + n > MAX_DECISION_BYTES { return None; }
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
    fn codex_payload_round_trips_over_an_isolated_same_user_pipe() {
        use std::ffi::c_void;
        use std::os::windows::io::{AsRawHandle, FromRawHandle};
        // Test-only Win32 server. No runtime option can redirect the production
        // relay; these unique names never open the developer's Coucou channel.
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn CreateNamedPipeW(name: *const u16, open_mode: u32, mode: u32,
                instances: u32, out_size: u32, in_size: u32, timeout: u32,
                attributes: *const c_void) -> *mut c_void;
            fn ConnectNamedPipe(pipe: *mut c_void, overlapped: *mut c_void) -> i32;
            fn GetLastError() -> u32;
        }
        let oversized = format!("allow\n{}", "x".repeat(MAX_DECISION_BYTES));
        for answer in ["allow\n", "deny\n", "", oversized.as_str()] {
            let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
            let path = format!(r"\\.\pipe\coucou-test-{}-{nonce}", std::process::id());
            let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
            let handle = unsafe { CreateNamedPipeW(wide.as_ptr(), 3, 0, 1, 4096, 4096, 0, std::ptr::null()) };
            assert_ne!(handle as isize, -1);
            let mut server = unsafe { std::fs::File::from_raw_handle(handle) };
            let reply = answer.to_string();
            let peer = std::thread::spawn(move || {
                let connected = unsafe { ConnectNamedPipe(server.as_raw_handle(), std::ptr::null_mut()) };
                assert!(connected != 0 || unsafe { GetLastError() } == 535);
                let mut input = Vec::new();
                let mut byte = [0u8];
                while server.read(&mut byte).unwrap() > 0 {
                    input.push(byte[0]); if byte[0] == b'\n' { break; }
                }
                let payload: serde_json::Value = serde_json::from_slice(&input).unwrap();
                assert_eq!(payload["agent_provider"], "codex");
                assert_eq!(payload["session_id"], "fixture-session");
                server.write_all(reply.as_bytes()).unwrap();
                if !reply.is_empty() { server.flush().unwrap(); }
            });
            let (payload, _) = normalize_event(br#"{"hook_event_name":"PermissionRequest","session_id":"fixture-session"}"#, true, "").unwrap();
            let result = talk_on_pipe(connect_to(&path).expect("fixture peer must be same user"), &payload, true);
            assert_eq!(result.as_deref(), if answer.is_empty() || answer.len() > MAX_DECISION_BYTES { None } else { Some(answer.trim()) });
            peer.join().unwrap();
            assert!(connect_to(&path).is_none());
        }
    }

    #[test]
    fn invocation_keeps_legacy_commands_and_accepts_explicit_providers() {
        let args = |values: &[&str]| values.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(invocation(&args(&["PreToolUse"])), Some((false, "PreToolUse".into())));
        assert_eq!(invocation(&args(&["--provider", "codex", "Stop"])), Some((true, "Stop".into())));
        assert_eq!(invocation(&args(&["--codex", "Stop"])), Some((true, "Stop".into())));
        assert!(invocation(&args(&["--provider", "unknown"])).is_none());
    }

    #[test]
    fn codex_payload_is_tagged_and_retains_session_turn_and_model() {
        let raw = br#"{"hook_event_name":"PreToolUse","agent_provider":"claude","session_id":"s","turn_id":"t","model":"fixture-model","tool_name":"apply_patch","tool_input":{"command":"patch"},"tool_response":"discard","transcript_path":"private"}"#;
        let (line, event) = normalize_event(raw, true, "").unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(event, "PreToolUse");
        assert_eq!(value["agent_provider"], "codex");
        assert_eq!(value["session_id"], "s");
        assert_eq!(value["turn_id"], "t");
        assert_eq!(value["model"], "fixture-model");
        assert!(value.get("tool_response").is_none());
        assert!(value.get("transcript_path").is_none());
    }

    #[test]
    fn malformed_inputs_are_silent_and_bom_is_accepted() {
        for raw in [b"null".as_slice(), b"[]", b"invalid", b""] {
            assert!(normalize_event(raw, true, "Stop").is_none());
        }
        let mut raw = vec![0xEF, 0xBB, 0xBF]; raw.extend_from_slice(b"{}");
        let (line, event) = normalize_event(&raw, false, "SessionStart").unwrap();
        assert_eq!(event, "SessionStart");
        assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["agent_provider"], "claude");
    }

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

    #[test]
    fn oversized_input_is_silent_and_approval_targets_are_never_truncated() {
        assert!(normalize_event(&vec![b' '; MAX_INPUT_BYTES + 1], true, "Stop").is_none());
        let raw = serde_json::json!({"hook_event_name":"PermissionRequest",
            "tool_input":{"command":"x".repeat(MAX_FIELD_LEN + 1)}}).to_string();
        assert!(normalize_event(raw.as_bytes(), true, "").is_none());
        let raw = serde_json::json!({"hook_event_name":"PermissionRequest",
            "tool_input":{"command":"echo complete command"}}).to_string();
        let (line, _) = normalize_event(raw.as_bytes(), true, "").unwrap();
        assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["tool_input"]["command"], "echo complete command");
    }
}
