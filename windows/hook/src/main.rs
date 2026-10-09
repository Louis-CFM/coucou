//! coucou-hook — the relay Claude Code (and every other agent) runs on each hook
//! event.
//!
//! Reads the hook JSON on stdin, maps the agent's event and field names onto
//! Claude Code's (normalize.rs), adds a little terminal context, and hands it to
//! Coucou over the named pipe `\\.\pipe\coucou-<sid>` (Windows) or the Unix
//! socket `$XDG_RUNTIME_DIR/coucou.sock` (Linux).
//!
//! Hard rule (docs/CLAUDE.md): **never block the agent.**
//! * If the pipe does not exist — Coucou is closed — we exit 0 immediately, with
//!   only the "no opinion" reply the agent expects (reply.rs), and the session
//!   carries on untouched. Opted-in Windows Codex/Hermes events can launch Coucou;
//!   that attempt still fits inside the two-second fire-and-forget deadline.
//! * Every step runs under a deadline enforced by the main thread, so a pipe that
//!   accepts the connection and then stops reading cannot wedge the session
//!   either: we abandon the worker and exit.
//! * Only `PermissionRequest` waits for an answer, because approving from the
//!   island is the whole point. No answer means no decision, and the agent asks
//!   in its terminal exactly as if Coucou were not installed.
//!
//! Usage: `coucou-hook [--agent <name>] [<EventName>]` (the event name is also
//! read from the JSON; `--agent` is absent for Claude Code), or
//! `coucou-hook --statusline` as Claude Code's status line command (plan usage,
//! see statusline.rs): it passes the plan limits on and runs the status line the
//! user had before, so that keeps working.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{json, Map, Value};

mod normalize;
mod reply;

#[path = "../../shared/auto_launch_trigger.rs"]
#[allow(dead_code)] // The backend uses the same policy for startup buffering.
mod auto_launch_trigger;

/// Budget for getting a pipe connection. Beyond this the agent wins, always.
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Whole-run budget for an event nobody waits on: connect and write, no more.
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
/// How long a permission prompt may stay on screen before the terminal takes over.
const DECISION_BUDGET: Duration = Duration::from_secs(110);

/// Fields that are pointless to forward and can be enormous (a whole file read,
/// a full command output). The island never shows them.
const DROPPED_FIELDS: &[&str] = &["tool_response", "tool_output", "transcript_path"];
/// Longest string forwarded for any single field; the island truncates to far
/// less than this anyway.
const MAX_FIELD_LEN: usize = 2_000;

mod statusline;

/// The live diff needs the whole text of a file edit, once it has happened:
/// PostToolUse of these tools keeps its edit strings far longer than the rest.
const DIFF_TOOLS: &[&str] = &["Edit", "MultiEdit", "Write"];
/// The `tool_input` keys holding the text being replaced or written.
const DIFF_FIELDS: &[&str] = &["old_string", "new_string", "content"];
/// Per edit string. The island stops diffing at 200 KB anyway (DiffEngine).
const MAX_DIFF_FIELD_LEN: usize = 256 * 1024;
/// For all edit strings of one event together, so the line stays well under the
/// 1 MiB the app reads from the pipe even once JSON-escaped.
const MAX_DIFF_TOTAL: usize = 512 * 1024;

#[cfg(windows)]
mod auto_launch;
#[cfg(windows)]
mod win;

#[cfg(target_os = "linux")]
mod unix;
#[cfg(target_os = "linux")]
use unix::connect;

/// What the command line says: `--agent <name>` and the event name.
struct Args {
    agent: String,
    event: String,
}

fn args() -> Args {
    let mut agent = String::new();
    let mut event = String::new();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        if arg == "--agent" {
            agent = it.next().unwrap_or_default();
        } else if event.is_empty() {
            event = arg;
        }
    }
    Args { agent, event }
}

/// One event, ready to forward.
struct Event {
    /// Validated before forwarding; Hermes must use its plugin's actual event/fields.
    launch_key: Option<Value>,
    /// The payload as one line of JSON.
    line: String,
    /// The canonical event name.
    name: String,
    /// For Claude Code's AskUserQuestion, the question as it was asked.
    question: Option<Value>,
}

fn main() {
    #[cfg(windows)]
    let started = std::time::Instant::now();
    if std::env::args().skip(1).any(|a| a == "--statusline") {
        statusline::run();
    }
    let args = args();
    let mut raw = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut raw);
    let env = |key: &str| std::env::var(key).ok();
    let cwd = std::env::current_dir()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    let Some(event) = prepare(&raw, &args, &env, &cwd) else {
        // Nothing we could forward. An agent that needs JSON still gets its
        // "no opinion" — Copilot is fail-closed and would deny without it.
        let name = normalize::event(&args.event);
        print(reply::stdout(&args.agent, name, None, None));
        std::process::exit(0);
    };

    // Only an agent whose decisions the island can give waits for one; any other
    // would be held for nothing, its decision being thrown away (reply.rs).
    let waits_for_answer = event.name == "PermissionRequest" && reply::takes_decisions(&args.agent);
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
    let line = event.line.clone();
    let launch_key = event.launch_key.clone();
    std::thread::spawn(move || {
        let _ = tx.send(talk(&line, waits_for_answer, launch_key));
    });

    let result = rx.recv_timeout(budget);
    #[cfg(windows)]
    if event.launch_key.is_some() {
        auto_launch::hook_finished(
            started.elapsed(),
            matches!(&result, Err(mpsc::RecvTimeoutError::Timeout)),
        );
    }
    let decision = result.ok().flatten();
    print(reply::stdout(
        &args.agent,
        &event.name,
        decision.as_deref(),
        event.question.as_ref(),
    ));
    std::process::exit(0);
}

fn print(line: Option<String>) {
    if let Some(line) = line {
        let mut out = std::io::stdout();
        let _ = writeln!(out, "{line}");
        let _ = out.flush();
    }
}

/// The payload to forward, from the raw stdin bytes. `env` reads an environment
/// variable and `cwd` is the working directory, so tests stay pure.
fn prepare(
    raw: &[u8],
    args: &Args,
    env: &dyn Fn(&str) -> Option<String>,
    cwd: &str,
) -> Option<Event> {
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    let raw = raw.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(raw);
    let mut payload = serde_json::from_slice::<Value>(raw).ok()?;
    // Plugin and Claude hooks must name their own events; normalization cannot invent a trigger.
    let tag = agent_tag(&args.agent, env);
    let launch_agent = if args.agent.is_empty() && tag.is_none() {
        "claude-code"
    } else {
        args.agent.as_str()
    };
    let raw_key = match launch_agent {
        "hermes" | "opencode" => auto_launch_trigger::key(&payload, launch_agent),
        "claude-code" => claude_launch_key(&payload),
        "antigravity"
            if args.event == "PreInvocation"
                && payload
                    .get("hook_event_name")
                    .is_none_or(|event| event.as_str() == Some("PreInvocation")) =>
        {
            auto_launch_trigger::key(
                &json!({
                    "hook_event_name": "PreInvocation",
                    "conversationId": payload.get("conversationId"),
                    "invocationNum": payload.get("invocationNum"),
                    "initialNumSteps": payload.get("initialNumSteps"),
                }),
                launch_agent,
            )
        }
        _ => None,
    };
    let map = payload.as_object_mut()?;
    // Relay creation time orders concurrent connections without retaining prompt content.
    map.insert(
        "coucou_event_time_us".into(),
        json!(std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros() as u64),
    );

    // Which agent this hook was installed for, so the app routes it to the right
    // pill. Absent means Claude Code, so existing hook commands keep working
    // unchanged; invalid names are discarded by the app, not here. A Claude Code
    // session started from the Claude desktop app is tagged `claude-desktop`.
    if let Some(tag) = tag {
        map.insert("coucou_agent".into(), Value::String(tag));
    }
    // Claude Code in Cursor's terminal goes on the Cursor pill (Mac #120).
    if !map.contains_key("term_editor") {
        if let Some(editor) = term_editor(env) {
            map.insert("term_editor".into(), Value::String(editor.into()));
        }
    }

    let raw_event = map
        .get("hook_event_name")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| args.event.clone());
    #[cfg(all(windows, not(test)))]
    if raw_key.is_none()
        && (matches!(launch_agent, "hermes" | "claude-code")
            && matches!(raw_event.as_str(), "SessionStart" | "UserPromptSubmit")
            || launch_agent == "opencode" && raw_event == "UserPromptSubmit"
            || launch_agent == "antigravity" && raw_event == "PreInvocation")
    {
        let reason = if launch_agent == "antigravity"
            || map.get("hook_event_name").and_then(Value::as_str) == Some(raw_event.as_str())
        {
            "invalid_identifiers"
        } else {
            "missing_event"
        };
        auto_launch::rejected(launch_agent, &raw_event, reason);
    }
    normalize::fields(map, env);
    let name = normalize::refine(normalize::event(&raw_event), map);
    map.insert("hook_event_name".into(), Value::String(name.clone()));

    let launch_key = if launch_agent == "codex" {
        auto_launch_trigger::key(&payload, launch_agent)
    } else {
        raw_key
    };
    let map = payload.as_object_mut()?;

    for field in DROPPED_FIELDS {
        map.remove(*field);
    }

    if map
        .get("cwd")
        .and_then(Value::as_str)
        .map(str::is_empty)
        .unwrap_or(true)
        && !cwd.is_empty()
    {
        map.insert("cwd".into(), Value::String(cwd.to_string()));
    }

    add_terminal_context(map, env);

    // Kept whole: what goes back to Claude Code must be its own input, not the
    // shortened copy the island is shown.
    let question = (map.get("tool_name").and_then(Value::as_str) == Some("AskUserQuestion"))
        .then(|| map.get("tool_input").cloned())
        .flatten();

    // Every string is capped, except the edit text of a finished Edit /
    // MultiEdit / Write, which the live diff needs whole (within its own limits).
    truncate_payload(&mut payload, &name);

    let mut line = payload.to_string();
    line.push('\n');
    Some(Event {
        line,
        name,
        question,
        launch_key,
    })
}

fn claude_launch_key(payload: &Value) -> Option<Value> {
    let event = payload.get("hook_event_name")?.as_str()?;
    if !matches!(event, "SessionStart" | "UserPromptSubmit") {
        return None;
    }
    let path = payload.get("transcript_path")?.as_str()?;
    if !std::path::Path::new(path).is_absolute() {
        return None;
    }
    // shortcut: transcript length marks a turn until Claude exposes a prompt ID in this hook.
    let len = match std::fs::metadata(path) {
        Ok(meta) if meta.is_file() => meta.len(),
        Err(err)
            if err.kind() == std::io::ErrorKind::NotFound
                && event == "SessionStart"
                && payload.get("source")?.as_str()? == "startup" =>
        {
            0
        }
        _ => return None,
    };
    auto_launch_trigger::key(
        &json!({
            "hook_event_name": event,
            "session_id": payload.get("session_id")?,
            "source": payload.get("source"),
            "turn_id": format!("transcript:{len}"),
        }),
        "claude-code",
    )
}

/// Which terminal the session runs in. Unlike macOS, Coucou here accepts events
/// from every terminal, so this is context only — never a filter.
fn add_terminal_context(map: &mut Map<String, Value>, env: &dyn Fn(&str) -> Option<String>) {
    for (key, var) in [
        ("term_program", "TERM_PROGRAM"),
        ("wt_session", "WT_SESSION"),
        ("term_session_id", "TERM_SESSION_ID"),
        ("vscode_pid", "VSCODE_PID"),
        ("session_pid", "CLAUDE_CODE_SSE_PORT"),
    ] {
        if !map.contains_key(key) {
            map.insert(key.into(), Value::String(env(var).unwrap_or_default()));
        }
    }
}

/// The `coucou_agent` tag: `--agent` when given, otherwise `claude-desktop` for
/// a Claude Code session started from the Claude desktop app, which says so in
/// CLAUDE_CODE_ENTRYPOINT — the same rule as the Mac's relay (#191). Nothing
/// for a plain Claude Code session.
fn agent_tag(arg: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    if !arg.is_empty() {
        return Some(arg.to_string());
    }
    (env("CLAUDE_CODE_ENTRYPOINT").as_deref() == Some("claude-desktop"))
        .then(|| "claude-desktop".to_string())
}

/// `cursor` when the session runs in Cursor's integrated terminal. Cursor sets
/// TERM_PROGRAM=vscode like VS Code does, so it is told apart by its own trace
/// variable, or by its executable behind VS Code's git helper.
fn term_editor(env: &dyn Fn(&str) -> Option<String>) -> Option<&'static str> {
    if env("CURSOR_TRACE_ID").is_some_and(|v| !v.is_empty()) {
        return Some("cursor");
    }
    let helper = env("VSCODE_GIT_ASKPASS_NODE").unwrap_or_default();
    let exe = helper
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    exe.starts_with("cursor").then_some("cursor")
}

/// Caps the strings of a payload: every field to MAX_FIELD_LEN, except the edit
/// strings of a finished Edit / MultiEdit / Write, which the live diff needs
/// whole. If even those had to be cut, `coucou_diff_truncated` tells the island
/// not to show counts it cannot trust.
fn truncate_payload(payload: &mut serde_json::Value, event: &str) {
    let keeps_diff = event == "PostToolUse"
        && payload
            .get("tool_name")
            .and_then(|v| v.as_str())
            .is_some_and(|tool| DIFF_TOOLS.contains(&tool));
    let input = if keeps_diff {
        payload
            .as_object_mut()
            .and_then(|map| map.remove("tool_input"))
    } else {
        None
    };

    truncate_strings(payload);

    if let Some(mut input) = input {
        let mut budget = MAX_DIFF_TOTAL;
        let mut cut_any = false;
        cap_diff_strings(&mut input, &mut budget, &mut cut_any);
        if let Some(map) = payload.as_object_mut() {
            map.insert("tool_input".into(), input);
            if cut_any {
                map.insert(
                    "coucou_diff_truncated".into(),
                    serde_json::Value::Bool(true),
                );
            }
        }
    }
}

/// `tool_input` of a diff tool: edit strings share MAX_DIFF_TOTAL, each capped at
/// MAX_DIFF_FIELD_LEN; any other string gets the ordinary cap.
fn cap_diff_strings(value: &mut serde_json::Value, budget: &mut usize, cut_any: &mut bool) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, v) in map.iter_mut() {
                match v {
                    serde_json::Value::String(s) if DIFF_FIELDS.contains(&key.as_str()) => {
                        let limit = MAX_DIFF_FIELD_LEN.min(*budget);
                        if cut(s, limit) {
                            *cut_any = true;
                        }
                        *budget = budget.saturating_sub(s.len());
                    }
                    _ => cap_diff_strings(v, budget, cut_any),
                }
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                cap_diff_strings(item, budget, cut_any);
            }
        }
        serde_json::Value::String(s) => {
            cut(s, MAX_FIELD_LEN);
        }
        _ => {}
    }
}

/// Caps every string in the payload. A single Write can carry a whole file.
fn truncate_strings(value: &mut Value) {
    match value {
        Value::String(s) => {
            cut(s, MAX_FIELD_LEN);
        }
        Value::Array(items) => items.iter_mut().for_each(truncate_strings),
        Value::Object(map) => map.values_mut().for_each(truncate_strings),
        _ => {}
    }
}

/// Shortens `s` to at most `max` bytes plus an ellipsis; true if it was cut.
fn cut(s: &mut String, max: usize) -> bool {
    if s.len() <= max {
        return false;
    }
    // Cut on a char boundary; a lone byte index can split UTF-8.
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s.truncate(end);
    s.push('…');
    true
}

/// Connect, send, and — for a permission request — wait for the island's word.
fn talk(payload: &str, waits_for_answer: bool, _launch_key: Option<Value>) -> Option<String> {
    #[cfg(windows)]
    let mut pipe = auto_launch::connect(_launch_key)?;
    #[cfg(target_os = "linux")]
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

    fn run(raw: &str, agent: &str, event: &str) -> (Value, Event) {
        let args = Args {
            agent: agent.into(),
            event: event.into(),
        };
        let ev = prepare(raw.as_bytes(), &args, &|_| None, "/home/me/here").expect("forwarded");
        let v = serde_json::from_str(ev.line.trim_end()).unwrap();
        (v, ev)
    }

    fn env_of(vars: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |name| {
            vars.iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| v.to_string())
        }
    }

    #[test]
    fn claude_desktop_sessions_are_tagged_and_an_explicit_agent_wins() {
        let desktop = env_of(&[("CLAUDE_CODE_ENTRYPOINT", "claude-desktop")]);
        assert_eq!(agent_tag("", &desktop).as_deref(), Some("claude-desktop"));
        assert_eq!(agent_tag("gemini", &desktop).as_deref(), Some("gemini"));
        assert_eq!(
            agent_tag("", &env_of(&[("CLAUDE_CODE_ENTRYPOINT", "cli")])),
            None
        );
        assert_eq!(agent_tag("", &env_of(&[])), None);
    }

    #[test]
    fn cursor_is_told_apart_from_vs_code() {
        assert_eq!(
            term_editor(&env_of(&[("CURSOR_TRACE_ID", "abc")])),
            Some("cursor")
        );
        assert_eq!(
            term_editor(&env_of(&[(
                "VSCODE_GIT_ASKPASS_NODE",
                r"C:\Users\me\AppData\Local\Programs\cursor\Cursor.exe"
            )])),
            Some("cursor")
        );
        assert_eq!(
            term_editor(&env_of(&[(
                "VSCODE_GIT_ASKPASS_NODE",
                r"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe"
            )])),
            None
        );
        assert_eq!(term_editor(&env_of(&[("CURSOR_TRACE_ID", "")])), None);
        assert_eq!(term_editor(&env_of(&[("TERM_PROGRAM", "vscode")])), None);
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
    fn claude_code_payloads_are_forwarded_as_they_are() {
        let (v, ev) = run(
            r#"{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/p"}"#,
            "",
            "PreToolUse",
        );
        assert_eq!(ev.name, "PreToolUse");
        assert!(v.get("coucou_agent").is_none());
        assert_eq!(v["cwd"], "/p");
        assert_eq!(v["tool_name"], "Bash");
        assert!(v["coucou_event_time_us"].as_u64().unwrap() > 0);
    }

    #[test]
    fn lifecycle_timestamp_is_relay_owned_and_session_end_never_launches() {
        for agent in ["", "codex", "hermes", "opencode", "antigravity"] {
            let (v, ev) = run(
                r#"{"hook_event_name":"SessionEnd","session_id":"session","coucou_event_time_us":1,"coucou_lifecycle":"finalize"}"#,
                agent,
                "",
            );
            assert!(v["coucou_event_time_us"].as_u64().unwrap() > 1);
            assert_eq!(v["coucou_lifecycle"], "finalize");
            assert!(ev.launch_key.is_none());
        }
    }

    #[test]
    fn hermes_plugin_payload_launches_but_normalization_cannot_invent_a_trigger() {
        let (v, ev) = run(
            r#"{"hook_event_name":"SessionStart","session_id":"h","platform":"cli"}"#,
            "hermes",
            "",
        );
        assert_eq!(
            ev.launch_key,
            Some(serde_json::json!(["hermes", "SessionStart", "h"]))
        );
        assert_eq!(v["coucou_agent"], "hermes");
        assert_eq!(v["platform"], "cli");
        let (v, ev) = run(
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"h","turn_id":"h:task:turn"}"#,
            "hermes",
            "",
        );
        assert_eq!(
            ev.launch_key,
            Some(serde_json::json!([
                "hermes",
                "UserPromptSubmit",
                "h",
                "h:task:turn"
            ]))
        );
        assert_eq!(v["coucou_agent"], "hermes");
        assert!(v.get("prompt").is_none());
        for raw in [
            r#"{"hook_event_name":"startup","session_id":"h"}"#,
            r#"{"hook_event_name":"SessionStart","sessionId":"h"}"#,
            r#"{"hook_event_name":"SessionStart","session_id":"","conversation_id":"h"}"#,
            r#"{"hook_event_name":"Stop","session_id":"h"}"#,
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"h"}"#,
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"h","turn_id":""}"#,
            r#"{"session_id":"h"}"#,
        ] {
            let (_, ev) = run(raw, "hermes", "SessionStart");
            assert!(ev.launch_key.is_none(), "{raw}");
        }
        let (_, ev) = run(
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"s","turn_id":"t"}"#,
            "codex",
            "",
        );
        assert_eq!(ev.launch_key, Some(serde_json::json!(["s", "t"])));
    }

    #[test]
    fn opencode_new_and_resumed_messages_use_message_ids_without_prompt_text() {
        for session in ["ses_new", "ses_resumed"] {
            let raw = format!(
                r#"{{"hook_event_name":"UserPromptSubmit","session_id":"{session}","turn_id":"msg_1","prompt":"private input"}}"#
            );
            let (payload, ev) = run(&raw, "opencode", "");
            assert_eq!(
                ev.launch_key,
                Some(json!(["opencode", "UserPromptSubmit", session, "msg_1"]))
            );
            assert_eq!(payload["coucou_agent"], "opencode");
            assert!(!ev.launch_key.unwrap().to_string().contains("private input"));
        }
        for raw in [
            r#"{"hook_event_name":"SessionStart","session_id":"ses_new"}"#,
            r#"{"hook_event_name":"UserPromptSubmit","session_id":"ses_new"}"#,
            r#"{"hook_event_name":"Stop","session_id":"ses_new","turn_id":"msg_1"}"#,
        ] {
            assert!(run(raw, "opencode", "").1.launch_key.is_none());
        }
    }

    #[test]
    fn both_antigravity_apps_use_preinvocation_without_a_prompt_or_synthetic_session() {
        for (id, directory, invocation, steps) in [
            ("ec33ebf9-0cba-4100-8142-c61503f6c587", "antigravity", 0, 0),
            (
                "7c619818-5c45-4e67-910e-f1dd3cffcb83",
                "antigravity-ide",
                7,
                29,
            ),
        ] {
            let raw = json!({
                "conversationId":id, "invocationNum":invocation,
                "initialNumSteps":steps,
                "transcriptPath":format!("/home/me/.gemini/{directory}/brain/{id}/transcript.jsonl")
            });
            let (payload, event) = run(&raw.to_string(), "antigravity", "PreInvocation");
            assert_eq!(event.name, "UserPromptSubmit");
            assert_eq!(
                event.launch_key,
                Some(json!([
                    "antigravity",
                    "PreInvocation",
                    id,
                    invocation,
                    steps
                ]))
            );
            assert_eq!(payload["session_id"], id);
            assert_eq!(payload["coucou_agent"], "antigravity");
            assert!(payload.get("prompt").is_none());
            for ignored in ["PostInvocation", "PreToolUse", "PostToolUse", "Stop"] {
                assert!(run(&raw.to_string(), "antigravity", ignored)
                    .1
                    .launch_key
                    .is_none());
            }
            let mut invalid = raw.clone();
            invalid["conversationId"] = json!("not-a-uuid");
            assert!(run(&invalid.to_string(), "antigravity", "PreInvocation")
                .1
                .launch_key
                .is_none());
            invalid = raw.clone();
            invalid["hook_event_name"] = json!("Stop");
            assert!(run(&invalid.to_string(), "antigravity", "PreInvocation")
                .1
                .launch_key
                .is_none());
        }
    }

    #[test]
    fn claude_start_and_followup_prompt_use_transcript_cursor_without_blocking_permissions() {
        let path =
            std::env::temp_dir().join(format!("coucou-claude-turn-{}.jsonl", std::process::id()));
        let new = json!({"hook_event_name":"SessionStart","session_id":"claude-new","source":"startup","transcript_path":path});
        assert_eq!(
            run(&new.to_string(), "", "").1.launch_key,
            Some(json!([
                "claude-code",
                "SessionStart",
                "claude-new",
                "startup",
                "transcript:0"
            ]))
        );
        let missing_prompt = json!({"hook_event_name":"UserPromptSubmit","session_id":"claude-new","transcript_path":path});
        assert!(run(&missing_prompt.to_string(), "", "")
            .1
            .launch_key
            .is_none());
        for bad in [
            json!(""),
            json!("relative.jsonl"),
            json!(std::env::temp_dir()),
        ] {
            let mut invalid = new.clone();
            invalid["transcript_path"] = bad;
            assert!(run(&invalid.to_string(), "", "").1.launch_key.is_none());
        }
        std::fs::write(&path, b"first transcript entry").unwrap();
        let path = path.to_string_lossy();
        let start = json!({"hook_event_name":"SessionStart","session_id":"claude-1","source":"resume","transcript_path":path});
        let (payload, ev) = run(&start.to_string(), "", "");
        assert_eq!(
            ev.launch_key,
            Some(json!([
                "claude-code",
                "SessionStart",
                "claude-1",
                "resume",
                "transcript:22"
            ]))
        );
        assert!(payload.get("coucou_agent").is_none());
        assert!(payload.get("transcript_path").is_none());
        let prompt = json!({"hook_event_name":"UserPromptSubmit","session_id":"claude-1","transcript_path":path,"prompt":"private input"});
        let (_, first) = run(&prompt.to_string(), "", "");
        assert_eq!(
            first.launch_key,
            Some(json!([
                "claude-code",
                "UserPromptSubmit",
                "claude-1",
                "transcript:22"
            ]))
        );
        assert!(!first
            .launch_key
            .unwrap()
            .to_string()
            .contains("private input"));
        let mut injected_turn = prompt.clone();
        injected_turn["turn_id"] = json!("private input");
        assert_eq!(
            run(&injected_turn.to_string(), "", "").1.launch_key,
            Some(json!([
                "claude-code",
                "UserPromptSubmit",
                "claude-1",
                "transcript:22"
            ]))
        );
        assert!(run(r#"{"hook_event_name":"UserPromptSubmit","session_id":"claude-1","turn_id":"synthetic"}"#, "", "").1.launch_key.is_none());
        std::fs::write(
            path.as_ref(),
            b"first transcript entry\nsecond transcript entry",
        )
        .unwrap();
        let (_, next) = run(&prompt.to_string(), "", "");
        assert_eq!(
            next.launch_key,
            Some(json!([
                "claude-code",
                "UserPromptSubmit",
                "claude-1",
                "transcript:46"
            ]))
        );
        for event in ["Stop", "SessionEnd", "PermissionRequest"] {
            let ignored =
                json!({"hook_event_name":event,"session_id":"claude-1","transcript_path":path});
            assert!(run(&ignored.to_string(), "", "").1.launch_key.is_none());
        }
        let compact = json!({"hook_event_name":"SessionStart","session_id":"claude-1","source":"compact","transcript_path":path});
        assert!(run(&compact.to_string(), "", "").1.launch_key.is_none());
        let missing_session = json!({"hook_event_name":"UserPromptSubmit","transcript_path":path});
        assert!(run(&missing_session.to_string(), "", "")
            .1
            .launch_key
            .is_none());
        let (_, permission) = run(
            r#"{"hook_event_name":"PermissionRequest","session_id":"claude-1","tool_name":"Bash"}"#,
            "",
            "",
        );
        assert!(permission.launch_key.is_none());
        assert_eq!(permission.name, "PermissionRequest");
        let (_, desktop) = {
            let args = Args {
                agent: "".into(),
                event: "".into(),
            };
            let ev = prepare(
                start.to_string().as_bytes(),
                &args,
                &env_of(&[("CLAUDE_CODE_ENTRYPOINT", "claude-desktop")]),
                "",
            )
            .unwrap();
            (serde_json::from_str::<Value>(ev.line.trim()).unwrap(), ev)
        };
        assert!(desktop.launch_key.is_none());
        std::fs::remove_file(path.as_ref()).unwrap();
    }

    #[test]
    fn an_agents_event_is_tagged_and_renamed() {
        // Gemini CLI: its own name in the payload, ours on the command line.
        let (v, ev) = run(
            r#"{"hook_event_name":"BeforeTool","toolCall":{"name":"shell","args":{"CommandLine":"ls"}}}"#,
            "gemini",
            "PreToolUse",
        );
        assert_eq!(ev.name, "PreToolUse");
        assert_eq!(v["hook_event_name"], "PreToolUse");
        assert_eq!(v["coucou_agent"], "gemini");
        assert_eq!(v["tool_input"]["command"], "ls");
        assert_eq!(v["cwd"], "/home/me/here");

        // Copilot CLI sends no event name: the command line's camelCase one is used.
        let (_, ev) = run(r#"{"toolName":"bash"}"#, "copilot", "permissionRequest");
        assert_eq!(ev.name, "PermissionRequest");

        // Cursor: a stop that failed, and its tool output left behind.
        let (v, ev) = run(
            r#"{"hook_event_name":"stop","status":"error","tool_output":"huge"}"#,
            "cursor",
            "",
        );
        assert_eq!(ev.name, "StopFailure");
        assert!(v.get("tool_output").is_none());
    }

    #[test]
    fn a_question_is_kept_whole_and_only_for_ask_user_question() {
        let long = "x".repeat(3000);
        let raw = format!(
            r#"{{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{{"questions":[{{"question":"{long}"}}]}}}}"#
        );
        let (v, ev) = run(&raw, "", "");
        assert_eq!(
            ev.question.unwrap()["questions"][0]["question"]
                .as_str()
                .unwrap()
                .len(),
            3000
        );
        assert!(v["tool_input"]["questions"][0]["question"]
            .as_str()
            .unwrap()
            .ends_with('…'));
        let (_, ev) = run(
            r#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#,
            "",
            "",
        );
        assert!(ev.question.is_none());
    }

    #[test]
    fn what_cannot_be_read_is_not_forwarded() {
        let args = Args {
            agent: "copilot".into(),
            event: "preToolUse".into(),
        };
        for raw in ["", "not json", "[1,2]"] {
            assert!(prepare(raw.as_bytes(), &args, &|_| None, "/").is_none());
        }
        // A BOM is not a reason to drop the event.
        let mut bom = vec![0xEF, 0xBB, 0xBF];
        bom.extend_from_slice(br#"{"hook_event_name":"Stop"}"#);
        assert!(prepare(&bom, &args, &|_| None, "/").is_some());
    }

    #[test]
    fn the_live_diff_rule_holds_through_the_normalised_relay() {
        let big = "z".repeat(10_000);
        // Claude Code's finished Edit: kept whole.
        let raw = format!(
            r#"{{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{{"old_string":"{big}","new_string":"a"}}}}"#
        );
        let (v, _) = run(&raw, "", "");
        assert_eq!(
            v["tool_input"]["old_string"].as_str().unwrap().len(),
            big.len()
        );
        // The same edit before it happens, or an agent's event renamed onto
        // PreToolUse: the ordinary cap.
        let raw = format!(
            r#"{{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{{"old_string":"{big}"}}}}"#
        );
        let (v, _) = run(&raw, "", "");
        assert!(v["tool_input"]["old_string"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4);
        let raw = format!(
            r#"{{"hook_event_name":"BeforeTool","tool_name":"Edit","tool_input":{{"content":"{big}"}}}}"#
        );
        let (v, ev) = run(&raw, "gemini", "");
        assert_eq!(ev.name, "PreToolUse");
        assert!(v["tool_input"]["content"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4);
    }

    #[test]
    fn a_finished_edit_keeps_its_text_whole_for_the_live_diff() {
        let big = "line\n".repeat(4_000); // 20 KB, well past MAX_FIELD_LEN
        let mut v = serde_json::json!({
            "tool_name": "Edit",
            "tool_input": { "file_path": "/p/a.ts", "old_string": big, "new_string": big },
            "cwd": "x".repeat(4_000),
        });
        truncate_payload(&mut v, "PostToolUse");
        assert_eq!(
            v["tool_input"]["old_string"].as_str().unwrap().len(),
            big.len()
        );
        assert_eq!(
            v["tool_input"]["new_string"].as_str().unwrap().len(),
            big.len()
        );
        // Everything else keeps the ordinary cap, and nothing says "cut".
        assert!(v["cwd"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4);
        assert!(v.get("coucou_diff_truncated").is_none());

        let mut multi = serde_json::json!({
            "tool_name": "MultiEdit",
            "tool_input": { "edits": [{ "old_string": big, "new_string": "x" }] },
        });
        truncate_payload(&mut multi, "PostToolUse");
        assert_eq!(
            multi["tool_input"]["edits"][0]["old_string"]
                .as_str()
                .unwrap()
                .len(),
            big.len()
        );
    }

    #[test]
    fn edits_are_still_capped_before_they_happen_and_for_other_tools() {
        let big = "é".repeat(4_000);
        for (event, tool) in [
            ("PreToolUse", "Edit"),
            ("PermissionRequest", "Write"),
            ("PostToolUse", "Bash"),
        ] {
            let mut v = serde_json::json!({ "tool_name": tool, "tool_input": { "content": big } });
            truncate_payload(&mut v, event);
            assert!(
                v["tool_input"]["content"].as_str().unwrap().len() <= MAX_FIELD_LEN + 4,
                "{event} {tool}"
            );
        }
    }

    #[test]
    fn an_edit_beyond_the_budget_is_cut_and_flagged() {
        let huge = "x".repeat(MAX_DIFF_FIELD_LEN + 10);
        let mut v = serde_json::json!({
            "tool_name": "Write",
            "tool_input": { "file_path": "/p/big.txt", "content": huge },
        });
        truncate_payload(&mut v, "PostToolUse");
        assert!(v["tool_input"]["content"].as_str().unwrap().len() <= MAX_DIFF_FIELD_LEN + 4);
        assert_eq!(v["coucou_diff_truncated"], serde_json::Value::Bool(true));

        // Together, the edit strings never pass the shared budget.
        let half = "y".repeat(MAX_DIFF_FIELD_LEN - 1);
        let edits: Vec<_> = (0..4)
            .map(|_| serde_json::json!({ "old_string": half, "new_string": half }))
            .collect();
        let mut multi =
            serde_json::json!({ "tool_name": "MultiEdit", "tool_input": { "edits": edits } });
        truncate_payload(&mut multi, "PostToolUse");
        assert!(multi.to_string().len() < MAX_DIFF_TOTAL + 64 * 1024);
        assert_eq!(
            multi["coucou_diff_truncated"],
            serde_json::Value::Bool(true)
        );
    }
}
