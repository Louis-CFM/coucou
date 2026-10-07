// Claude API client — the same integration as ClaudeService.swift: multi-turn
// chat with web search, and files sent as document/image/text blocks. The
// task tools (start_task, list_sessions) and their loop live in tools.rs.
//
// Everything happens here rather than in the island: the API key never leaves
// the Credential Manager, and file bytes never cross the IPC boundary.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::secrets;
use crate::tools::{self, Backend, ChatAction, ToolRunner, Turn};

const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Server-side fallback: on a policy decline the API retries the same request on
/// a fallback model inside the same call, so the island never shows a dead end.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const MAX_TOKENS: u32 = 4096;
/// Text and code files are inlined; anything larger is skipped, as on macOS.
const MAX_INLINE_TEXT: u64 = 200_000;

pub const DEFAULT_MODEL: &str = "claude-opus-5";

const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

/// The same persona for providers that get no web_search tool.
pub(crate) const SYSTEM_PROMPT_NO_SEARCH: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

#[derive(Default)]
pub struct Chat {
    history: Mutex<History>,
    turn: tokio::sync::Mutex<()>,
}

#[derive(Default)]
struct History {
    generation: u64,
    messages: Vec<Value>,
}

pub(crate) const BUSY: &str = "Coucou is still answering the other chat window.";
pub(crate) const CLEARED: &str = "The chat was cleared.";

impl Chat {
    pub fn reset(&self) {
        let mut history = self.history.lock().unwrap();
        history.messages.clear();
        history.generation += 1;
    }

    pub(crate) fn begin_turn(&self) -> Result<tokio::sync::MutexGuard<'_, ()>, String> {
        self.turn.try_lock().map_err(|_| BUSY.to_string())
    }

    pub(crate) fn generation(&self) -> u64 {
        self.history.lock().unwrap().generation
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.history.lock().unwrap().messages.is_empty()
    }

    pub(crate) fn push(&self, generation: u64, message: Value) -> bool {
        let mut history = self.history.lock().unwrap();
        if history.generation != generation { return false; }
        history.messages.push(message);
        true
    }

    pub(crate) fn len(&self) -> usize {
        self.history.lock().unwrap().messages.len()
    }

    pub(crate) fn truncate(&self, generation: u64, len: usize) {
        let mut history = self.history.lock().unwrap();
        if history.generation == generation { history.messages.truncate(len); }
    }

    pub(crate) fn snapshot_at(&self, generation: u64) -> Option<Vec<Value>> {
        let history = self.history.lock().unwrap();
        (history.generation == generation).then(|| history.messages.clone())
    }

    #[cfg(test)]
    pub(crate) fn snapshot(&self) -> Vec<Value> {
        self.history.lock().unwrap().messages.clone()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatContext {
    File { name: String, path: String },
    Window { app_name: String, title: String, url: Option<String> },
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatReply {
    pub text: String,
    /// Tasks the chat started (or tried to), for the system lines in the log.
    pub actions: Vec<ChatAction>,
    pub memory_status: Option<String>,
    pub turn_id: Option<String>,
}

pub(crate) fn system_prompt() -> String {
    format!("{SYSTEM_PROMPT}{}", tools::GUIDANCE)
}

/// One chat turn, with the task tools. Returns the assistant's text, or a
/// message the island shows in the note view.
pub(crate) async fn send<R: ToolRunner>(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
    memory_context: Option<String>,
    runner: &mut R,
) -> Result<ChatReply, String> {
    let key = secrets::get("anthropic-api-key")
        .ok_or_else(|| "API key missing. Open settings.".to_string())?;

    // File / window context rides along with the first message only, exactly
    // like ClaudeService.chat().
    let mut content = if chat.is_empty() { context_blocks(&context) } else { Vec::new() };
    content.push(json!({ "type": "text", "text": query }));

    let access = tools::ToolAccess::for_memory_context(memory_context.as_deref());
    let mut backend = Anthropic { key, model: model.to_string(), defaults: runner.defaults(), memory_context };
    tools::run_turn_with_access(chat, json!({ "role": "user", "content": content }), &mut backend, runner, access).await
}

struct Anthropic {
    key: String,
    model: String,
    defaults: tools::ToolDefaults,
    memory_context: Option<String>,
}

pub(crate) fn build_body(model: &str, history: Vec<Value>, defaults: &tools::ToolDefaults, allow_tools: bool, memory_context: Option<&str>) -> Value {
    let mut all_tools = vec![json!({ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 })];
    all_tools.extend(tools::anthropic_tools(defaults, tools::ToolAccess::for_memory_context(memory_context)));
    let mut system = system_prompt();
    if let Some(memory_context) = memory_context {
        system.push_str("\n\n");
        system.push_str(memory_context);
    }
    let mut body = json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": system,
        "tools": all_tools,
        "fallbacks": "default",
        "messages": history,
    });
    if !allow_tools {
        body["tool_choice"] = json!({ "type": "none" });
    }
    body
}

/// An Anthropic reply → the loop's Turn. Refusals and odd shapes are errors.
pub(crate) fn parse_turn(response: &Value) -> Result<Turn, String> {
    // A policy decline comes back as HTTP 200 with stop_reason "refusal".
    if response.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        let why = response
            .get("stop_details")
            .and_then(|d| d.get("explanation"))
            .and_then(Value::as_str)
            .unwrap_or("Claude declined this one.");
        return Err(why.to_string());
    }
    let blocks = response
        .get("content")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(|| "Unexpected API response.".to_string())?;
    let text = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    let calls = tools::parse_anthropic_calls(&blocks);
    // Store the whole content (server_tool_use / tool_use included) so the next
    // turn has the right context.
    Ok(Turn { blocks, text, calls, note: None })
}

impl Backend for Anthropic {
    async fn complete(&mut self, history: Vec<Value>, allow_tools: bool) -> Result<Turn, String> {
        let body = build_body(&self.model, history, &self.defaults, allow_tools, self.memory_context.as_deref());
        let response = call(&self.key, &body).await?;
        parse_turn(&response)
    }
}

/// The first-turn context blocks for a dropped file or the focused window.
pub(crate) fn context_blocks(context: &Option<ChatContext>) -> Vec<Value> {
    let mut content = Vec::new();
    match context {
        Some(ChatContext::File { name, path }) => {
            if let Some(block) = file_block(path) {
                content.push(block);
            }
            content.push(json!({ "type": "text", "text": format!("File: {name}") }));
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            let mut text = format!("Context — App: {app_name}, Window: {title}");
            if let Some(url) = url {
                text.push_str(&format!(", URL: {url}"));
            }
            content.push(json!({ "type": "text", "text": text }));
        }
        None => {}
    }
    content
}

async fn call(key: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(ENDPOINT)
        .header("x-api-key", key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .header("anthropic-beta", FALLBACK_BETA)
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        // Surface the API's own message, which is what makes a bad key obvious.
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(format!("Claude API {status}: {detail}"));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

/// PDF → document block, image → image block, text/code → inline text.
/// Mirrors readFileAsBlock() in ClaudeService.swift.
fn file_block(path: &str) -> Option<Value> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    let media_type = match ext.as_str() {
        "pdf" => Some(("document", "application/pdf")),
        "jpg" | "jpeg" => Some(("image", "image/jpeg")),
        "png" => Some(("image", "image/png")),
        "gif" => Some(("image", "image/gif")),
        "webp" => Some(("image", "image/webp")),
        _ => None,
    };

    if let Some((block_type, media)) = media_type {
        let bytes = std::fs::read(path).ok()?;
        return Some(json!({
            "type": block_type,
            "source": { "type": "base64", "media_type": media, "data": base64(&bytes) },
        }));
    }

    let len = std::fs::metadata(path).ok()?.len();
    if len > MAX_INLINE_TEXT {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    Some(json!({ "type": "text", "text": format!("File contents:\n{text}") }))
}

/// Small standalone base64 encoder — not worth another dependency.
/// Also used for Stripe's basic auth.
pub(crate) fn base64_for(bytes: &[u8]) -> String {
    base64(bytes)
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_rfc4648_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
        assert_eq!(base64(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn body_carries_web_search_and_task_tools() {
        let d = tools::ToolDefaults::default();
        let trusted = system_prompt();
        let history = vec![json!({ "role": "user", "content": [{ "type": "text", "text": "hello" }] })];
        let body = build_body("m", history.clone(), &d, true, Some("untrusted memory"));
        let names: Vec<&str> = body["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, vec!["web_search", "list_sessions"]);
        assert!(body.get("tool_choice").is_none());
        assert!(body.get("context").is_none());
        let system = body["system"].as_str().unwrap();
        assert!(system.starts_with(&trusted));
        assert!(system.ends_with("untrusted memory"));
        assert_eq!(body["messages"], json!(history));
        let unrestricted = build_body("m", vec![], &d, true, None);
        let unrestricted_names: Vec<&str> = unrestricted["tools"].as_array().unwrap().iter().map(|tool| tool["name"].as_str().unwrap()).collect();
        assert_eq!(unrestricted_names, vec!["web_search", "start_task", "list_sessions", "robot_task"]);
        assert_eq!(build_body("m", vec![], &d, false, None)["tool_choice"], json!({ "type": "none" }));
    }

    #[test]
    fn turns_are_parsed_from_replies() {
        let reply = json!({ "stop_reason": "tool_use", "content": [
            { "type": "text", "text": " Starting. " },
            { "type": "tool_use", "id": "toolu_1", "name": "start_task", "input": { "agent": "claude", "prompt": "p" } }
        ] });
        let turn = parse_turn(&reply).unwrap();
        assert_eq!(turn.text, "Starting.");
        assert_eq!(turn.calls.len(), 1);
        assert_eq!(turn.blocks.len(), 2);
        let refusal = json!({ "stop_reason": "refusal", "stop_details": { "explanation": "no" } });
        assert_eq!(parse_turn(&refusal).unwrap_err(), "no");
        assert!(parse_turn(&json!({})).is_err());
    }
}
