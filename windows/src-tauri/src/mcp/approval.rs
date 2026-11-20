// Approval of MCP tool calls from the island (Windows and Linux).
//
// A tool that is not read-only runs only after an Allow on the island's
// permission card, clicked before the request's deadline (gate.rs). The card is
// the one Claude Code's requests use: the request goes to the island as a
// `PermissionRequest` from agent `mcp`, kind `mcp_tool`, with an id `mcp-N`
// that pipe.rs hands back here. It waits in the same line as every other
// request and takes the card in turn.
//
// Everything else is a refusal: no window to show the card on (the phone's
// chat), a paused island, a full line, no ack within ACK_TIMEOUT, Deny, no
// click before the deadline, or an Allow that arrives after it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::mpsc;
use tokio::time::{Duration, Instant};

use super::gate::{self, Reply};
use super::models::MCPTool;
use crate::island::WINDOW_LABEL;
use crate::log;

/// Ids of MCP approval requests start with this; the relay's never do.
pub const PREFIX: &str = "mcp-";
/// The agent tag and card kind the island knows MCP requests by (agents.ts).
pub const AGENT: &str = "mcp";
pub const KIND: &str = "mcp_tool";
/// The island's pill is per session; every MCP request shares this one.
const SESSION: &str = "mcp";

/// Same as the relay's requests (pipe.rs): the island has 800 ms to say the
/// card is up, and drops a card it still shows after 110 s.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// What of the arguments the card shows.
const MAX_SHOWN_ARGS: usize = 300;

/// MCP approval requests the island has been told about.
#[derive(Default)]
pub struct Approvals(Mutex<HashMap<String, mpsc::Sender<Reply>>>);

static COUNTER: AtomicU64 = AtomicU64::new(1);

pub fn is_mcp(request_id: &str) -> bool {
    request_id.starts_with(PREFIX)
}

/// Whether `tool` may run with `arguments`. Read-only tools always may; any
/// other needs an Allow on the island, so with no island (`app` is None) the
/// answer is no.
pub async fn allowed(app: Option<&AppHandle>, tool: &MCPTool, arguments: &HashMap<String, Value>) -> bool {
    if tool.is_read_only {
        return true;
    }
    let Some(app) = app else {
        log::line(format!("mcp tool {} refused: no window to ask on", tool.id));
        return false;
    };
    let Some(approvals) = app.try_state::<Approvals>() else {
        log::line(format!("mcp tool {} refused: approvals not ready", tool.id));
        return false;
    };

    let id = format!("{PREFIX}{}", COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    approvals.0.lock().unwrap().insert(id.clone(), tx);
    log::line(format!("mcp approval id={id} tool={}", tool.id));
    let _ = app.emit_to(WINDOW_LABEL, "hook", request_payload(&id, tool, arguments));

    let allow = gate::wait(&mut rx, ACK_TIMEOUT, DECISION_TIMEOUT).await;
    approvals.0.lock().unwrap().remove(&id);
    log::line(format!("mcp approval id={id} {}", if allow { "allowed" } else { "refused" }));
    // A card still up (or still in line) for this request would be lying.
    let _ = app.emit_to(WINDOW_LABEL, "approval-expired", &id);
    allow
}

/// The MCP pill goes once the turn's tool calls are done.
pub fn finish(app: Option<&AppHandle>) {
    if let Some(app) = app {
        let _ = app.emit_to(
            WINDOW_LABEL,
            "hook",
            json!({ "hook_event_name": "SessionEnd", "coucou_agent": AGENT, "session_id": SESSION }),
        );
    }
}

/// The request as the island's hook handler reads a permission request.
fn request_payload(id: &str, tool: &MCPTool, arguments: &HashMap<String, Value>) -> Value {
    json!({
        "hook_event_name": "PermissionRequest",
        "request_id": id,
        "coucou_agent": AGENT,
        "coucou_kind": KIND,
        "session_id": SESSION,
        "tool_name": format!("{}: {}", tool.server_name, tool.name),
        "tool_input": { "command": shown_arguments(arguments) },
    })
}

/// The arguments on one line, keys sorted, cut to what the card can show.
fn shown_arguments(arguments: &HashMap<String, Value>) -> String {
    let sorted: std::collections::BTreeMap<_, _> = arguments.iter().collect();
    let text = serde_json::to_string(&sorted).unwrap_or_default();
    if text.chars().count() <= MAX_SHOWN_ARGS {
        return text;
    }
    let cut: String = text.chars().take(MAX_SHOWN_ARGS).collect();
    format!("{cut}…")
}

fn send(app: &AppHandle, request_id: &str, reply: Reply, keep: bool) {
    let Some(approvals) = app.try_state::<Approvals>() else { return };
    let sender = {
        let mut map = approvals.0.lock().unwrap();
        if keep { map.get(request_id).cloned() } else { map.remove(request_id) }
    };
    match sender {
        Some(tx) => {
            let _ = tx.try_send(reply);
        }
        None => log::line(format!("reply for id={request_id} — no pending mcp request")),
    }
}

/// The island has the card on screen.
pub fn acknowledge(app: &AppHandle, request_id: &str) {
    send(app, request_id, Reply::Ack, true);
}

/// Nobody can act on it: a refusal.
pub fn decline(app: &AppHandle, request_id: &str) {
    send(app, request_id, Reply::Decline, false);
}

/// A click on the card. Stamped now, so an Allow that comes in after the
/// deadline is refused even if it is read in time.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let allow = matches!(decision, "allow" | "always");
    log::line(format!("decision id={request_id} {}", if allow { "allow" } else { "deny" }));
    send(app, request_id, Reply::Answer { allow, at: Instant::now() }, false);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(read_only: bool) -> MCPTool {
        MCPTool {
            id: "srv__create_issue".into(),
            name: "create_issue".into(),
            server_id: "srv".into(),
            server_name: "GitHub".into(),
            description: String::new(),
            input_schema: json!({}),
            is_read_only: read_only,
        }
    }

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn a_mutating_tool_with_no_window_is_refused() {
        assert!(!block_on(allowed(None, &tool(false), &HashMap::new())));
    }

    #[test]
    fn a_read_only_tool_runs_without_a_card() {
        assert!(block_on(allowed(None, &tool(true), &HashMap::new())));
    }

    #[test]
    fn mcp_ids_never_look_like_relay_ids() {
        assert!(is_mcp("mcp-1"));
        assert!(!is_mcp("1234-1"));
    }

    #[test]
    fn the_card_shows_the_server_tool_and_sorted_arguments() {
        let mut args = HashMap::new();
        args.insert("title".to_string(), json!("Bug"));
        args.insert("body".to_string(), json!("x"));
        let p = request_payload("mcp-7", &tool(false), &args);
        assert_eq!(p["hook_event_name"], "PermissionRequest");
        assert_eq!(p["request_id"], "mcp-7");
        assert_eq!(p["coucou_agent"], AGENT);
        assert_eq!(p["coucou_kind"], KIND);
        assert_eq!(p["tool_name"], "GitHub: create_issue");
        assert_eq!(p["tool_input"]["command"], r#"{"body":"x","title":"Bug"}"#);
    }

    #[test]
    fn long_arguments_are_cut() {
        let mut args = HashMap::new();
        args.insert("text".to_string(), json!("é".repeat(1000)));
        let shown = shown_arguments(&args);
        assert_eq!(shown.chars().count(), MAX_SHOWN_ARGS + 1);
        assert!(shown.ends_with('…'));
    }
}
