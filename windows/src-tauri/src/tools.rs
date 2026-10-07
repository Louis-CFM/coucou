// Chat tools: the island chat can start agent tasks (`start_task`), look at
// the sessions Coucou is showing (`list_sessions`) and hand a web task to the
// background robot in the hidden browser (`robot_task`, see robot.rs).
//
// Both chat providers share this module. The provider-specific parts are the
// tool schema shape and how tool calls come back:
//   - Anthropic: custom tools next to the server-side web_search; calls arrive
//     as `tool_use` content blocks.
//   - OpenAI-compatible (9router): `tools` of type "function"; calls arrive in
//     `choices[0].message.tool_calls` with JSON-string arguments.
// The chat history is stored in Anthropic's block shape either way, so a
// conversation can switch provider between turns.
//
// `start_task` runs with no confirmation (the user asked for that), through
// the same `launch::execute` path as the "+ Task" form: same validation, same
// typing gate, same log line. Tool results carry status text only: never the
// prompt, never a key.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::claude::{Chat, ChatReply};
use crate::launch::{LaunchOutcome, LaunchRequest};

/// Tool calls executed per user message; more are answered "skipped".
pub const MAX_CALLS: usize = 3;
/// Model requests per user message. The last one may not call tools.
pub const MAX_ROUNDS: usize = 4;

const MAX_SESSIONS: usize = 20;
const MAX_FIELD: usize = 60;

pub const AGENTS: [&str; 4] = ["claude", "codex", "kimi-code", "hermes"];
pub const TARGETS: [&str; 2] = ["cli", "desktop"];

pub const START_TASK: &str = "start_task";
pub const LIST_SESSIONS: &str = "list_sessions";
pub const ROBOT_TASK: &str = "robot_task";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolAccess { All, ReadOnly }

impl ToolAccess {
    pub fn for_memory_context(memory_context: Option<&str>) -> Self {
        if memory_context.is_some_and(|value| !value.trim().is_empty()) { Self::ReadOnly } else { Self::All }
    }
    fn allows_side_effects(self) -> bool { self == Self::All }
}

/// Appended to the system prompt of both providers.
pub const GUIDANCE: &str = "\n\nYou can start coding-agent tasks on this PC with the start_task tool \
(agents: claude = Claude Code, codex = Codex, kimi-code = Kimi Code, hermes = Hermes). \
When the user asks to start, open, run or launch a task in one of them, call start_task right away; it runs without confirmation. \
Infer the agent, folder and prompt from the message. Pass the folder exactly as the user gave it; omit it to reuse the folder last used with that agent and target; never invent a folder path. \
Omit target unless the user says terminal/CLI or desktop/app. \
Ask one short question only if the agent is genuinely ambiguous. \
If start_task returns an error, tell the user plainly what went wrong. \
list_sessions shows the agent sessions currently running. \
For anything to do on a website as the user (Telegram Web, Gemini, Gmail, downloads, forms), call robot_task: \
a background robot does it in a hidden, logged-in browser without touching the user's screen. \
Pass the task in the user's words, with every exact text, name and recipient. \
It returns at once; Coucou shows the result, and asks the user before anything is sent, posted, paid or deleted \
unless that exact action is pre-approved. Do not ask for confirmation yourself. If it says busy, tell the user.";

#[derive(Debug, Clone, Default)]
pub struct ToolDefaults {
    pub last_folder: String,
    pub last_targets: BTreeMap<String, String>,
    /// Folder saved per "agent/target" (settings `task_profiles`).
    pub folders: BTreeMap<String, String>,
}

impl ToolDefaults {
    pub fn from_settings(s: &crate::settings::Settings) -> Self {
        let folders = s
            .task_profiles
            .iter()
            .filter(|(_, p)| !p.folder.trim().is_empty())
            .map(|(k, p)| (k.clone(), p.folder.trim().to_string()))
            .collect();
        ToolDefaults { last_folder: s.last_task_folder.clone(), last_targets: s.last_task_targets.clone(), folders }
    }

    /// Same rule as the "+ Task" card: this agent and target's own folder,
    /// else the last folder used by any launch.
    pub fn folder_for(&self, agent: &str, target: &str) -> Option<String> {
        self.folders
            .get(&crate::settings::task_profile_key(agent, target))
            .map(|f| f.trim())
            .filter(|f| !f.is_empty())
            .or_else(|| Some(self.last_folder.trim()).filter(|f| !f.is_empty()))
            .map(str::to_string)
    }
}

/// One island session as the front end sees it. No prompts, no tool inputs.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct SessionInfo {
    pub agent: String,
    pub project: String,
    pub status: String,
}

fn clean_field(s: &str) -> String {
    let flat: String = s.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    flat.trim().chars().take(MAX_FIELD).collect()
}

pub fn sanitize_sessions(raw: Vec<SessionInfo>) -> Vec<SessionInfo> {
    raw.into_iter()
        .take(MAX_SESSIONS)
        .map(|s| SessionInfo {
            agent: clean_field(&s.agent),
            project: clean_field(&s.project),
            status: clean_field(&s.status),
        })
        .collect()
}

// ── Schemas ──────────────────────────────────────────────────────────────────

const START_DESC: &str = "Start a new task in a coding agent (Claude Code, Codex, Kimi Code or Hermes) \
in a project folder. It launches immediately in the agent's own default permission mode. \
Returns whether it started, or why not.";
const LIST_DESC: &str = "List the agent sessions Coucou currently shows: agent, project folder name, status. Read-only.";
const ROBOT_DESC: &str = "Run a task in a hidden, logged-in web browser on this PC (Telegram Web, Gemini and other sites), \
done by a background agent that never touches the user's mouse, keyboard or windows. Starts the task and returns at once; \
one robot task at a time. Sends, posts, payments and deletions wait for the user's Allow unless pre-approved.";

fn robot_task_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "task": { "type": "string", "description": "What to do, in the user's words, with every exact message text, group or file name." }
        },
        "required": ["task"]
    })
}

pub fn start_task_schema(d: &ToolDefaults) -> Value {
    let folder = if d.last_folder.trim().is_empty() && d.folders.is_empty() {
        "Absolute path of the project folder. Required: no folder has been used yet.".to_string()
    } else if d.last_folder.trim().is_empty() {
        "Absolute path of the project folder. Omit to reuse the folder last used with that agent and target.".to_string()
    } else {
        format!(
            "Absolute path of the project folder. Omit to reuse the folder last used with that agent and target, else the last folder: {}",
            d.last_folder
        )
    };
    json!({
        "type": "object",
        "properties": {
            "agent": {
                "type": "string",
                "enum": AGENTS,
                "description": "The coding agent that runs the task."
            },
            "target": {
                "type": "string",
                "enum": TARGETS,
                "description": "cli = new terminal, desktop = the agent's desktop app. Omit unless the user said; defaults to the one last used with this agent, else cli."
            },
            "folder": { "type": "string", "description": folder },
            "prompt": { "type": "string", "description": "The task for the agent, in the user's words." }
        },
        "required": ["agent", "prompt"]
    })
}

fn list_sessions_schema() -> Value {
    json!({ "type": "object", "properties": {} })
}

pub fn anthropic_tools(d: &ToolDefaults, access: ToolAccess) -> Vec<Value> {
    let mut tools = Vec::new();
    if access.allows_side_effects() {
        tools.push(json!({ "name": START_TASK, "description": START_DESC, "input_schema": start_task_schema(d) }));
    }
    tools.push(json!({ "name": LIST_SESSIONS, "description": LIST_DESC, "input_schema": list_sessions_schema() }));
    if access.allows_side_effects() {
        tools.push(json!({ "name": ROBOT_TASK, "description": ROBOT_DESC, "input_schema": robot_task_schema() }));
    }
    tools
}

pub fn openai_tools(d: &ToolDefaults, access: ToolAccess) -> Vec<Value> {
    let mut tools = Vec::new();
    if access.allows_side_effects() {
        tools.push(json!({ "type": "function", "function": {
            "name": START_TASK, "description": START_DESC, "parameters": start_task_schema(d) } }));
    }
    tools.push(json!({ "type": "function", "function": {
        "name": LIST_SESSIONS, "description": LIST_DESC, "parameters": list_sessions_schema() } }));
    if access.allows_side_effects() {
        tools.push(json!({ "type": "function", "function": {
            "name": ROBOT_TASK, "description": ROBOT_DESC, "parameters": robot_task_schema() } }));
    }
    tools
}

// ── Parsing tool calls ───────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    /// `Value::Null` when the arguments could not be read.
    pub input: Value,
}

/// Ids go back to both APIs; Anthropic only accepts `[A-Za-z0-9_-]`.
fn safe_id(raw: Option<&str>, n: usize) -> String {
    let id: String = raw
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(64)
        .collect();
    if id.is_empty() {
        format!("call_{n}")
    } else {
        id
    }
}

/// `tool_use` blocks of an Anthropic reply. Server tools (web_search) come as
/// `server_tool_use` and are not ours to run.
pub fn parse_anthropic_calls(blocks: &[Value]) -> Vec<ToolCall> {
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_use"))
        .enumerate()
        .map(|(n, b)| ToolCall {
            id: safe_id(b.get("id").and_then(Value::as_str), n),
            name: b.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
            input: b.get("input").cloned().unwrap_or(Value::Null),
        })
        .collect()
}

/// `message.tool_calls` of an OpenAI-compatible reply. Arguments are a JSON
/// string by spec; some gateways send an object.
pub fn parse_openai_calls(message: &Value) -> Vec<ToolCall> {
    let Some(calls) = message.get("tool_calls").and_then(Value::as_array) else {
        return Vec::new();
    };
    calls
        .iter()
        .enumerate()
        .filter_map(|(n, c)| {
            let f = c.get("function")?;
            let name = f.get("name").and_then(Value::as_str)?.to_string();
            let input = match f.get("arguments") {
                Some(Value::String(s)) if s.trim().is_empty() => json!({}),
                Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(Value::Null),
                Some(v @ Value::Object(_)) => v.clone(),
                None => json!({}),
                _ => Value::Null,
            };
            Some(ToolCall { id: safe_id(c.get("id").and_then(Value::as_str), n), name, input })
        })
        .collect()
}

// ── start_task arguments ─────────────────────────────────────────────────────

fn normalize_agent(raw: &str) -> Option<&'static str> {
    let a = raw.trim().to_ascii_lowercase();
    match a.as_str() {
        "claude" | "claude-code" | "claude code" => Some("claude"),
        "codex" => Some("codex"),
        "kimi-code" | "kimi" | "kimi code" => Some("kimi-code"),
        "hermes" => Some("hermes"),
        _ => None,
    }
}

fn opt_str<'a>(input: &'a Value, key: &str) -> Result<Option<&'a str>, String> {
    match input.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.as_str())),
        Some(_) => Err(format!("`{key}` must be a string.")),
    }
}

/// Tool input → launch request, with the defaults filled in. Folder and prompt
/// are validated for real by `launch::execute`.
pub fn resolve_start_task(input: &Value, d: &ToolDefaults) -> Result<LaunchRequest, String> {
    if !input.is_object() {
        return Err("start_task arguments were not a JSON object.".into());
    }
    let agent_raw = opt_str(input, "agent")?.ok_or("`agent` is required (claude, codex, kimi-code or hermes).")?;
    let agent = normalize_agent(agent_raw)
        .ok_or_else(|| format!("Unknown agent `{}`. Use claude, codex, kimi-code or hermes.", clean_field(agent_raw)))?;
    let target = match opt_str(input, "target")? {
        Some(t) => {
            let t = t.trim().to_ascii_lowercase();
            if !TARGETS.contains(&t.as_str()) {
                return Err(format!("Unknown target `{}`. Use cli or desktop.", clean_field(&t)));
            }
            t
        }
        None => match d.last_targets.get(agent).map(String::as_str) {
            Some("desktop") => "desktop".to_string(),
            _ => "cli".to_string(),
        },
    };
    let folder = match opt_str(input, "folder")? {
        Some(f) => f.trim().to_string(),
        None => d
            .folder_for(agent, &target)
            .ok_or("No folder given and none used before. Ask the user which folder.")?,
    };
    let prompt = opt_str(input, "prompt")?.ok_or("`prompt` is required.")?.to_string();
    Ok(LaunchRequest { agent: agent.to_string(), target, folder, prompt })
}

// ── Results ──────────────────────────────────────────────────────────────────

/// One executed action, for the system line in the chat log.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ChatAction {
    /// "started", "clipboard" (paste needed), "robot" (robot task started) or "error".
    pub kind: &'static str,
    /// Agent id, or "" when it could not be read.
    pub agent: String,
    /// "cli", "desktop" or "".
    pub target: String,
    /// Last component of the folder, not the full path.
    pub folder: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolOutcome {
    pub text: String,
    pub is_error: bool,
    pub action: Option<ChatAction>,
}

pub fn folder_name(path: &str) -> String {
    let trimmed = path.trim().trim_end_matches(['\\', '/']);
    trimmed
        .rsplit(['\\', '/'])
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(trimmed)
        .to_string()
}

pub fn agent_label(id: &str) -> &'static str {
    match id {
        "claude" => "Claude",
        "codex" => "Codex",
        "kimi-code" => "Kimi Code",
        "hermes" => "Hermes",
        _ => "the agent",
    }
}

pub fn start_task_outcome(req: &LaunchRequest, result: Result<LaunchOutcome, String>) -> ToolOutcome {
    let folder = folder_name(&req.folder);
    let label = agent_label(&req.agent);
    match result {
        Ok(o) if o.status == "started" => ToolOutcome {
            text: format!("Started {label} ({}) in folder {}. {}", req.target, req.folder, o.message),
            is_error: false,
            action: Some(ChatAction {
                kind: "started",
                agent: req.agent.clone(),
                target: req.target.clone(),
                folder,
                message: o.message,
            }),
        },
        Ok(o) => ToolOutcome {
            text: format!(
                "Opened {label} ({}) in folder {}, but the prompt could not be typed in automatically: {} Tell the user.",
                req.target, req.folder, o.message
            ),
            is_error: false,
            action: Some(ChatAction {
                kind: "clipboard",
                agent: req.agent.clone(),
                target: req.target.clone(),
                folder,
                message: o.message,
            }),
        },
        Err(err) => ToolOutcome {
            text: format!("Error: {label} was not started. {err}"),
            is_error: true,
            action: Some(ChatAction {
                kind: "error",
                agent: req.agent.clone(),
                target: req.target.clone(),
                folder,
                message: err,
            }),
        },
    }
}

fn invalid_outcome(input: &Value, err: String) -> ToolOutcome {
    let agent = input
        .get("agent")
        .and_then(Value::as_str)
        .and_then(normalize_agent)
        .unwrap_or("")
        .to_string();
    ToolOutcome {
        text: format!("Error: nothing was started. {err}"),
        is_error: true,
        action: Some(ChatAction { kind: "error", agent, target: String::new(), folder: String::new(), message: err }),
    }
}

/// The robot's task text from the tool input.
pub fn resolve_robot_task(input: &Value) -> Result<String, String> {
    if !input.is_object() {
        return Err("robot_task arguments were not a JSON object.".into());
    }
    let task = opt_str(input, "task")?.ok_or("`task` is required.")?;
    crate::robot::validate_task(task)
}

/// `Ok` carries the robot's status line. The task text is never echoed.
pub fn robot_task_outcome(result: Result<String, String>) -> ToolOutcome {
    match result {
        Ok(msg) => ToolOutcome {
            text: format!("Robot task started in the hidden browser. {msg} Coucou will show the result, or ask the user before any send/post/pay/delete."),
            is_error: false,
            action: Some(ChatAction {
                kind: "robot",
                agent: "robot".into(),
                target: String::new(),
                folder: String::new(),
                message: "Robot started in the hidden browser.".into(),
            }),
        },
        Err(err) => ToolOutcome {
            text: format!("Error: the robot task was not started. {err}"),
            is_error: true,
            action: Some(ChatAction { kind: "error", agent: "robot".into(), target: String::new(), folder: String::new(), message: err }),
        },
    }
}

pub fn list_sessions_outcome(sessions: &[SessionInfo]) -> ToolOutcome {
    let text = if sessions.is_empty() {
        "No agent sessions are showing in Coucou right now.".to_string()
    } else {
        sessions
            .iter()
            .map(|s| format!("{} | {} | {}", s.agent, s.project, s.status))
            .collect::<Vec<_>>()
            .join("\n")
    };
    ToolOutcome { text, is_error: false, action: None }
}

/// The sentence used when the model has nothing to add after acting.
pub fn summary(actions: &[ChatAction]) -> String {
    actions
        .iter()
        .map(|a| match a.kind {
            "started" => format!("Started {} ({}) in {}.", agent_label(&a.agent), a.target, a.folder),
            "clipboard" => a.message.clone(),
            "robot" => "The robot is on it in the hidden browser.".to_string(),
            _ if a.agent == "robot" => format!("Could not start the robot: {}", a.message),
            _ => format!("Could not start the task: {}", a.message),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// ── The loop ─────────────────────────────────────────────────────────────────

/// What runs a tool for real: the app (start_task via lib::start_task) or a
/// test double.
pub(crate) trait ToolRunner {
    fn defaults(&self) -> ToolDefaults;
    fn sessions(&self) -> Vec<SessionInfo>;
    async fn start(&mut self, request: LaunchRequest) -> Result<LaunchOutcome, String>;
    /// Starts a robot task; `Ok` is a short status line, `Err` e.g. "busy".
    fn robot(&mut self, task: String) -> Result<String, String>;
}

pub(crate) async fn run_call<R: ToolRunner>(runner: &mut R, call: &ToolCall) -> ToolOutcome {
    run_call_with_access(runner, call, ToolAccess::All).await
}

pub(crate) async fn run_call_with_access<R: ToolRunner>(runner: &mut R, call: &ToolCall, access: ToolAccess) -> ToolOutcome {
    if !access.allows_side_effects() && matches!(call.name.as_str(), START_TASK | ROBOT_TASK) {
        return ToolOutcome {
            text: format!("Error: tool `{}` is unavailable while recalled memory is present.", call.name),
            is_error: true,
            action: None,
        };
    }
    match call.name.as_str() {
        START_TASK => match resolve_start_task(&call.input, &runner.defaults()) {
            Ok(req) => {
                let result = runner.start(req.clone()).await;
                start_task_outcome(&req, result)
            }
            Err(err) => invalid_outcome(&call.input, err),
        },
        LIST_SESSIONS => list_sessions_outcome(&runner.sessions()),
        ROBOT_TASK => match resolve_robot_task(&call.input) {
            Ok(task) => robot_task_outcome(runner.robot(task)),
            Err(err) => robot_task_outcome(Err(err)),
        },
        other => ToolOutcome {
            text: format!("Error: unknown tool `{}`.", clean_field(other)),
            is_error: true,
            action: None,
        },
    }
}

/// One model reply, already in Anthropic block shape for the history.
#[derive(Debug, Clone, Default)]
pub struct Turn {
    pub blocks: Vec<Value>,
    pub text: String,
    pub calls: Vec<ToolCall>,
    /// Shown under the answer, e.g. "this model cannot start tasks".
    pub note: Option<String>,
}

pub(crate) trait Backend {
    /// One model request over the whole history. `allow_tools: false` asks the
    /// model for a final text answer (tool_choice none).
    async fn complete(&mut self, history: Vec<Value>, allow_tools: bool) -> Result<Turn, String>;
}

fn text_message(text: &str) -> Value {
    json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] })
}

fn results_message(results: &[(String, ToolOutcome)]) -> Value {
    let blocks: Vec<Value> = results
        .iter()
        .map(|(id, o)| {
            let mut b = json!({ "type": "tool_result", "tool_use_id": id, "content": o.text });
            if o.is_error {
                b["is_error"] = json!(true);
            }
            b
        })
        .collect();
    json!({ "role": "user", "content": blocks })
}

fn with_notes(text: String, notes: &[String]) -> String {
    let mut out = text;
    for n in notes {
        if !out.is_empty() {
            out.push_str("\n\n");
        }
        out.push_str(n);
    }
    out
}

/// One user message: ask the model, run its tool calls, feed the results
/// back, repeat until it answers in text. At most MAX_ROUNDS requests and
/// MAX_CALLS executed calls. If the request fails before anything ran, the
/// history is rolled back and the error returned; once an action has run, the
/// user gets a reply describing it whatever happens next.
pub(crate) async fn run_turn<B: Backend, R: ToolRunner>(
    chat: &Chat,
    user_message: Value,
    backend: &mut B,
    runner: &mut R,
) -> Result<ChatReply, String> {
    run_turn_with_access(chat, user_message, backend, runner, ToolAccess::All).await
}

pub(crate) async fn run_turn_with_access<B: Backend, R: ToolRunner>(
    chat: &Chat,
    user_message: Value,
    backend: &mut B,
    runner: &mut R,
    access: ToolAccess,
) -> Result<ChatReply, String> {
    let _turn = chat.begin_turn()?;
    let generation = chat.generation();
    let start = chat.len();
    chat.push(generation, user_message);
    let mut actions: Vec<ChatAction> = Vec::new();
    let mut notes: Vec<String> = Vec::new();
    let mut used = 0usize;

    for round in 0..MAX_ROUNDS {
        let allow = round + 1 < MAX_ROUNDS && used < MAX_CALLS;
        let Some(history) = chat.snapshot_at(generation) else { return cleared(actions); };
        let turn = match backend.complete(history, allow).await {
            Ok(t) => t,
            Err(err) if actions.is_empty() => {
                chat.truncate(generation, start);
                return Err(err);
            }
            Err(err) => {
                let text = format!("{}\n(The follow-up reply failed: {err})", summary(&actions));
                chat.push(generation, text_message(&text));
                return Ok(ChatReply { text, actions, memory_status: None, turn_id: None });
            }
        };
        if let Some(n) = turn.note.clone() { notes.push(n); }
        if !chat.push(generation, json!({ "role": "assistant", "content": turn.blocks })) { return cleared(actions); }

        if turn.calls.is_empty() {
            let text = if turn.text.trim().is_empty() { summary(&actions) } else { turn.text.trim().to_string() };
            if text.is_empty() && notes.is_empty() {
                chat.truncate(generation, start);
                return Err("No response text.".into());
            }
            return Ok(ChatReply { text: with_notes(text, &notes), actions, memory_status: None, turn_id: None });
        }

        let mut results = Vec::with_capacity(turn.calls.len());
        for call in &turn.calls {
            let outcome = if !allow || used >= MAX_CALLS {
                ToolOutcome { text: format!("Skipped: at most {MAX_CALLS} actions per message."), is_error: true, action: None }
            } else {
                used += 1;
                run_call_with_access(runner, call, access).await
            };
            if let Some(action) = outcome.action.clone() { actions.push(action); }
            results.push((call.id.clone(), outcome));
        }
        if !chat.push(generation, results_message(&results)) { return cleared(actions); }

        if !allow {
            let mut text = turn.text.trim().to_string();
            if text.is_empty() { text = summary(&actions); }
            if text.is_empty() { text = "I stopped after too many steps.".into(); }
            chat.push(generation, text_message(&text));
            return Ok(ChatReply { text: with_notes(text, &notes), actions, memory_status: None, turn_id: None });
        }
    }
    unreachable!("the last round never allows tools")
}

fn cleared(actions: Vec<ChatAction>) -> Result<ChatReply, String> {
    if actions.is_empty() { return Err(crate::claude::CLEARED.into()); }
    Ok(ChatReply { text: summary(&actions), actions, memory_status: None, turn_id: None })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn defaults() -> ToolDefaults {
        let mut d = ToolDefaults { last_folder: r"C:\work\coucou".into(), ..Default::default() };
        d.last_targets.insert("kimi-code".into(), "desktop".into());
        d
    }

    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(f)
    }

    #[test]
    fn memory_augmented_tool_schemas_are_read_only() {
        let anthropic = anthropic_tools(&defaults(), ToolAccess::ReadOnly);
        let anthropic_names: Vec<_> = anthropic.iter().filter_map(|tool| tool["name"].as_str()).collect();
        assert_eq!(anthropic_names, [LIST_SESSIONS]);
        let openai = openai_tools(&defaults(), ToolAccess::ReadOnly);
        let openai_names: Vec<_> = openai.iter().filter_map(|tool| tool["function"]["name"].as_str()).collect();
        assert_eq!(openai_names, [LIST_SESSIONS]);
    }

    #[test]
    fn memory_augmented_executor_rejects_fabricated_side_effect_calls() {
        let mut runner = FakeRunner::default();
        for call in [
            ToolCall { id: "s".into(), name: START_TASK.into(), input: json!({ "agent": "codex", "folder": "C:\\work", "prompt": "injected" }) },
            ToolCall { id: "r".into(), name: ROBOT_TASK.into(), input: json!({ "task": "injected" }) },
        ] {
            let outcome = block_on(run_call_with_access(&mut runner, &call, ToolAccess::ReadOnly));
            assert!(outcome.is_error);
            assert!(outcome.text.contains("unavailable while recalled memory is present"));
        }
        let read = block_on(run_call_with_access(&mut runner, &ToolCall { id: "l".into(), name: LIST_SESSIONS.into(), input: json!({}) }, ToolAccess::ReadOnly));
        assert!(!read.is_error);
        assert!(runner.started.is_empty() && runner.robot.is_empty());
    }

    #[test]
    fn anthropic_schema_has_both_tools_and_enums() {
        let tools = anthropic_tools(&defaults(), ToolAccess::All);
        assert_eq!(tools.len(), 3);
        assert_eq!(tools[0]["name"], START_TASK);
        let schema = &tools[0]["input_schema"];
        assert_eq!(schema["type"], "object");
        assert_eq!(schema["properties"]["agent"]["enum"], json!(["claude", "codex", "kimi-code", "hermes"]));
        assert_eq!(schema["properties"]["target"]["enum"], json!(["cli", "desktop"]));
        assert_eq!(schema["required"], json!(["agent", "prompt"]));
        assert!(schema["properties"]["folder"]["description"].as_str().unwrap().contains(r"C:\work\coucou"));
        assert_eq!(tools[1]["name"], LIST_SESSIONS);
        assert_eq!(tools[1]["input_schema"]["type"], "object");
        assert!(tools.iter().all(|t| t.get("type").is_none()));
        assert_eq!(tools[2]["name"], ROBOT_TASK);
        assert_eq!(tools[2]["input_schema"]["required"], json!(["task"]));
    }

    #[test]
    fn openai_schema_wraps_functions() {
        let tools = openai_tools(&ToolDefaults::default(), ToolAccess::All);
        assert_eq!(tools.len(), 3);
        assert_eq!(tools[0]["type"], "function");
        assert_eq!(tools[0]["function"]["name"], START_TASK);
        assert_eq!(tools[0]["function"]["parameters"]["required"], json!(["agent", "prompt"]));
        assert!(tools[0]["function"]["parameters"]["properties"]["folder"]["description"]
            .as_str()
            .unwrap()
            .contains("Required"));
        assert_eq!(tools[1]["function"]["name"], LIST_SESSIONS);
        assert_eq!(tools[2]["function"]["name"], ROBOT_TASK);
    }

    #[test]
    fn anthropic_tool_use_blocks_are_parsed() {
        let blocks = vec![
            json!({ "type": "text", "text": "On it." }),
            json!({ "type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": {} }),
            json!({ "type": "tool_use", "id": "toolu_01A", "name": "start_task",
                    "input": { "agent": "codex", "prompt": "fix it" } }),
            json!({ "type": "tool_use", "name": "list_sessions" }),
        ];
        let calls = parse_anthropic_calls(&blocks);
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0], ToolCall {
            id: "toolu_01A".into(),
            name: "start_task".into(),
            input: json!({ "agent": "codex", "prompt": "fix it" }),
        });
        assert_eq!(calls[1].id, "call_1");
        assert_eq!(calls[1].input, Value::Null);
    }

    #[test]
    fn openai_tool_calls_are_parsed_from_json_strings() {
        let message = json!({ "role": "assistant", "content": null, "tool_calls": [
            { "id": "call_abc", "type": "function",
              "function": { "name": "start_task", "arguments": "{\"agent\":\"codex\",\"prompt\":\"hi\"}" } },
            { "id": "call:x y", "type": "function", "function": { "name": "list_sessions", "arguments": "" } },
            { "type": "function", "function": { "name": "start_task", "arguments": { "agent": "hermes" } } },
            { "id": "bad", "type": "function", "function": { "name": "start_task", "arguments": "{not json" } },
            { "id": "noname", "type": "function", "function": {} }
        ] });
        let calls = parse_openai_calls(&message);
        assert_eq!(calls.len(), 4);
        assert_eq!(calls[0].input, json!({ "agent": "codex", "prompt": "hi" }));
        assert_eq!(calls[1].id, "callxy");
        assert_eq!(calls[1].input, json!({}));
        assert_eq!(calls[2].id, "call_2");
        assert_eq!(calls[2].input, json!({ "agent": "hermes" }));
        assert_eq!(calls[3].input, Value::Null);
        assert!(parse_openai_calls(&json!({ "content": "hi" })).is_empty());
    }

    #[test]
    fn start_task_arguments_get_defaults() {
        let d = defaults();
        let r = resolve_start_task(&json!({ "agent": "codex", "prompt": "do x" }), &d).unwrap();
        assert_eq!((r.agent.as_str(), r.target.as_str(), r.folder.as_str(), r.prompt.as_str()),
                   ("codex", "cli", r"C:\work\coucou", "do x"));
        let r = resolve_start_task(&json!({ "agent": "Kimi", "prompt": "p", "target": null, "folder": "" }), &d).unwrap();
        assert_eq!((r.agent.as_str(), r.target.as_str()), ("kimi-code", "desktop"));
        let r = resolve_start_task(&json!({ "agent": "hermes", "target": "Desktop", "folder": r"D:\x", "prompt": "p" }), &d).unwrap();
        assert_eq!((r.target.as_str(), r.folder.as_str()), ("desktop", r"D:\x"));
    }

    #[test]
    fn start_task_folder_comes_from_the_agent_and_target_profile() {
        let mut s = crate::settings::Settings::default();
        s.remember_task("codex", "cli", r"C:\codex-cli");
        s.remember_task("kimi-code", "desktop", r"C:\kimi-app");
        s.remember_task("claude", "desktop", r"C:\claude-app");
        let d = ToolDefaults::from_settings(&s);
        let folder = |v: Value| resolve_start_task(&v, &d).unwrap().folder;
        assert_eq!(folder(json!({ "agent": "codex", "prompt": "p" })), r"C:\codex-cli");
        // kimi-code's remembered target is desktop, so its desktop folder.
        assert_eq!(folder(json!({ "agent": "kimi", "prompt": "p" })), r"C:\kimi-app");
        assert_eq!(folder(json!({ "agent": "claude", "prompt": "p" })), r"C:\claude-app");
        // No profile for hermes/cli: the last folder used anywhere.
        assert_eq!(folder(json!({ "agent": "hermes", "prompt": "p" })), r"C:\claude-app");
        assert_eq!(folder(json!({ "agent": "codex", "prompt": "p", "folder": r"D:\given" })), r"D:\given");
    }

    #[test]
    fn start_task_arguments_are_validated() {
        let d = defaults();
        let err = |v: Value, d: &ToolDefaults| resolve_start_task(&v, d).unwrap_err();
        assert!(err(Value::Null, &d).contains("JSON object"));
        assert!(err(json!({ "prompt": "p" }), &d).contains("`agent` is required"));
        assert!(err(json!({ "agent": "gpt", "prompt": "p" }), &d).contains("Unknown agent"));
        assert!(err(json!({ "agent": "codex", "target": "web", "prompt": "p" }), &d).contains("Unknown target"));
        assert!(err(json!({ "agent": "codex" }), &d).contains("`prompt` is required"));
        assert!(err(json!({ "agent": "codex", "prompt": 3 }), &d).contains("must be a string"));
        assert!(err(json!({ "agent": "codex", "prompt": "p" }), &ToolDefaults::default()).contains("Ask the user"));
    }

    #[test]
    fn outcomes_never_echo_the_prompt() {
        let req = LaunchRequest {
            agent: "codex".into(), target: "cli".into(),
            folder: r"C:\work\coucou\".into(), prompt: "SECRET-PROMPT".into(),
        };
        let ok = start_task_outcome(&req, Ok(LaunchOutcome { status: "started", message: "Started codex in a new terminal.".into() }));
        assert!(!ok.is_error && !ok.text.contains("SECRET"));
        assert_eq!(ok.action.as_ref().unwrap().folder, "coucou");
        assert_eq!(ok.action.as_ref().unwrap().kind, "started");
        let paste = start_task_outcome(&req, Ok(LaunchOutcome { status: "clipboard", message: "Press Ctrl+V".into() }));
        assert_eq!(paste.action.unwrap().kind, "clipboard");
        let bad = start_task_outcome(&req, Err("Folder not found: C:\\nope".into()));
        assert!(bad.is_error && bad.text.starts_with("Error:"));
        assert_eq!(bad.action.unwrap().kind, "error");
        assert_eq!(folder_name("C:/a/b/"), "b");
        assert_eq!(folder_name(r"C:\"), "C:");
    }

    #[test]
    fn sessions_are_sanitized_and_listed() {
        let raw: Vec<SessionInfo> = (0..30)
            .map(|i| SessionInfo { agent: "codex".into(), project: format!("p{i}\n{}", "x".repeat(100)), status: "working".into() })
            .collect();
        let clean = sanitize_sessions(raw);
        assert_eq!(clean.len(), MAX_SESSIONS);
        assert!(!clean[0].project.contains('\n') && clean[0].project.chars().count() <= MAX_FIELD);
        assert!(list_sessions_outcome(&clean[..1]).text.starts_with("codex | p0"));
        assert!(list_sessions_outcome(&[]).text.contains("No agent sessions"));
    }

    // ── Mocked loop ──────────────────────────────────────────────────────────

    struct FakeBackend {
        replies: Vec<Turn>,
        seen: Vec<(usize, bool)>,
        fail_at: Option<usize>,
    }

    impl Backend for FakeBackend {
        async fn complete(&mut self, history: Vec<Value>, allow_tools: bool) -> Result<Turn, String> {
            let n = self.seen.len();
            self.seen.push((history.len(), allow_tools));
            if self.fail_at == Some(n) {
                return Err("boom".into());
            }
            Ok(if self.replies.is_empty() { call_turn(n) } else { self.replies.remove(0) })
        }
    }

    fn call_turn(n: usize) -> Turn {
        let input = json!({ "agent": "codex", "prompt": "p", "folder": r"C:\w\proj" });
        Turn {
            blocks: vec![json!({ "type": "tool_use", "id": format!("t{n}"), "name": "start_task", "input": input })],
            text: String::new(),
            calls: vec![ToolCall { id: format!("t{n}"), name: "start_task".into(), input }],
            note: None,
        }
    }

    fn text_turn(t: &str) -> Turn {
        Turn { blocks: vec![json!({ "type": "text", "text": t })], text: t.into(), calls: vec![], note: None }
    }

    #[derive(Default)]
    struct FakeRunner {
        started: Vec<LaunchRequest>,
        robot: Vec<String>,
        robot_busy: bool,
    }

    impl ToolRunner for FakeRunner {
        fn defaults(&self) -> ToolDefaults {
            ToolDefaults::default()
        }
        fn sessions(&self) -> Vec<SessionInfo> {
            vec![SessionInfo { agent: "claude".into(), project: "coucou".into(), status: "working".into() }]
        }
        async fn start(&mut self, request: LaunchRequest) -> Result<LaunchOutcome, String> {
            self.started.push(request);
            Ok(LaunchOutcome { status: "started", message: "Started codex in a new terminal.".into() })
        }
        fn robot(&mut self, task: String) -> Result<String, String> {
            if self.robot_busy {
                return Err("The robot is busy with another task.".into());
            }
            self.robot.push(task);
            Ok("Checking the hidden browser.".into())
        }
    }

    fn user(t: &str) -> Value {
        json!({ "role": "user", "content": [{ "type": "text", "text": t }] })
    }

    /// Every tool_use in the history is answered by a tool_result right after.
    fn well_formed(history: &[Value]) -> bool {
        history.iter().enumerate().all(|(i, m)| {
            let ids: Vec<String> = parse_anthropic_calls(m["content"].as_array().map(Vec::as_slice).unwrap_or(&[]))
                .into_iter().map(|c| c.id).collect();
            ids.is_empty() || history.get(i + 1).is_some_and(|next| {
                ids.iter().all(|id| next["content"].as_array().unwrap().iter().any(|b| b["tool_use_id"] == json!(id)))
            })
        })
    }

    #[test]
    fn loop_runs_a_call_then_answers() {
        let chat = Chat::default();
        let mut backend = FakeBackend { replies: vec![call_turn(0), text_turn("Codex is on it.")], seen: vec![], fail_at: None };
        let mut runner = FakeRunner::default();
        let reply = block_on(run_turn(&chat, user("start codex"), &mut backend, &mut runner)).unwrap();
        assert_eq!(reply.text, "Codex is on it.");
        assert_eq!(reply.actions.len(), 1);
        assert_eq!(reply.actions[0].folder, "proj");
        assert_eq!(runner.started.len(), 1);
        assert_eq!(backend.seen, vec![(1, true), (3, true)]);
        let h = chat.snapshot();
        assert_eq!(h.len(), 4);
        assert_eq!(h[2]["content"][0]["type"], "tool_result");
        assert!(well_formed(&h));
    }

    #[test]
    fn loop_stops_at_three_calls_and_four_rounds() {
        let chat = Chat::default();
        // The model never stops calling tools.
        let mut backend = FakeBackend { replies: vec![], seen: vec![], fail_at: None };
        let mut runner = FakeRunner::default();
        let reply = block_on(run_turn(&chat, user("go"), &mut backend, &mut runner)).unwrap();
        assert_eq!(runner.started.len(), MAX_CALLS);
        assert_eq!(backend.seen.len(), MAX_ROUNDS);
        assert_eq!(backend.seen.iter().map(|s| s.1).collect::<Vec<_>>(), vec![true, true, true, false]);
        assert_eq!(reply.actions.len(), MAX_CALLS);
        assert!(reply.text.contains("Started Codex"));
        assert!(well_formed(&chat.snapshot()));
        assert_eq!(chat.snapshot().last().unwrap()["role"], "assistant");
    }

    #[test]
    fn loop_caps_parallel_calls_in_one_reply() {
        let chat = Chat::default();
        let mut many = call_turn(0);
        for n in 1..5 {
            let c = call_turn(n);
            many.blocks.extend(c.blocks);
            many.calls.extend(c.calls);
        }
        let mut backend = FakeBackend { replies: vec![many, text_turn("done")], seen: vec![], fail_at: None };
        let mut runner = FakeRunner::default();
        let reply = block_on(run_turn(&chat, user("go"), &mut backend, &mut runner)).unwrap();
        assert_eq!(runner.started.len(), 3);
        assert_eq!(backend.seen[1], (3, false));
        assert_eq!(reply.text, "done");
        let results = &chat.snapshot()[2]["content"];
        assert_eq!(results.as_array().unwrap().len(), 5);
        assert!(results[4]["content"].as_str().unwrap().starts_with("Skipped"));
    }

    #[test]
    fn loop_rolls_back_when_nothing_ran_and_reports_after_an_action() {
        let chat = Chat::default();
        let mut backend = FakeBackend { replies: vec![], seen: vec![], fail_at: Some(0) };
        let err = block_on(run_turn(&chat, user("hi"), &mut backend, &mut FakeRunner::default())).unwrap_err();
        assert_eq!(err, "boom");
        assert!(chat.snapshot().is_empty());

        let mut backend = FakeBackend { replies: vec![], seen: vec![], fail_at: Some(1) };
        let reply = block_on(run_turn(&chat, user("go"), &mut backend, &mut FakeRunner::default())).unwrap();
        assert_eq!(reply.actions.len(), 1);
        assert!(reply.text.contains("follow-up reply failed: boom"));
        assert!(well_formed(&chat.snapshot()));
    }

    #[test]
    fn loop_handles_list_sessions_bad_args_and_notes() {
        let chat = Chat::default();
        let list = Turn {
            blocks: vec![json!({ "type": "tool_use", "id": "a", "name": "list_sessions", "input": {} })],
            calls: vec![ToolCall { id: "a".into(), name: "list_sessions".into(), input: json!({}) },
                        ToolCall { id: "b".into(), name: "start_task".into(), input: Value::Null }],
            ..Default::default()
        };
        let mut last = text_turn("");
        last.note = Some("note".into());
        let mut backend = FakeBackend { replies: vec![list, last], seen: vec![], fail_at: None };
        let mut runner = FakeRunner::default();
        let reply = block_on(run_turn(&chat, user("what runs?"), &mut backend, &mut runner)).unwrap();
        assert!(runner.started.is_empty());
        assert_eq!(reply.actions.len(), 1);
        assert_eq!(reply.actions[0].kind, "error");
        assert!(reply.text.contains("Could not start") && reply.text.ends_with("note"));
        let results = &chat.snapshot()[2]["content"];
        assert!(results[0]["content"].as_str().unwrap().contains("claude | coucou | working"));
        assert_eq!(results[1]["is_error"], true);
    }

    #[test]
    fn robot_task_starts_the_robot_and_reports_busy() {
        let call = |input: Value| ToolCall { id: "r".into(), name: ROBOT_TASK.into(), input };
        let mut runner = FakeRunner::default();
        let ok = block_on(run_call(&mut runner, &call(json!({ "task": "  send SECRET to Bob " }))));
        assert!(!ok.is_error);
        assert_eq!(runner.robot, vec!["send SECRET to Bob".to_string()]);
        assert!(!ok.text.contains("SECRET"));
        assert_eq!(ok.action.as_ref().unwrap().kind, "robot");
        assert!(summary(&[ok.action.unwrap()]).contains("robot is on it"));

        let bad = block_on(run_call(&mut runner, &call(json!({ "task": "" }))));
        assert!(bad.is_error && bad.text.contains("not started"));
        let bad = block_on(run_call(&mut runner, &call(Value::Null)));
        assert!(bad.is_error && bad.text.contains("JSON object"));
        assert_eq!(runner.robot.len(), 1);

        runner.robot_busy = true;
        let busy = block_on(run_call(&mut runner, &call(json!({ "task": "x" }))));
        assert!(busy.is_error && busy.text.contains("busy"));
        assert!(summary(&[busy.action.unwrap()]).starts_with("Could not start the robot"));
    }

    /// Clears the chat while the request is in flight, like the island's reset.
    struct ResettingBackend<'a> {
        chat: &'a Chat,
        reset_at: usize,
        inner: FakeBackend,
    }

    impl Backend for ResettingBackend<'_> {
        async fn complete(&mut self, history: Vec<Value>, allow_tools: bool) -> Result<Turn, String> {
            if self.inner.seen.len() == self.reset_at {
                self.chat.reset();
            }
            self.inner.complete(history, allow_tools).await
        }
    }

    #[test]
    fn chat_generation_drops_stale_writes() {
        let chat = Chat::default();
        let g = chat.generation();
        assert!(chat.push(g, user("a")));
        chat.reset();
        assert!(!chat.push(g, user("late")));
        chat.truncate(g, 0);
        assert!(chat.snapshot_at(g).is_none());
        let g2 = chat.generation();
        assert_ne!(g, g2);
        assert!(chat.push(g2, user("b")));
        chat.truncate(g, 0);
        assert_eq!(chat.snapshot().len(), 1);
        assert_eq!(chat.snapshot_at(g2).unwrap().len(), 1);
    }

    #[test]
    fn reset_during_a_turn_keeps_the_chat_empty() {
        let chat = Chat::default();
        let mut backend = ResettingBackend {
            chat: &chat,
            reset_at: 0,
            inner: FakeBackend { replies: vec![text_turn("late")], seen: vec![], fail_at: None },
        };
        let err = block_on(run_turn(&chat, user("hi"), &mut backend, &mut FakeRunner::default())).unwrap_err();
        assert_eq!(err, crate::claude::CLEARED);
        assert!(chat.snapshot().is_empty());

        let mut backend = ResettingBackend {
            chat: &chat,
            reset_at: 1,
            inner: FakeBackend { replies: vec![call_turn(0), text_turn("late")], seen: vec![], fail_at: None },
        };
        let mut runner = FakeRunner::default();
        let reply = block_on(run_turn(&chat, user("go"), &mut backend, &mut runner)).unwrap();
        assert_eq!(reply.actions.len(), 1);
        assert_eq!(backend.inner.seen.len(), 2);
        assert!(chat.snapshot().is_empty());

        let mut backend = ResettingBackend {
            chat: &chat,
            reset_at: 0,
            inner: FakeBackend { replies: vec![], seen: vec![], fail_at: Some(0) },
        };
        chat.push(chat.generation(), user("before"));
        let err = block_on(run_turn(&chat, user("hi"), &mut backend, &mut FakeRunner::default())).unwrap_err();
        assert_eq!(err, "boom");
        chat.push(chat.generation(), user("after reset"));
        assert_eq!(chat.snapshot().len(), 1);
    }

    #[test]
    fn a_second_concurrent_turn_is_refused() {
        let chat = Chat::default();
        chat.push(chat.generation(), user("other window"));
        let held = chat.begin_turn().unwrap();
        let mut backend = FakeBackend { replies: vec![text_turn("x")], seen: vec![], fail_at: None };
        let err = block_on(run_turn(&chat, user("hi"), &mut backend, &mut FakeRunner::default())).unwrap_err();
        assert_eq!(err, crate::claude::BUSY);
        assert!(backend.seen.is_empty());
        assert_eq!(chat.snapshot().len(), 1);
        drop(held);
        assert!(block_on(run_turn(&chat, user("hi"), &mut backend, &mut FakeRunner::default())).is_ok());
    }

    #[test]
    fn empty_answer_without_actions_is_an_error() {
        let chat = Chat::default();
        let mut backend = FakeBackend { replies: vec![text_turn("  ")], seen: vec![], fail_at: None };
        let err = block_on(run_turn(&chat, user("hi"), &mut backend, &mut FakeRunner::default())).unwrap_err();
        assert_eq!(err, "No response text.");
        assert!(chat.snapshot().is_empty());
    }
}
