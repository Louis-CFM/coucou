//! coucou-hook — the Windows relay for Claude Code and tagged CLI observers.
//!
//! Reads hook JSON on stdin, translates tagged Kimi, Codex and Hermes events,
//! and hands canonical events to Coucou over `\\.\pipe\coucou-<sid>`.
//!
//! Observer events have a 2 s whole-run deadline; an unavailable pipe exits 0
//! with no output. A `PermissionRequest` from Claude (untagged) or Codex
//! (`--agent codex`) may wait for a decision (up to 110 s); both use the same
//! documented `hookSpecificOutput.decision` shape. Silence hands approval back
//! to the agent's own prompt. Kimi `PermissionRequest` and Hermes
//! `pre_approval_request` become `ApprovalNotice`: a display-only observer event
//! that never receives a decision.
//!
//! A Claude `AskUserQuestion` request is answered with one line
//! `{"answers":[["label"],…]}` (one label list per question, by index). The
//! relay checks it against its own untruncated `tool_input` and emits
//! `updatedInput` with `answers` keyed by the original question text.
//!
//! Usage: `coucou-hook [--agent kimi-code|codex|hermes] [EventName]`.

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
/// Longest string forwarded per field; external prompt/tool display fields
/// are non-verbatim labels, while native cwd remains routing metadata.
const MAX_FIELD_LEN: usize = 2_000;
const MAX_PAYLOAD: usize = (1 << 20) - 1;

mod origin;
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
        match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&path)
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

enum Progress {
    Event(bool),
    Decision(Option<String>, Option<serde_json::Value>),
}

fn main() {
    let started = Instant::now();
    // The worker owns stdin as well as the pipe: an open stdin handle must not
    // hold the observer past its whole-run deadline.
    let (tx, rx) = mpsc::channel::<Progress>();
    std::thread::spawn(move || {
        let Some((payload, event, questions)) = read_event() else { return };
        let waits_for_answer = event == "PermissionRequest";
        if tx.send(Progress::Event(waits_for_answer)).is_ok() {
            let _ = tx.send(Progress::Decision(talk(&payload, waits_for_answer), questions));
        }
    });

    let remaining = |budget: Duration| budget.saturating_sub(started.elapsed());
    let Ok(Progress::Event(waits_for_answer)) = rx.recv_timeout(remaining(FIRE_AND_FORGET_BUDGET)) else {
        std::process::exit(0);
    };
    let budget = if waits_for_answer { DECISION_BUDGET } else { FIRE_AND_FORGET_BUDGET };
    if let Ok(Progress::Decision(Some(decision), questions)) = rx.recv_timeout(remaining(budget)) {
        if let Some(json) = decision_json(&decision, questions.as_ref()) {
            let mut out = std::io::stdout();
            let _ = writeln!(out, "{json}");
            let _ = out.flush();
        }
    }
    // With no permission decision, Claude Code uses its own approval UI;
    // ordinary observer events intentionally print nothing.
    std::process::exit(0);
}

/// The documented PermissionRequest output. Anything we do not recognise prints
/// nothing at all rather than guessing — silence is the safe answer.
/// See https://code.claude.com/docs/en/hooks — Codex documents the identical
/// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":…}}}`
/// shape (https://developers.openai.com/codex/hooks); `message` is accepted on deny.
///
/// `questions` is this relay's own untruncated `tool_input` when the request is
/// a Claude `AskUserQuestion`. The island answers by question index; the labels
/// and question keys come from that original input, never from the island.
fn decision_json(decision: &str, questions: Option<&serde_json::Value>) -> Option<String> {
    let decision = decision.trim();
    let behavior = match decision {
        // A bare allow on a question would make Claude record "no preference":
        // stay silent so Claude asks in its own interface instead.
        "allow" | "always" if questions.is_some() => return None,
        // "always" still answers a plain allow; remembering it is the island's
        // business, not Claude Code's.
        "allow" | "always" => r#"{"behavior":"allow"}"#.to_string(),
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#.to_string(),
        _ if decision.starts_with('{') => {
            let updated = answered_input(questions?, decision)?;
            serde_json::json!({"behavior": "allow", "updatedInput": updated}).to_string()
        }
        _ => return None,
    };
    Some(format!(
        r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#
    ))
}

/// Longest structured answer accepted from the island.
const MAX_ANSWER: usize = 64 * 1024;

/// Maps `{"answers":[["label"],["a","b"]]}` (one entry per question, in order)
/// onto the original tool input. Every label must be one of that question's
/// own options; a single-select question takes exactly one. Anything off
/// returns `None`.
fn answered_input(tool_input: &serde_json::Value, reply: &str) -> Option<serde_json::Value> {
    use serde_json::Value;
    if reply.len() > MAX_ANSWER {
        return None;
    }
    let reply: Value = serde_json::from_str(reply).ok()?;
    let picked = reply.get("answers")?.as_array()?;
    let questions = tool_input.get("questions")?.as_array()?;
    if questions.is_empty() || picked.len() != questions.len() {
        return None;
    }
    let mut answers = serde_json::Map::new();
    for (question, labels) in questions.iter().zip(picked) {
        let text = question.get("question")?.as_str()?;
        let multi = question.get("multiSelect").and_then(Value::as_bool).unwrap_or(false);
        let options: Vec<&str> = question
            .get("options")?
            .as_array()?
            .iter()
            .filter_map(|o| o.get("label").and_then(Value::as_str))
            .collect();
        // The island saw the forwarded copy, where a label over the field limit
        // was cut; map it back to the one original option it came from.
        let labels: Vec<&str> = labels
            .as_array()?
            .iter()
            .map(|l| {
                let l = l.as_str()?;
                if options.contains(&l) {
                    return Some(l);
                }
                let mut cut = options.iter().filter(|o| o.len() > MAX_FIELD_LEN && truncated(o) == l);
                let original = cut.next()?;
                cut.next().is_none().then_some(*original)
            })
            .collect::<Option<_>>()?;
        if labels.is_empty() || (!multi && labels.len() != 1) {
            return None;
        }
        for (i, label) in labels.iter().enumerate() {
            if labels[..i].contains(label) {
                return None;
            }
        }
        if answers.insert(text.to_string(), Value::String(labels.join(", "))).is_some() {
            return None;
        }
    }
    let mut updated = tool_input.clone();
    updated.as_object_mut()?.insert("answers".into(), Value::Object(answers));
    Some(updated)
}

/// The untruncated `tool_input` of an untagged Claude `AskUserQuestion`
/// permission request, kept so answers are keyed by the exact question text.
fn ask_user_question_input(raw: &[u8], agent: Option<&str>) -> Option<serde_json::Value> {
    if agent.is_some() {
        return None;
    }
    let source = serde_json::from_slice::<serde_json::Value>(raw).ok()?;
    let event = source.get("hook_event_name").and_then(|v| v.as_str()).unwrap_or("PermissionRequest");
    if event != "PermissionRequest"
        || source.get("tool_name").and_then(|v| v.as_str()) != Some("AskUserQuestion")
    {
        return None;
    }
    let input = source.get("tool_input")?;
    input.get("questions")?.as_array()?;
    Some(input.clone())
}

/// Reads stdin and returns the payload to forward, the event name, and the
/// original question input of a Claude `AskUserQuestion` request.
fn read_event() -> Option<(String, String, Option<serde_json::Value>)> {
    let mut raw = Vec::new();
    let stdin = std::io::stdin();
    if stdin
        .lock()
        .take((MAX_PAYLOAD + 1) as u64)
        .read_to_end(&mut raw)
        .is_err()
        || raw.is_empty()
        || raw.len() > MAX_PAYLOAD
    {
        return None;
    }
    // Some shells hand us a UTF-8 BOM; serde_json would choke on it.
    if raw.starts_with(&[0xEF, 0xBB, 0xBF]) {
        raw.drain(..3);
    }

    let mut agent = None;
    let mut arg_event = String::new();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        if arg == "--agent" {
            agent = Some(it.next().unwrap_or_default());
        } else if arg_event.is_empty() {
            arg_event = arg;
        }
    }
    let found = std::cell::Cell::new(None);
    let (line, event) = canonical_event_with(&raw, agent.as_deref(), &arg_event, |cwd| {
        found.set(origin::find(cwd));
        found.get()
    })?;
    origin::trace(agent.as_deref().unwrap_or("claude"), &event, found.get());
    let questions = (event == "PermissionRequest")
        .then(|| ask_user_question_input(&raw, agent.as_deref()))
        .flatten();
    Some((line, event, questions))
}

#[cfg(test)]
fn canonical_event(raw: &[u8], agent: Option<&str>, arg_event: &str) -> Option<(String, String)> {
    canonical_event_with(raw, agent, arg_event, |_| None)
}

/// `origin` maps the session's cwd to the `(hwnd, pid, console_pid)` of the
/// window that started it; `None` simply leaves the fields out, as does an
/// unknown `console_pid` for its own field.
fn canonical_event_with(
    raw: &[u8],
    agent: Option<&str>,
    arg_event: &str,
    origin: impl FnOnce(&str) -> Option<(i64, u32, Option<u32>)>,
) -> Option<(String, String)> {
    if raw.len() > MAX_PAYLOAD {
        return None;
    }
    let source = serde_json::from_slice::<serde_json::Value>(raw).ok()?;
    let input = source.as_object()?;
    let mut payload = if matches!(agent, Some("kimi-code" | "codex" | "hermes")) {
        external_event(input, agent?, arg_event)?
    } else {
        let mut value = source;
        let map = value.as_object_mut()?;
        if let Some(agent) = agent {
            map.insert(
                "coucou_agent".into(),
                serde_json::Value::String(agent.to_string()),
            );
        }
        let event = map
            .get("hook_event_name")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(arg_event)
            .to_string();
        map.insert("hook_event_name".into(), serde_json::Value::String(event));
        for field in DROPPED_FIELDS {
            map.remove(*field);
        }
        value
    };
    let map = payload.as_object_mut()?;
    let event = map.get("hook_event_name")?.as_str()?.to_string();
    let cwd_missing = map
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(str::is_empty)
        .unwrap_or(true);
    if cwd_missing && !matches!(agent, Some("kimi-code" | "codex" | "hermes")) {
        if let Ok(cwd) = std::env::current_dir() {
            map.insert(
                "cwd".into(),
                serde_json::Value::String(cwd.to_string_lossy().to_string()),
            );
        }
    }

    if !matches!(agent, Some("kimi-code" | "codex" | "hermes")) {
        // Keep the original terminal context for Claude; external observers
        // do not forward potentially identifying env values.
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
    }

    let cwd = map.get("cwd").and_then(|v| v.as_str()).unwrap_or("").to_string();
    map.remove("origin_hwnd");
    map.remove("origin_pid");
    map.remove("origin_console_pid");
    if let Some((hwnd, pid, console_pid)) = origin(&cwd) {
        map.insert("origin_hwnd".into(), serde_json::Value::from(hwnd));
        map.insert("origin_pid".into(), serde_json::Value::from(pid));
        if let Some(console_pid) = console_pid.filter(|p| *p != 0) {
            map.insert("origin_console_pid".into(), serde_json::Value::from(console_pid));
        }
    }

    truncate_strings(&mut payload);
    let mut line = payload.to_string();
    line.push('\n');
    (line.len() <= 1 << 20).then_some((line, event))
}

fn external_event(
    input: &serde_json::Map<String, serde_json::Value>,
    agent: &str,
    hint: &str,
) -> Option<serde_json::Value> {
    use serde_json::{json, Value};
    let name = input
        .get("hook_event_name")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or(hint);
    let session = input
        .get("session_id")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())?;
    let extra = input.get("extra").and_then(Value::as_object);
    let event = match agent {
        "hermes" => match name {
            "on_session_start" => "SessionStart",
            "pre_llm_call" => "UserPromptSubmit",
            "post_llm_call" => "PostToolUse",
            "pre_tool_call" => "PreToolUse",
            "post_tool_call" => {
                if extra.is_some_and(|e| {
                    e.get("status")
                        .and_then(Value::as_str)
                        .is_some_and(|s| s != "ok")
                        || e.get("error_type").is_some_and(|v| !v.is_null())
                        || e.get("error").is_some_and(|v| !v.is_null())
                }) {
                    "PostToolUseFailure"
                } else {
                    "PostToolUse"
                }
            }
            "on_session_end" => {
                let outcome = extra?;
                if outcome.get("failed").and_then(Value::as_bool) == Some(true)
                    || outcome.get("interrupted").and_then(Value::as_bool) == Some(true)
                {
                    "StopFailure"
                } else if outcome.get("completed").and_then(Value::as_bool) == Some(true) {
                    "Stop"
                } else {
                    return None;
                }
            }
            "on_session_finalize" | "on_session_reset" => "SessionEnd",
            "pre_approval_request" => "ApprovalNotice",
            _ => return None,
        },
        "kimi-code" => match name {
            "PermissionRequest" => "ApprovalNotice",
            "Notification"
                if input.get("notification_type").and_then(Value::as_str)
                    == Some("task.completed") =>
            {
                "SubagentStop"
            }
            "SessionStart" | "UserPromptSubmit" | "PreToolUse" | "PostToolUse"
            | "PostToolUseFailure" | "Stop" | "StopFailure" | "SessionEnd" | "SubagentStart"
            | "SubagentStop" => name,
            _ => return None,
        },
        "codex" => match name {
            "SessionStart" | "UserPromptSubmit" | "PreToolUse" | "PermissionRequest"
            | "PostToolUse" | "Stop" | "SessionEnd" | "SubagentStart" | "SubagentStop" => name,
            "Interrupt" => "StopFailure",
            _ => return None,
        },
        _ => return None,
    };
    let cwd = input.get("cwd").and_then(Value::as_str).unwrap_or("");
    let mut output =
        json!({"coucou_agent": agent, "session_id": session, "hook_event_name": event, "cwd": cwd});
    let map = output.as_object_mut()?;
    if event == "UserPromptSubmit" {
        map.insert("prompt".into(), Value::String("Prompt submitted".into()));
    }
    if matches!(event, "PreToolUse" | "PostToolUse" | "PostToolUseFailure") {
        let name = input.get("tool_name").and_then(Value::as_str).unwrap_or("");
        let safe = safe_tool_name(agent, name);
        map.insert("tool_name".into(), Value::String(safe.into()));
        if event == "PreToolUse" {
            let questions = match safe {
                "AskUserQuestion" | "request_user_input" => {
                    input.get("tool_input").and_then(question_preview)
                }
                "clarify" => input.get("tool_input").and_then(clarify_preview),
                _ => None,
            };
            if let Some(questions) = questions {
                map.insert("tool_input".into(), json!({ "questions": questions }));
            }
        }
    }
    if matches!(event, "PermissionRequest" | "ApprovalNotice") {
        let (tool, target) = approval_preview(agent, input);
        map.insert("tool_name".into(), Value::String(tool));
        if let Some(target) = target {
            map.insert("tool_input".into(), json!({ "command": target }));
        }
    }
    Some(output)
}

/// Tool names an external agent may show as-is; anything else is "Tool".
fn safe_tool_name<'a>(agent: &str, name: &'a str) -> &'a str {
    match name {
        "Bash" | "Read" | "Write" | "Edit" | "Glob" | "Grep" | "WebSearch" | "WebFetch"
        | "TodoWrite" | "Task" | "PowerShell" | "terminal" | "apply_patch" => name,
        "AskUserQuestion" if agent == "kimi-code" => name,
        "request_user_input" if agent == "codex" => name,
        "clarify" if agent == "hermes" => name,
        _ => "Tool",
    }
}

/// Longest approval target (command or reason) shown on an approval card.
const MAX_APPROVAL_TEXT: usize = 300;

/// What an approval is about: a display tool name and one short, capped line
/// (the command, else the agent's own approval description). Nothing else from
/// the request crosses the pipe.
///
/// - Codex `PermissionRequest`: `tool_name`, `tool_input.command` / `.description`.
/// - Kimi `PermissionRequest`: `tool_name`, `action` (its own approval text),
///   `tool_input.command`.
/// - Hermes `pre_approval_request`: `extra.command`, `extra.description`.
fn approval_preview(
    agent: &str,
    input: &serde_json::Map<String, serde_json::Value>,
) -> (String, Option<String>) {
    use serde_json::Value;
    let text = |v: Option<&Value>| -> Option<String> {
        let s = v?.as_str()?.trim();
        (!s.is_empty()).then(|| cap_text(s, MAX_APPROVAL_TEXT))
    };
    let tool_input = input.get("tool_input");
    let extra = input.get("extra");
    let raw_tool = input.get("tool_name").and_then(Value::as_str).unwrap_or("");
    let tool = match agent {
        "hermes" => "terminal".to_string(),
        "codex" if raw_tool.starts_with("mcp__") => "MCP".to_string(),
        _ => safe_tool_name(agent, raw_tool).to_string(),
    };
    let target = match agent {
        "hermes" => text(extra.and_then(|e| e.get("command")))
            .or_else(|| text(extra.and_then(|e| e.get("description")))),
        "kimi-code" => text(tool_input.and_then(|t| t.get("command")))
            .or_else(|| text(input.get("action"))),
        _ => text(tool_input.and_then(|t| t.get("command")))
            .or_else(|| text(tool_input.and_then(|t| t.get("description")))),
    };
    (tool, target)
}

/// `s` cut to at most `max` bytes on a char boundary, with an ellipsis when cut.
fn cap_text(s: &str, max: usize) -> String {
    let mut end = s.len().min(max);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    let mut out = s[..end].to_string();
    if end < s.len() {
        out.push('…');
    }
    out
}

/// Hermes `clarify` asks `questions: [{question, choices?, multi_select?}]`.
/// Only questions with choices become a read-only multiple-choice card;
/// open-ended ones are left for Hermes' own window.
fn clarify_preview(tool_input: &serde_json::Value) -> Option<serde_json::Value> {
    use serde_json::{json, Value};
    let questions: Vec<Value> = tool_input
        .get("questions")?
        .as_array()?
        .iter()
        .filter_map(|q| {
            let options: Vec<Value> = q
                .get("choices")
                .and_then(Value::as_array)?
                .iter()
                .filter(|label| label.as_str().is_some_and(|s| !s.trim().is_empty()))
                .map(|label| json!({ "label": label }))
                .collect();
            if options.is_empty() {
                return None;
            }
            Some(json!({
                "question": q.get("question").cloned().unwrap_or(Value::Null),
                "multiSelect": q.get("multi_select").and_then(Value::as_bool).unwrap_or(false),
                "options": options,
            }))
        })
        .collect();
    question_preview(&json!({ "questions": questions }))
}

/// Longest question, header, label or description shown for an external agent.
const MAX_QUESTION_TEXT: usize = 300;
const MAX_QUESTIONS: usize = 8;
const MAX_OPTIONS: usize = 12;

/// A display-only copy of an external agent's multiple-choice questions:
/// question text, header, multi-select flag and option labels/descriptions,
/// each capped. Nothing else from the tool input crosses the pipe.
fn question_preview(tool_input: &serde_json::Value) -> Option<serde_json::Value> {
    use serde_json::{json, Value};
    let cap = |v: Option<&Value>| -> Option<String> {
        let s = v?.as_str()?.trim();
        if s.is_empty() {
            return None;
        }
        let mut end = s.len().min(MAX_QUESTION_TEXT);
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        let mut out = s[..end].to_string();
        if end < s.len() {
            out.push('…');
        }
        Some(out)
    };
    let questions: Vec<Value> = tool_input
        .get("questions")?
        .as_array()?
        .iter()
        .take(MAX_QUESTIONS)
        .filter_map(|q| {
            let question = cap(q.get("question"))?;
            let options: Vec<Value> = q
                .get("options")
                .and_then(Value::as_array)
                .map(|o| o.as_slice())
                .unwrap_or_default()
                .iter()
                .take(MAX_OPTIONS)
                .filter_map(|o| {
                    let label = cap(o.get("label")).or_else(|| cap(Some(o)))?;
                    let mut option = json!({ "label": label });
                    if let Some(d) = cap(o.get("description")) {
                        option["description"] = Value::String(d);
                    }
                    Some(option)
                })
                .collect();
            let mut out = json!({
                "question": question,
                "multiSelect": q.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
                "options": options,
            });
            if let Some(header) = cap(q.get("header")) {
                out["header"] = Value::String(header);
            }
            Some(out)
        })
        .collect();
    (!questions.is_empty()).then(|| Value::Array(questions))
}

/// A string as `truncate_strings` forwards it.
fn truncated(s: &str) -> String {
    let mut v = serde_json::Value::String(s.to_string());
    truncate_strings(&mut v);
    v.as_str().unwrap_or_default().to_string()
}

/// Caps strings for the frame limit; external cwd is canonical metadata, not a display preview.
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
                if buf.len() > MAX_ANSWER {
                    return None;
                }
            }
            Err(_) => break,
        }
    }
    decision_line(&buf)
}

/// First line of the server's reply, or `None` when empty, oversized or not UTF-8.
fn decision_line(buf: &[u8]) -> Option<String> {
    let line = buf.split(|b| *b == b'\n').next()?;
    if line.len() > MAX_ANSWER {
        return None;
    }
    let answer = std::str::from_utf8(line).ok()?.trim().to_string();
    (!answer.is_empty()).then_some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decision_json_matches_the_documented_shape() {
        assert_eq!(
            decision_json("allow", None).unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        );
        assert_eq!(
            decision_json("deny", None).unwrap(),
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Coucou"}}}"#
        );
        // "always" is an island concept; Claude Code just gets an allow.
        assert!(decision_json("always", None)
            .unwrap()
            .contains(r#""behavior":"allow""#));
    }

    #[test]
    fn anything_unrecognised_prints_nothing() {
        assert!(decision_json("", None).is_none());
        assert!(decision_json("maybe", None).is_none());
        // The shape the app used to send must not be mistaken for a decision.
        assert!(decision_json(r#"{"permissionDecision":"allow"}"#, None).is_none());
        // A structured answer without an original question input is ignored.
        assert!(decision_json(r#"{"answers":[["A"]]}"#, None).is_none());
    }

    fn mcq() -> serde_json::Value {
        serde_json::json!({
            "questions": [
                {"question": "Which style?", "header": "Grill me", "multiSelect": false,
                 "options": [{"label": "Anime cel video", "description": "flat"}, {"label": "Photoreal"}]},
                {"question": "Which extras?", "header": "Extras", "multiSelect": true,
                 "options": [{"label": "Music"}, {"label": "Captions"}, {"label": "Logo"}]}
            ]
        })
    }

    fn answered(decision: &str, input: &serde_json::Value) -> Option<serde_json::Value> {
        let json = decision_json(decision, Some(input))?;
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["hookSpecificOutput"]["hookEventName"], "PermissionRequest");
        assert_eq!(value["hookSpecificOutput"]["decision"]["behavior"], "allow");
        Some(value["hookSpecificOutput"]["decision"]["updatedInput"].clone())
    }

    #[test]
    fn single_select_answer_is_keyed_by_the_question_text() {
        let input = serde_json::json!({"questions": [mcq()["questions"][0].clone()]});
        let updated = answered(r#"{"answers":[["Anime cel video"]]}"#, &input).unwrap();
        assert_eq!(updated["answers"]["Which style?"], "Anime cel video");
        assert_eq!(updated["questions"], input["questions"]);
    }

    #[test]
    fn multi_select_and_multiple_questions_join_labels_with_comma_space() {
        let updated = answered(r#"{"answers":[["Photoreal"],["Music","Logo"]]}"#, &mcq()).unwrap();
        assert_eq!(updated["answers"]["Which style?"], "Photoreal");
        assert_eq!(updated["answers"]["Which extras?"], "Music, Logo");
        assert_eq!(updated["answers"].as_object().unwrap().len(), 2);
        assert_eq!(updated["questions"], mcq()["questions"]);
    }

    #[test]
    fn invalid_answers_print_nothing() {
        let input = mcq();
        for bad in [
            r#"{"answers":[["Nope"],["Music"]]}"#,
            r#"{"answers":[["Photoreal","Anime cel video"],["Music"]]}"#,
            r#"{"answers":[[],["Music"]]}"#,
            r#"{"answers":[["Photoreal"],["Music","Music"]]}"#,
            r#"{"answers":[["Photoreal"]]}"#,
            r#"{"answers":[["Photoreal"],["Music"],["Logo"]]}"#,
            r#"{"answers":[["Photoreal"],[1]]}"#,
            r#"{"answers":{"0":["Photoreal"]}}"#,
            r#"{"answers":[["Photoreal"],["Music"]]"#,
        ] {
            assert!(decision_json(bad, Some(&input)).is_none(), "{bad}");
        }
        let huge = format!(r#"{{"answers":[["{}"],["Music"]]}}"#, "x".repeat(MAX_ANSWER));
        assert!(decision_json(&huge, Some(&input)).is_none());
    }

    #[test]
    fn question_requests_never_get_a_bare_allow_but_can_be_denied() {
        assert!(decision_json("allow", Some(&mcq())).is_none());
        assert!(decision_json("always", Some(&mcq())).is_none());
        assert!(decision_json("deny", Some(&mcq())).unwrap().contains(r#""behavior":"deny""#));
    }

    #[test]
    fn long_question_text_is_keyed_by_the_relays_untruncated_copy() {
        let long = format!("{}?", "Q".repeat(3000));
        let label = "L".repeat(2500);
        let raw = serde_json::json!({
            "hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "session_id": "s",
            "tool_input": {"questions": [{"question": long, "multiSelect": false, "options": [{"label": label}]}]}
        })
        .to_string();
        let (line, _) = canonical_event(raw.as_bytes(), None, "").unwrap();
        assert!(!line.contains(&long), "forwarded copy is truncated");
        let forwarded: serde_json::Value = serde_json::from_str(&line).unwrap();
        let seen = forwarded["tool_input"]["questions"][0]["options"][0]["label"].as_str().unwrap();
        assert_ne!(seen, label);
        let input = ask_user_question_input(raw.as_bytes(), None).unwrap();
        for picked in [label.as_str(), seen] {
            let reply = serde_json::json!({"answers": [[picked]]}).to_string();
            let updated = answered(&reply, &input).unwrap();
            assert_eq!(updated["answers"][&long], label);
            assert_eq!(updated["questions"][0]["question"], long);
        }
        // A cut label shared by two original options is ambiguous: nothing printed.
        let twin = serde_json::json!({"questions": [{"question": "Q?", "multiSelect": false,
            "options": [{"label": format!("{label}a")}, {"label": format!("{label}b")}]}]});
        let reply = serde_json::json!({"answers": [[truncated(&format!("{label}a"))]]}).to_string();
        assert!(decision_json(&reply, Some(&twin)).is_none());
    }

    #[test]
    fn only_untagged_claude_ask_user_question_keeps_original_input() {
        let raw = br#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#;
        assert!(ask_user_question_input(raw, None).is_some());
        assert!(ask_user_question_input(raw, Some("kimi-code")).is_none());
        assert!(ask_user_question_input(br#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"x"}}"#, None).is_none());
        assert!(ask_user_question_input(br#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#, None).is_none());
    }

    #[test]
    fn decision_line_is_framed_and_bounded() {
        assert_eq!(decision_line(b"allow\n").as_deref(), Some("allow"));
        assert_eq!(decision_line(b"{\"answers\":[[\"A\"]]}\nextra").as_deref(), Some(r#"{"answers":[["A"]]}"#));
        assert!(decision_line(b"\n").is_none());
        assert!(decision_line(&[0xff, 0xfe, b'\n']).is_none());
        assert!(decision_line(&vec![b'x'; MAX_ANSWER + 1]).is_none());
    }

    #[test]
    fn external_question_tools_forward_only_capped_question_fields() {
        let long = "é".repeat(400);
        for (agent, tool) in [("kimi-code", "AskUserQuestion"), ("codex", "request_user_input")] {
            let raw = serde_json::json!({
                "hook_event_name": "PreToolUse", "session_id": "s-1", "tool_name": tool,
                "tool_input": {"secret": "sk-short", "questions": [
                    {"question": long, "header": "H", "multiSelect": true, "id": "sk-short",
                     "options": [{"label": "A", "description": "first", "value": "sk-short"}, {"label": "B"}]}
                ]}
            })
            .to_string();
            let value = translated(raw.as_bytes(), agent, "");
            assert_eq!(value["tool_name"], tool);
            let text = value.to_string();
            assert!(!text.contains("sk-short"), "{agent}");
            let q = &value["tool_input"]["questions"][0];
            assert!(q["question"].as_str().unwrap().len() <= MAX_QUESTION_TEXT + 3);
            assert!(q["question"].as_str().unwrap().ends_with('…'));
            assert_eq!(q["header"], "H");
            assert_eq!(q["multiSelect"], true);
            assert_eq!(q["options"][0]["label"], "A");
            assert_eq!(q["options"][0]["description"], "first");
            assert_eq!(q["options"][1]["label"], "B");
        }
        // The other agent's question tool name is not allowlisted.
        let raw = br#"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"request_user_input","tool_input":{"questions":[{"question":"Q?"}]}}"#;
        let value = translated(raw, "kimi-code", "");
        assert_eq!(value["tool_name"], "Tool");
        assert!(value.get("tool_input").is_none());
        // Hermes never forwards questions.
        let raw = br#"{"hook_event_name":"pre_tool_call","session_id":"s-1","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?"}]}}"#;
        let value = translated(raw, "hermes", "");
        assert!(value.get("tool_input").is_none());
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
    fn relay_tags_and_canonicalizes_external_hook_json() {
        let (line, event) = canonical_event(
            br#"{"session_id":"s1","prompt":"hi"}"#,
            Some("kimi-code"),
            "UserPromptSubmit",
        )
        .unwrap();
        assert_eq!(event, "UserPromptSubmit");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["coucou_agent"], "kimi-code");
        assert_eq!(value["hook_event_name"], "UserPromptSubmit");
        assert!(line.ends_with('\n'));
    }

    #[test]
    fn relay_preserves_invalid_explicit_tag_for_ingress_to_reject() {
        let (line, _) =
            canonical_event(br#"{"hook_event_name":"Stop"}"#, Some(""), "Stop").unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["coucou_agent"], "");
    }

    #[test]
    fn relay_keeps_legacy_claude_untagged() {
        let (line, _) =
            canonical_event(br#"{"hook_event_name":"PermissionRequest"}"#, None, "").unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert!(value.get("coucou_agent").is_none());
    }

    fn translated(raw: &[u8], agent: &str, hint: &str) -> serde_json::Value {
        let (line, event) = canonical_event(raw, Some(agent), hint).unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["hook_event_name"], event);
        assert!(line.ends_with('\n'));
        value
    }

    #[test]
    fn kimi_foreground_stop_and_failure_keep_session_identity() {
        let stop = translated(
            include_bytes!("../tests/fixtures/kimi.json"),
            "kimi-code",
            "",
        );
        assert_eq!(stop["hook_event_name"], "Stop");
        assert_eq!(stop["session_id"], "kimi-session-1");
        assert_eq!(stop["cwd"], r"C:\Work Space\demo");
        let failure = translated(br#"{"hook_event_name":"StopFailure","session_id":"kimi-session-1","cwd":"C:\\Work Space\\demo","error_type":"tool_error"}"#, "kimi-code", "");
        assert_eq!(failure["hook_event_name"], "StopFailure");
    }

    #[test]
    fn kimi_background_notification_becomes_a_step_not_a_second_stop() {
        let value = translated(br#"{"hook_event_name":"Notification","session_id":"kimi-session-1","cwd":"C:\\Work Space\\demo","notification_type":"task.completed","task_id":"task-1","message":"Background task done"}"#, "kimi-code", "");
        assert_eq!(value["hook_event_name"], "SubagentStop");
        assert!(value.get("task_id").is_none());
        assert!(canonical_event(br#"{"hook_event_name":"Notification","session_id":"kimi-session-1","notification_type":"task.started"}"#, Some("kimi-code"), "").is_none());
    }

    #[test]
    fn codex_stop_is_a_turn_completion_not_session_teardown() {
        let value = translated(include_bytes!("../tests/fixtures/codex.json"), "codex", "");
        assert_eq!(value["hook_event_name"], "Stop");
        assert_eq!(value["session_id"], "thr_test_123");
        assert_eq!(value["cwd"], r"C:\Work Space\demo");
        assert!(value.get("transcript_path").is_none());
        assert!(value.get("last_assistant_message").is_none());
    }

    #[test]
    fn hermes_turn_outcome_and_teardown_are_distinct() {
        let stop = translated(
            include_bytes!("../tests/fixtures/hermes.json"),
            "hermes",
            "",
        );
        assert_eq!(stop["hook_event_name"], "Stop");
        assert_eq!(stop["session_id"], "hermes-session-1");
        assert_eq!(stop["cwd"], r"C:\Work Space\demo");
        assert!(stop.get("message").is_none());
        assert!(stop.get("extra").is_none());
        let response = translated(br#"{"hook_event_name":"post_llm_call","session_id":"hermes-session-1","extra":{"assistant_response":"Finished the work","conversation_history":["sensitive"]}}"#, "hermes", "");
        assert_eq!(response["hook_event_name"], "PostToolUse");
        assert!(response.get("extra").is_none());
        let failure = translated(br#"{"hook_event_name":"on_session_end","session_id":"hermes-session-1","extra":{"completed":false,"failed":true,"interrupted":false}}"#, "hermes", "");
        assert_eq!(failure["hook_event_name"], "StopFailure");
        let interrupted = translated(br#"{"hook_event_name":"on_session_end","session_id":"hermes-session-1","extra":{"completed":false,"failed":false,"interrupted":true}}"#, "hermes", "");
        assert_eq!(interrupted["hook_event_name"], "StopFailure");
        let end = translated(br#"{"hook_event_name":"on_session_finalize","session_id":"hermes-session-1","extra":{}}"#, "hermes", "");
        assert_eq!(end["hook_event_name"], "SessionEnd");
    }

    #[test]
    fn hermes_prompt_and_tool_events_forward_only_preview_fields() {
        let prompt = translated(br#"{"hook_event_name":"pre_llm_call","session_id":"h-1","cwd":"C:\\Work Space\\demo","extra":{"user_message":"check it","conversation_history":["sensitive"],"model":"gpt-4"}}"#, "hermes", "");
        assert_eq!(prompt["hook_event_name"], "UserPromptSubmit");
        assert_eq!(prompt["prompt"], "Prompt submitted");
        assert!(prompt.get("extra").is_none());
        let tool = translated(br#"{"hook_event_name":"pre_tool_call","session_id":"h-1","tool_name":"terminal","tool_input":{"command":"git status","secret":"hidden"},"extra":{"result":"sensitive"}}"#, "hermes", "");
        assert_eq!(tool["hook_event_name"], "PreToolUse");
        assert_eq!(tool["tool_name"], "terminal");
        assert!(tool.get("tool_input").is_none());
        let post = translated(br#"{"hook_event_name":"post_tool_call","session_id":"h-1","tool_name":"terminal","extra":{"result":"sensitive","error":"failed"}}"#, "hermes", "");
        assert_eq!(post["hook_event_name"], "PostToolUseFailure");
        assert!(post.get("extra").is_none());
    }

    #[test]
    fn malformed_external_payload_is_never_forwarded() {
        for agent in ["kimi-code", "codex", "hermes"] {
            assert!(canonical_event(b"not json", Some(agent), "Stop").is_none());
            assert!(canonical_event(br#"{"hook_event_name":"Stop"}"#, Some(agent), "").is_none());
        }
        // Hermes has no PermissionRequest event; its approval observer is pre_approval_request.
        assert!(canonical_event(
            br#"{"hook_event_name":"PermissionRequest","session_id":"s-1"}"#,
            Some("hermes"),
            ""
        )
        .is_none());
        assert!(canonical_event(
            br#"{"hook_event_name":"on_session_end","session_id":"s-1","extra":{}}"#,
            Some("hermes"),
            ""
        )
        .is_none());
    }

    #[test]
    fn external_short_secrets_in_prompts_and_tool_inputs_do_not_reach_the_canonical_frame() {
        for agent in ["kimi-code", "codex"] {
            let raw = br#"{"hook_event_name":"UserPromptSubmit","session_id":"s-1","prompt":"api_key=sk-short"}"#;
            let (line, _) = canonical_event(raw, Some(agent), "").unwrap();
            assert!(!line.contains("sk-short"));
            assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["prompt"], "Prompt submitted");
            let raw = br#"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"curl -H 'Authorization: Bearer sk-short' https://example.invalid","path":"C:\\private\\sk-short","query":"sk-short"}}"#;
            let (line, _) = canonical_event(raw, Some(agent), "").unwrap();
            assert!(!line.contains("sk-short"));
            assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["tool_name"], "Bash");
        }
        let raw = br#"{"hook_event_name":"pre_llm_call","session_id":"s-1","extra":{"user_message":"api_key=sk-short"}}"#;
        let (line, _) = canonical_event(raw, Some("hermes"), "").unwrap();
        assert!(!line.contains("sk-short"));
        assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["prompt"], "Prompt submitted");
        let raw = br#"{"hook_event_name":"pre_tool_call","session_id":"s-1","tool_name":"terminal","tool_input":{"command":"echo sk-short","file_path":"sk-short"}}"#;
        let (line, _) = canonical_event(raw, Some("hermes"), "").unwrap();
        assert!(!line.contains("sk-short"));
        assert_eq!(serde_json::from_str::<serde_json::Value>(&line).unwrap()["tool_name"], "terminal");
    }

    #[test]
    fn external_untrusted_tool_labels_and_response_do_not_leak_short_secrets() {
        let raw = br#"{"hook_event_name":"PreToolUse","session_id":"s-1","cwd":"C:\\private\\sk-short","tool_name":"sk-short","tool_input":{"command":"echo sk-short"}}"#;
        let (line, _) = canonical_event(raw, Some("codex"), "").unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(value["tool_name"], "Tool");
        assert_eq!(value["cwd"], r"C:\private\sk-short");
        assert!(value.get("tool_input").is_none());
        assert!(value.get("prompt").is_none());
        assert_eq!(value.as_object().unwrap().len(), 5);
        let raw = br#"{"hook_event_name":"on_session_end","session_id":"s-1","extra":{"completed":true,"assistant_response":"sk-short"}}"#;
        let (line, _) = canonical_event(raw, Some("hermes"), "").unwrap();
        assert!(!line.contains("sk-short"));
    }

    #[test]
    fn origin_window_is_forwarded_for_every_agent_when_found() {
        for agent in [None, Some("kimi-code"), Some("codex"), Some("hermes")] {
            let raw: &[u8] = match agent {
                Some("hermes") => br#"{"hook_event_name":"on_session_start","session_id":"s-1","cwd":"C:\\w\\demo"}"#,
                _ => br#"{"hook_event_name":"SessionStart","session_id":"s-1","cwd":"C:\\w\\demo","origin_hwnd":1,"origin_pid":2,"origin_console_pid":3}"#,
            };
            let mut seen = String::new();
            let (line, _) = canonical_event_with(raw, agent, "", |cwd| {
                seen = cwd.to_string();
                Some((0x1234, 4321, Some(5555)))
            })
            .unwrap();
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(seen, r"C:\w\demo", "{agent:?}");
            assert_eq!(value["origin_hwnd"], 0x1234, "{agent:?}");
            assert_eq!(value["origin_pid"], 4321, "{agent:?}");
            assert_eq!(value["origin_console_pid"], 5555, "{agent:?}");
            let (line, _) = canonical_event_with(raw, agent, "", |_| Some((0x1234, 4321, None))).unwrap();
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(value["origin_pid"], 4321, "{agent:?}");
            assert!(value.get("origin_console_pid").is_none(), "{agent:?}");
        }
    }

    #[test]
    fn origin_fields_are_omitted_when_no_window_is_found() {
        for agent in [None, Some("codex")] {
            let raw = br#"{"hook_event_name":"Stop","session_id":"s-1","cwd":"C:\\w","origin_hwnd":7,"origin_pid":8,"origin_console_pid":9}"#;
            let (line, _) = canonical_event_with(raw, agent, "", |_| None).unwrap();
            let value: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert!(value.get("origin_hwnd").is_none(), "{agent:?}");
            assert!(value.get("origin_pid").is_none(), "{agent:?}");
            assert!(value.get("origin_console_pid").is_none(), "{agent:?}");
        }
    }

    #[test]
    fn codex_permission_request_is_forwarded_with_a_capped_target_only() {
        let long = format!("rm -rf build && echo {}", "x".repeat(800));
        let raw = serde_json::json!({
            "hook_event_name": "PermissionRequest", "session_id": "thr-1", "turn_id": "t",
            "cwd": "C:\\w", "tool_name": "Bash", "permission_mode": "default",
            "transcript_path": "C:\\secret\\rollout.jsonl",
            "tool_input": {"command": long, "description": "needs network", "env": "sk-short"}
        })
        .to_string();
        let value = translated(raw.as_bytes(), "codex", "");
        assert_eq!(value["hook_event_name"], "PermissionRequest");
        assert_eq!(value["coucou_agent"], "codex");
        assert_eq!(value["tool_name"], "Bash");
        let command = value["tool_input"]["command"].as_str().unwrap();
        assert!(command.starts_with("rm -rf build"));
        assert!(command.len() <= MAX_APPROVAL_TEXT + 3 && command.ends_with('…'));
        let text = value.to_string();
        assert!(!text.contains("sk-short") && !text.contains("rollout") && !text.contains("turn_id"));
        assert_eq!(value["tool_input"].as_object().unwrap().len(), 1);
        // No command: the agent's own approval reason is shown instead.
        let raw = br#"{"hook_event_name":"PermissionRequest","session_id":"thr-1","tool_name":"mcp__fs__write","tool_input":{"description":"Write a file","path":"sk-short"}}"#;
        let value = translated(raw, "codex", "");
        assert_eq!(value["tool_name"], "MCP");
        assert_eq!(value["tool_input"]["command"], "Write a file");
        assert!(!value.to_string().contains("sk-short"));
    }

    #[test]
    fn codex_permission_decisions_use_the_documented_shape() {
        // Codex documents the same hookSpecificOutput.decision as Claude Code.
        let allow: serde_json::Value = serde_json::from_str(&decision_json("allow", None).unwrap()).unwrap();
        assert_eq!(allow["hookSpecificOutput"]["hookEventName"], "PermissionRequest");
        assert_eq!(allow["hookSpecificOutput"]["decision"], serde_json::json!({"behavior": "allow"}));
        let deny: serde_json::Value = serde_json::from_str(&decision_json("deny", None).unwrap()).unwrap();
        assert_eq!(deny["hookSpecificOutput"]["decision"]["behavior"], "deny");
        // Reserved fields fail closed in Codex: never emitted.
        for d in ["allow", "deny", "always"] {
            let out = decision_json(d, None).unwrap();
            assert!(!out.contains("updatedInput") && !out.contains("updatedPermissions") && !out.contains("interrupt"));
        }
        // Codex never gets a question payload, so an answers line prints nothing.
        assert!(decision_json(r#"{"answers":[["A"]]}"#, None).is_none());
        let raw = br#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#;
        assert!(ask_user_question_input(raw, Some("codex")).is_none());
    }

    #[test]
    fn kimi_and_hermes_approvals_become_display_only_notices() {
        let raw = br#"{"hook_event_name":"PermissionRequest","session_id":"k-1","cwd":"C:\\w","tool_name":"Bash","action":"Run a shell command","tool_input":{"command":"git push --force","token":"sk-short"},"display":{"detail":"sk-short"}}"#;
        let value = translated(raw, "kimi-code", "");
        assert_eq!(value["hook_event_name"], "ApprovalNotice");
        assert_eq!(value["tool_name"], "Bash");
        assert_eq!(value["tool_input"]["command"], "git push --force");
        assert!(!value.to_string().contains("sk-short"));
        let raw = br#"{"hook_event_name":"PermissionRequest","session_id":"k-1","tool_name":"WeirdTool","action":"Approve WeirdTool","tool_input":{"x":"sk-short"}}"#;
        let value = translated(raw, "kimi-code", "");
        assert_eq!(value["tool_name"], "Tool");
        assert_eq!(value["tool_input"]["command"], "Approve WeirdTool");
        let raw = br#"{"hook_event_name":"pre_approval_request","tool_name":null,"tool_input":null,"session_id":"h-1","cwd":"C:\\w","extra":{"command":"rm -rf /tmp/x","description":"dangerous delete","pattern_key":"rm","session_key":"sk-short","surface":"cli"}}"#;
        let value = translated(raw, "hermes", "");
        assert_eq!(value["hook_event_name"], "ApprovalNotice");
        assert_eq!(value["tool_name"], "terminal");
        assert_eq!(value["tool_input"]["command"], "rm -rf /tmp/x");
        assert!(!value.to_string().contains("sk-short"));
        // Results of an approval are not forwarded.
        assert!(canonical_event(br#"{"hook_event_name":"post_approval_response","session_id":"h-1","extra":{"choice":"once"}}"#, Some("hermes"), "").is_none());
        assert!(canonical_event(br#"{"hook_event_name":"PermissionResult","session_id":"k-1"}"#, Some("kimi-code"), "").is_none());
    }

    #[test]
    fn hermes_clarify_becomes_a_read_only_question_preview() {
        let raw = serde_json::json!({
            "hook_event_name": "pre_tool_call", "session_id": "h-1", "tool_name": "clarify",
            "tool_input": {"questions": [
                {"question": "Which db?", "choices": ["Postgres", "SQLite", " "], "multi_select": true},
                {"question": "Anything else?"},
                {"question": "Deploy?", "choices": ["Yes", "No"]}
            ], "secret": "sk-short"},
            "extra": {"task_id": "sk-short"}
        })
        .to_string();
        let value = translated(raw.as_bytes(), "hermes", "");
        assert_eq!(value["hook_event_name"], "PreToolUse");
        assert_eq!(value["tool_name"], "clarify");
        let questions = value["tool_input"]["questions"].as_array().unwrap();
        assert_eq!(questions.len(), 2);
        assert_eq!(questions[0]["question"], "Which db?");
        assert_eq!(questions[0]["multiSelect"], true);
        assert_eq!(questions[0]["options"].as_array().unwrap().len(), 2);
        assert_eq!(questions[0]["options"][1]["label"], "SQLite");
        assert_eq!(questions[1]["question"], "Deploy?");
        assert_eq!(questions[1]["multiSelect"], false);
        let open_ended = br#"{"hook_event_name":"pre_tool_call","session_id":"h-1","tool_name":"clarify","tool_input":{"questions":[{"question":"Why?"}]}}"#;
        assert!(translated(open_ended, "hermes", "").get("tool_input").is_none());
        assert!(!value.to_string().contains("sk-short"));
        // Other agents' clarify is just "Tool".
        let raw = br#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"clarify","tool_input":{"questions":[{"question":"Q?","choices":["a"]}]}}"#;
        let value = translated(raw, "codex", "");
        assert_eq!(value["tool_name"], "Tool");
        assert!(value.get("tool_input").is_none());
    }

    #[test]
    fn oversized_stdin_and_preview_are_rejected_or_bounded() {
        let raw = serde_json::json!({"hook_event_name":"Stop","session_id":"s-1","prompt":"x".repeat(1 << 20)}).to_string();
        assert!(canonical_event(raw.as_bytes(), Some("kimi-code"), "").is_none());
        let raw = serde_json::json!({"hook_event_name":"UserPromptSubmit","session_id":"s-1","prompt":"é".repeat(4000)}).to_string();
        let value = translated(raw.as_bytes(), "kimi-code", "");
        assert_eq!(value["prompt"], "Prompt submitted");
    }
}
