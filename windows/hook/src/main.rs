//! coucou-hook — the relay Claude Code runs on every hook event.
//!
//! Reads the hook JSON on stdin, adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<sid>` (Windows) or the Unix
//! socket `$XDG_RUNTIME_DIR/coucou.sock` (Linux).
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
//! Usage: `coucou-hook <EventName>` (the name is also read from the JSON), or
//! `coucou-hook --statusline` as Claude Code's status line command: it passes the
//! plan limits on and runs the status line the user had before, so that keeps working.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Budget for getting a pipe connection. Beyond this Claude Code wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);
/// How long the user's own status line may take before we give up on it.
const PREVIOUS_STATUS_LINE_BUDGET: Duration = Duration::from_secs(10);

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output). The island never shows them.
const DROPPED_FIELDS: &[&str] = &["tool_response", "transcript_path"];
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;
/// How much of what a command printed goes on: its last lines, each cut short.
const TAIL_LINES: usize = 3;
const TAIL_WIDTH: usize = 160;

#[cfg(windows)]
mod win;
#[cfg(windows)]
use win::connect;

#[cfg(target_os = "linux")]
mod unix;
#[cfg(target_os = "linux")]
use unix::connect;

fn main() {
    if std::env::args().any(|a| a == "--statusline") {
        run_status_line();
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

/// `coucou-hook --statusline`: the status line command of Claude Code.
///
/// It gets the session's JSON on stdin and whatever it prints becomes the status
/// line. Coucou only wants the plan limits in it, so they go on in the background
/// (never delaying the status line), and if the user had a status line of their
/// own it is run with the same input and its output passed on untouched.
fn run_status_line() -> ! {
    let mut raw = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut raw);
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }

    let sent = serde_json::from_slice::<serde_json::Value>(&raw)
        .ok()
        .and_then(|v| status_line_payload(v.as_object()?))
        .map(|line| {
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let _ = tx.send(talk(&line, false));
            });
            rx
        });

    if let Some(command) = previous_status_line() {
        if let Some(out) = run_previous(&command, &raw, PREVIOUS_STATUS_LINE_BUDGET) {
            let mut stdout = std::io::stdout();
            let _ = stdout.write_all(&out);
            let _ = stdout.flush();
        }
    }
    // Coucou's share is a few hundred milliseconds at most.
    if let Some(rx) = sent {
        let _ = rx.recv_timeout(CONNECT_TIMEOUT);
    }
    std::process::exit(0);
}

/// The command of the status line the user had before Coucou's relay took its place,
/// saved by the installer next to this program.
fn previous_status_line() -> Option<String> {
    let path = std::env::current_exe().ok()?.with_file_name("statusline-previous.json");
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    saved.get("command")?.as_str().filter(|c| !c.trim().is_empty()).map(str::to_string)
}

/// Runs `command` through the shell with `input` on stdin and returns what it
/// printed, or nothing if it could not start or ran past `budget` (then it is killed).
fn run_previous(command: &str, input: &[u8], budget: Duration) -> Option<Vec<u8>> {
    use std::process::{Command, Stdio};

    #[cfg(unix)]
    let mut cmd = {
        let mut c = Command::new("/bin/sh");
        c.args(["-c", command]);
        c
    };
    #[cfg(windows)]
    let mut cmd = {
        use std::os::windows::process::CommandExt;
        let mut c = Command::new("cmd");
        c.args(["/C", command]).creation_flags(0x0800_0000); // no console window
        c
    };
    let mut child =
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().ok()?;

    // Feed and drain on their own threads: a long input or output cannot deadlock us.
    let mut stdin = child.stdin.take()?;
    let data = input.to_vec();
    std::thread::spawn(move || {
        let _ = stdin.write_all(&data);
    });
    let mut stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = stdout.read_to_end(&mut out);
        let _ = tx.send(out);
    });

    let deadline = Instant::now() + budget;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    rx.recv_timeout(Duration::from_millis(500)).ok()
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

    // Parse argv: "coucou-hook.exe [--agent <name>] [<EventName>]"
    // --agent tags the payload with coucou_agent so the app routes to the right pill.
    // Absent or invalid names are validated and discarded by the app, not here.
    let mut agent = String::new();
    let mut arg_event = String::new();
    {
        let mut it = std::env::args().skip(1);
        while let Some(arg) = it.next() {
            if arg == "--agent" {
                agent = it.next().unwrap_or_default();
            } else if arg_event.is_empty() {
                arg_event = arg;
            }
        }
    }
    // Which agent this hook was installed for. Absent means Claude Code,
    // so existing hook commands keep working unchanged.
    if !agent.is_empty() {
        map.insert("coucou_agent".into(), serde_json::Value::String(agent));
    }
    let event = map
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
        .unwrap_or(arg_event);
    map.insert("hook_event_name".into(), serde_json::Value::String(event.clone()));

    // Claude Code's status line hands us its usage limits (5 h, weekly). That is
    // all the island wants of it, so only that goes on; without limits (API-key
    // users) there is nothing to send. The command's own output stays empty.
    if event == "StatusLine" {
        return status_line_payload(map).map(|line| (line, event));
    }

    // What a finished command printed is dropped with the rest of `tool_response`,
    // except its last lines: the island shows them under the command, like a
    // terminal pane. Never the whole output — it may hold anything.
    if event == "PostToolUse"
        && matches!(map.get("tool_name").and_then(|v| v.as_str()), Some("Bash" | "PowerShell"))
    {
        if let Some(lines) = map.get("tool_response").and_then(output_tail) {
            map.insert("tool_tail".into(), serde_json::json!(lines));
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
        if let Ok(cwd) = std::env::current_dir() {
            map.insert(
                "cwd".into(),
                serde_json::Value::String(cwd.to_string_lossy().to_string()),
            );
        }
    }

    // Which terminal the session runs in. Unlike macOS, Coucou here accepts
    // events from every terminal, so this is context only — never a filter.
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
        // Konsole: where "Open terminal" can jump to (its D-Bus tab and window).
        ("konsole_service", "KONSOLE_DBUS_SERVICE"),
        ("konsole_session", "KONSOLE_DBUS_SESSION"),
        ("konsole_window", "KONSOLE_DBUS_WINDOW"),
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

/// The one line the island gets from a status-line call: the limits and which
/// session they came from.
fn status_line_payload(map: &serde_json::Map<String, serde_json::Value>) -> Option<String> {
    let limits = map.get("rate_limits").filter(|v| v.is_object())?;
    let mut line = serde_json::json!({
        "hook_event_name": "StatusLine",
        "session_id": map.get("session_id").cloned().unwrap_or(serde_json::Value::Null),
        "rate_limits": limits,
    })
    .to_string();
    line.push('\n');
    Some(line)
}

/// The last few non-empty lines a command printed (stdout, else stderr), without
/// colour codes and cut to a width the island can show.
fn output_tail(response: &serde_json::Value) -> Option<Vec<String>> {
    let text = match response {
        serde_json::Value::String(s) => s.as_str(),
        serde_json::Value::Object(o) => ["stdout", "stderr"]
            .iter()
            .filter_map(|k| o.get(*k)?.as_str())
            .find(|s| !s.trim().is_empty())?,
        _ => return None,
    };
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| strip_ansi(l).trim_end().to_string())
        .filter(|l| !l.trim().is_empty())
        .rev()
        .take(TAIL_LINES)
        .map(|l| l.chars().take(TAIL_WIDTH).collect())
        .collect();
    lines.reverse();
    (!lines.is_empty()).then_some(lines)
}

/// Drops `ESC [ … letter` colour and cursor sequences.
fn strip_ansi(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            while let Some(&n) = chars.peek() {
                chars.next();
                if n.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
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

    #[cfg(unix)]
    #[test]
    fn the_users_own_status_line_gets_the_same_input_and_its_output_comes_back() {
        let out = run_previous("cat; echo ' tail'", b"{\"a\":1}", Duration::from_secs(5)).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "{\"a\":1} tail\n");
    }

    #[cfg(unix)]
    #[test]
    fn a_status_line_that_hangs_is_killed_and_prints_nothing() {
        let started = Instant::now();
        assert!(run_previous("sleep 5", b"{}", Duration::from_millis(200)).is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn a_status_line_call_forwards_only_the_limits() {
        let input = serde_json::json!({
            "session_id": "s1", "cwd": "/secret", "model": { "id": "x" },
            "rate_limits": { "five_hour": { "used_percentage": 42, "resets_at": 1 } }
        });
        let line = status_line_payload(input.as_object().unwrap()).unwrap();
        let v: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(v["rate_limits"]["five_hour"]["used_percentage"], 42);
        assert!(v.get("cwd").is_none() && v.get("model").is_none());
        // No limits (API-key users): nothing is sent.
        assert!(
            status_line_payload(serde_json::json!({ "session_id": "s1" }).as_object().unwrap())
                .is_none()
        );
    }

    #[test]
    fn only_the_last_lines_of_a_command_survive_and_without_colours() {
        let out = serde_json::json!({ "stdout": "a\n\n\u{1b}[32mPASS\u{1b}[0m tests/x.ts\n  ✓ works (3 ms)\nTests: 1 passed\n" });
        assert_eq!(
            output_tail(&out).unwrap(),
            vec!["PASS tests/x.ts", "  ✓ works (3 ms)", "Tests: 1 passed"]
        );
        // stderr is the fallback; nothing printed means nothing to show.
        assert_eq!(
            output_tail(&serde_json::json!({ "stdout": "", "stderr": "boom" })).unwrap(),
            vec!["boom"]
        );
        assert!(output_tail(&serde_json::json!({ "stdout": " \n" })).is_none());
        assert!(output_tail(&serde_json::json!(42)).is_none());
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
