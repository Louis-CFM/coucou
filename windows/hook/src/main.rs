//! Relay coding-agent lifecycle events over `\\.\pipe\coucou-<sid>`.
//!
//! Usage: `coucou-hook [--agent <name>] [EventName]`. The native Codex
//! integration requires `--agent codex <EventName>` for its stdout contract.
//! No app, malformed input, timeout or unknown reply means no approval decision:
//! the agent keeps its normal approval flow. Codex Stop/SubagentStop receive an
//! empty JSON object because their successful output must be JSON.

use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use serde_json::{Map, Value};

const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// Includes connection, bounded stdin read, parsing and serialisation.
const PREPARE_BUDGET: Duration = Duration::from_secs(2);
const FIRE_AND_FORGET_BUDGET: Duration = Duration::from_secs(2);
const DECISION_BUDGET: Duration = Duration::from_secs(110);
/// Must fit the server's frame limit, including the terminating newline.
const MAX_PAYLOAD: usize = 1 << 20;
const MAX_REPLY: usize = 64;
const MAX_FIELD_LEN: usize = 2_000;
const DROPPED_FIELDS: &[&str] = &["tool_response", "transcript_path"];

#[cfg(windows)]
mod win;
#[cfg(windows)]
use win::connect;
#[cfg(target_os = "linux")]
mod unix;
#[cfg(target_os = "linux")]
use unix::connect;
#[cfg(test)]
mod tests;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Agent { Claude, Codex, External }

#[derive(Clone, Debug, PartialEq, Eq)]
struct Args {
    agent: Agent,
    event: String,
    /// None means stdin may supply a tag. An explicit, even invalid, tag wins.
    agent_tag: Option<String>,
}

fn agent_from_tag(tag: Option<&str>) -> Agent {
    match tag {
        Some("codex") => Agent::Codex,
        Some("claude") => Agent::Claude,
        Some(name) if valid_agent_name(name) => Agent::External,
        _ => Agent::Claude,
    }
}

fn valid_agent_name(name: &str) -> bool {
    (1..=24).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Legacy installations may read the event from JSON. Codex requires argv so
/// even unreadable stdin has the correct neutral Stop/SubagentStop output.
fn parse_args(args: &[String]) -> Option<Args> {
    let (tag, event) = match args {
        [] => (None, ""),
        [flag] if flag == "--agent" => (Some(""), ""),
        [event] if !event.starts_with('-') => (None, event.as_str()),
        [flag, agent] if flag == "--agent" && agent != "codex" => (Some(agent.as_str()), ""),
        [flag, agent, event] if flag == "--agent" && !event.starts_with('-') && !event.is_empty() => {
            (Some(agent.as_str()), event.as_str())
        }
        _ => return None,
    };
    Some(Args { agent: agent_from_tag(tag), event: event.into(), agent_tag: tag.map(str::to_string) })
}

fn main() {
    let Some(args) = parse_args(&std::env::args().skip(1).collect::<Vec<_>>()) else {
        std::process::exit(0);
    };
    let mut event = args.event.clone();
    let mut agent = args.agent;
    let started = Instant::now();
    let worker_args = args.clone();
    // Connect first: a closed app should not wait for stdin to reach EOF. The
    // worker owns all blocking calls, including stdin, under the main deadline.
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let prepared = (|| {
            let pipe = connect()?;
            let raw = read_bounded(std::io::stdin(), MAX_PAYLOAD)?;
            let cwd = std::env::current_dir().ok().map(|p| p.to_string_lossy().into_owned());
            let (payload, event, agent) = prepare_event(&raw, &worker_args, cwd.as_deref())?;
            Some((pipe, payload, event, agent))
        })();
        let _ = tx.send(prepared);
    });
    let mut decision = None;
    if let Ok(Some((pipe, payload, received_event, received_agent))) = rx.recv_timeout(PREPARE_BUDGET) {
        event = received_event;
        agent = received_agent;
        let waits_for_answer = waits_for_approval(agent, &event);
        let total_budget = if waits_for_answer { DECISION_BUDGET } else { FIRE_AND_FORGET_BUDGET };
        let budget = total_budget.saturating_sub(started.elapsed());
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(talk(pipe, &payload, waits_for_answer));
        });
        decision = rx.recv_timeout(budget).ok().flatten();
    }
    if let Some(json) = output_json(agent, &event, decision.as_deref()) {
        let mut out = std::io::stdout();
        let _ = writeln!(out, "{json}");
        let _ = out.flush();
    }
    // Exit also cancels any worker whose stdin/pipe operation hit our deadline.
    std::process::exit(0);
}

/// Read at most limit + 1 bytes, including for an endless stdin stream.
fn read_bounded(reader: impl Read, limit: usize) -> Option<Vec<u8>> {
    let mut raw = Vec::new();
    reader.take((limit + 1) as u64).read_to_end(&mut raw).ok()?;
    (raw.len() <= limit).then_some(raw)
}

fn output_json(agent: Agent, event: &str, decision: Option<&str>) -> Option<String> {
    if waits_for_approval(agent, event) { return decision.and_then(decision_json); }
    // Never request continuation, block completion, or inject model context.
    if agent == Agent::Codex && matches!(event, "Stop" | "SubagentStop") {
        return Some("{}".into());
    }
    None
}

fn waits_for_approval(agent: Agent, event: &str) -> bool {
    agent != Agent::External && event == "PermissionRequest"
}

/// Shared schema: https://learn.chatgpt.com/docs/hooks#permissionrequest
fn decision_json(decision: &str) -> Option<String> {
    let behavior = match decision.trim() {
        // Remembering a choice is never delegated to the agent's permissions.
        "allow" | "always" => r#"{"behavior":"allow"}"#,
        "deny" => r#"{"behavior":"deny","message":"Denied from Coucou"}"#,
        _ => return None,
    };
    Some(format!(r#"{{"hookSpecificOutput":{{"hookEventName":"PermissionRequest","decision":{behavior}}}}}"#))
}

/// Codex uses a fresh allowlist. Ordinary activity never forwards prompts,
/// messages, tool arguments/results or transcript locations.
fn prepare_event(raw: &[u8], args: &Args, fallback_cwd: Option<&str>) -> Option<(String, String, Agent)> {
    if raw.len() > MAX_PAYLOAD { return None; }
    let raw = raw.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(raw);
    let payload: Value = serde_json::from_slice(raw).ok()?;
    let source = payload.as_object()?;
    // Match upstream's metadata protocol. Explicit argv always overrides stdin;
    // absent or invalid tags retain the established Claude fallback behavior.
    let tag = args.agent_tag.as_deref().or_else(|| source.get("coucou_agent").and_then(Value::as_str));
    let agent = agent_from_tag(tag);
    let input_event = source.get("hook_event_name").and_then(Value::as_str).filter(|s| !s.is_empty());
    // Do not let mismatching Codex argv/JSON turn an observation into approval.
    // Keep legacy Claude JSON-event precedence for existing installations.
    if agent == Agent::Codex && !args.event.is_empty() && input_event.is_some_and(|e| e != args.event) { return None; }
    let event = input_event.unwrap_or(&args.event).to_string();
    if event.is_empty() { return None; }
    let mut map = if agent == Agent::Codex {
        let mut safe = Map::new();
        for field in ["session_id", "turn_id", "cwd", "tool_name", "tool_use_id", "agent_id", "agent_type"] {
            if let Some(Value::String(value)) = source.get(field) {
                safe.insert(field.into(), Value::String(value.clone()));
            }
        }
        if safe.get("session_id").and_then(Value::as_str).is_none_or(str::is_empty) { return None; }
        if event == "PermissionRequest" {
            let input = source.get("tool_input").filter(|input| !input.is_null())?;
            if safe.get("tool_name").and_then(Value::as_str).is_none_or(str::is_empty) { return None; }
            // Includes the full command/patch/MCP arguments and optional
            // tool_input.description. These must remain exact for approval.
            safe.insert("tool_input".into(), input.clone());
            // Preserve the source JSON as well: parsing numeric MCP arguments
            // into Value or JavaScript numbers can round their exact value.
            // The approval view renders this string verbatim, without parsing.
            let raw_fields: std::collections::BTreeMap<String, &serde_json::value::RawValue> =
                serde_json::from_slice(raw).ok()?;
            let raw_input = raw_fields.get("tool_input")?.get();
            safe.insert("coucou_tool_input_json".into(), Value::String(raw_input.into()));
            if let Some(Value::String(mode)) = source.get("permission_mode") {
                safe.insert("permission_mode".into(), Value::String(mode.clone()));
            }
        }
        safe.insert("coucou_agent".into(), Value::String("codex".into()));
        safe
    } else {
        let mut legacy = source.clone();
        for field in DROPPED_FIELDS { legacy.remove(*field); }
        legacy.remove("coucou_agent");
        if agent == Agent::External {
            legacy.insert("coucou_agent".into(), Value::String(tag?.into()));
        }
        legacy
    };
    map.insert("hook_event_name".into(), Value::String(event.clone()));
    if map.get("cwd").and_then(Value::as_str).is_none_or(str::is_empty) {
        if let Some(cwd) = fallback_cwd { map.insert("cwd".into(), Value::String(cwd.into())); }
    }
    if agent != Agent::Codex {
        for (key, var) in [
            ("term_program", "TERM_PROGRAM"), ("wt_session", "WT_SESSION"),
            ("term_session_id", "TERM_SESSION_ID"), ("vscode_pid", "VSCODE_PID"),
            ("session_pid", "CLAUDE_CODE_SSE_PORT"),
        ] {
            map.entry(key).or_insert_with(|| Value::String(std::env::var(var).unwrap_or_default()));
        }
    }
    let mut payload = Value::Object(map);
    // Keep legacy activity display limits. Never truncate an approval command,
    // patch or arbitrary tool argument: reject oversized frames altogether.
    if agent != Agent::Codex && (event != "PermissionRequest" || agent == Agent::External) {
        truncate_strings(&mut payload);
    }
    let mut line = payload.to_string();
    line.push('\n');
    (line.len() <= MAX_PAYLOAD).then_some((line, event, agent))
}

fn truncate_strings(value: &mut Value) {
    match value {
        Value::String(s) => {
            if s.len() > MAX_FIELD_LEN {
                let mut end = MAX_FIELD_LEN;
                while end > 0 && !s.is_char_boundary(end) { end -= 1; }
                s.truncate(end);
                s.push('…');
            }
        }
        Value::Array(items) => items.iter_mut().for_each(truncate_strings),
        Value::Object(map) => map.values_mut().for_each(truncate_strings),
        _ => {}
    }
}

fn talk(mut pipe: impl Read + Write, payload: &str, waits_for_answer: bool) -> Option<String> {
    pipe.write_all(payload.as_bytes()).ok()?;
    let _ = pipe.flush();
    if !waits_for_answer { return None; }
    let mut buf = Vec::new();
    let mut chunk = [0u8; MAX_REPLY + 1];
    loop {
        match pipe.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() > MAX_REPLY { return None; }
                if buf.contains(&b'\n') { break; }
            }
            Err(_) => return None,
        }
    }
    let answer = std::str::from_utf8(&buf).ok()?.trim().to_string();
    (!answer.is_empty()).then_some(answer)
}
