// Claude API client — the same integration as ClaudeService.swift: multi-turn
// chat with web search, and files sent as document/image/text blocks.
//
// Two providers are supported:
//   * official — https://api.anthropic.com with the full feature set (server-
//     side web search, server-side fallback); the API key is required.
//   * custom — any endpoint configured in Settings, speaking either the
//     Anthropic Messages dialect or the OpenAI Chat Completions dialect
//     (proxies, gateways, local servers). Web search is omitted there: the
//     tool is Anthropic-specific, and a custom endpoint may not know it.
//
// Everything happens here rather than in the island: the API key never leaves
// the Credential Manager, and file bytes never cross the IPC boundary.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::secrets;

const ANTHROPIC_ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Official API only: on a policy decline the API retries the same request on
/// a fallback model inside the same call, so the island never shows a dead end.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const MAX_TOKENS: u32 = 4096;
/// Text and code files are inlined; anything larger is skipped, as on macOS.
const MAX_INLINE_TEXT: u64 = 200_000;

pub const DEFAULT_MODEL: &str = "claude-opus-5";

const SYSTEM_PROMPT_SEARCH: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

const SYSTEM_PROMPT_PLAIN: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

/// Where a chat turn goes — assembled from `Settings` in lib.rs.
#[derive(Debug, Clone)]
pub struct ChatConfig {
    /// "anthropic" (the official API) or "custom".
    pub mode: String,
    /// Already resolved: `custom_model` when a custom provider names one,
    /// otherwise the regular `model`.
    pub model: String,
    /// Custom endpoint base URL; unused for the official provider.
    pub base_url: String,
    /// Custom endpoint dialect: "anthropic" or "openai".
    pub api_style: String,
}

impl ChatConfig {
    fn custom(&self) -> bool {
        self.mode == "custom"
    }

    fn openai(&self) -> bool {
        self.custom() && self.api_style == "openai"
    }
}

/// Custom base URL → full endpoint. The base may be a root
/// ("http://127.0.0.1:20128"), already carry "/v1", or name the full path.
fn endpoint_for(base: &str, openai: bool) -> String {
    let base = base.trim().trim_end_matches('/');
    if openai {
        if base.ends_with("/chat/completions") {
            base.to_string()
        } else if base.ends_with("/v1") {
            format!("{base}/chat/completions")
        } else {
            format!("{base}/v1/chat/completions")
        }
    } else if base.ends_with("/messages") {
        base.to_string()
    } else if base.ends_with("/v1") {
        format!("{base}/messages")
    } else {
        format!("{base}/v1/messages")
    }
}

fn system_prompt(official: bool) -> &'static str {
    if official {
        SYSTEM_PROMPT_SEARCH
    } else {
        SYSTEM_PROMPT_PLAIN
    }
}

#[derive(Default)]
pub struct Chat {
    /// Full multi-turn history, including tool_use / tool_result blocks.
    messages: Mutex<Vec<Value>>,
}

impl Chat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }

    fn is_empty(&self) -> bool {
        self.messages.lock().unwrap().is_empty()
    }

    fn push(&self, message: Value) {
        self.messages.lock().unwrap().push(message);
    }

    fn pop(&self) {
        self.messages.lock().unwrap().pop();
    }

    fn snapshot(&self) -> Vec<Value> {
        self.messages.lock().unwrap().clone()
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatContext {
    File { name: String, path: String },
    Window { app_name: String, title: String, url: Option<String> },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatReply {
    pub text: String,
}

/// One chat turn. Returns the assistant's text, or a message the island shows
/// in the note view.
///
/// The history is always stored Anthropic-shaped (arrays of content blocks);
/// the OpenAI dialect gets a fresh conversion on every request, so switching
/// the provider in Settings never corrupts an existing conversation.
pub async fn send(
    chat: &Chat,
    cfg: &ChatConfig,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let custom = cfg.custom();
    let openai = cfg.openai();
    let official = !custom;

    let endpoint = if custom {
        if cfg.base_url.trim().is_empty() {
            return Err("Custom base URL missing. Open settings.".into());
        }
        endpoint_for(&cfg.base_url, openai)
    } else {
        ANTHROPIC_ENDPOINT.to_string()
    };

    // Local gateways often need no key at all — only the official API demands one.
    let key = if custom {
        secrets::get("custom-api-key").unwrap_or_default()
    } else {
        secrets::get("anthropic-api-key")
            .ok_or_else(|| "API key missing. Open settings.".to_string())?
    };

    let mut content: Vec<Value> = Vec::new();

    // File / window context rides along with the first message only, exactly
    // like ClaudeService.chat().
    if chat.is_empty() {
        match &context {
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
    }
    content.push(json!({ "type": "text", "text": query }));

    chat.push(json!({ "role": "user", "content": content }));

    let body = if openai {
        json!({
            "model": cfg.model,
            "max_tokens": MAX_TOKENS,
            "messages": openai_messages(&chat.snapshot(), system_prompt(official)),
        })
    } else {
        let mut body = json!({
            "model": cfg.model,
            "max_tokens": MAX_TOKENS,
            "system": system_prompt(official),
            "messages": chat.snapshot(),
        });
        // Web search and the server-side fallback are official-API features;
        // a custom endpoint gets a plain Messages request it can always parse.
        if official {
            body["tools"] = json!([{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }]);
            body["fallbacks"] = json!("default");
        }
        body
    };

    let response = match call(&endpoint, &key, official, openai, &body).await {
        Ok(v) => v,
        Err(err) => {
            chat.pop(); // keep the history consistent with what the model saw
            return Err(err);
        }
    };

    if openai {
        let text = response
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|c| c.first())
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        if text.is_empty() {
            chat.pop();
            return Err("No response text.".into());
        }
        // Stored as an Anthropic-shaped text block: the converter above and any
        // later style switch always see the same history shape.
        chat.push(json!({ "role": "assistant", "content": [{ "type": "text", "text": &text }] }));
        return Ok(ChatReply { text });
    }

    // A policy decline comes back as HTTP 200 with stop_reason "refusal".
    if response.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        chat.pop();
        let why = response
            .get("stop_details")
            .and_then(|d| d.get("explanation"))
            .and_then(Value::as_str)
            .unwrap_or("Claude declined this one.");
        return Err(why.to_string());
    }

    let Some(blocks) = response.get("content").and_then(Value::as_array).cloned() else {
        chat.pop();
        return Err("Unexpected API response.".into());
    };

    // Store the whole content — tool_use / tool_result blocks included — so the
    // next turn has the right context.
    chat.push(json!({ "role": "assistant", "content": blocks.clone() }));

    let text = text_of(&blocks);

    if text.is_empty() {
        return Err("No response text.".into());
    }
    Ok(ChatReply { text })
}

/// All text blocks of one Anthropic content array, joined.
fn text_of(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// The stored history (Anthropic-shaped) → OpenAI Chat Completions messages.
/// Images become data URIs; PDF blocks are skipped (no portable equivalent).
fn openai_messages(history: &[Value], system: &str) -> Value {
    let mut out: Vec<Value> = vec![json!({ "role": "system", "content": system })];
    for m in history {
        let role = m.get("role").and_then(Value::as_str).unwrap_or("user");
        let content = match m.get("content") {
            Some(Value::String(s)) => json!(s),
            Some(Value::Array(blocks)) if role == "assistant" => json!(text_of(blocks)),
            Some(Value::Array(blocks)) => {
                json!(blocks.iter().filter_map(openai_part).collect::<Vec<Value>>())
            }
            _ => json!(""),
        };
        out.push(json!({ "role": role, "content": content }));
    }
    json!(out)
}

/// One Anthropic content block → one OpenAI content part.
fn openai_part(b: &Value) -> Option<Value> {
    match b.get("type").and_then(Value::as_str) {
        Some("text") => Some(json!({ "type": "text", "text": b.get("text")?.as_str()? })),
        Some("image") => {
            let source = b.get("source")?;
            let media = source.get("media_type")?.as_str()?;
            let data = source.get("data")?.as_str()?;
            Some(json!({
                "type": "image_url",
                "image_url": { "url": format!("data:{media};base64,{data}") },
            }))
        }
        _ => None,
    }
}

async fn call(
    endpoint: &str,
    key: &str,
    official: bool,
    openai: bool,
    body: &Value,
) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let mut request = client
        .post(endpoint)
        .header("content-type", "application/json");
    if openai {
        if !key.is_empty() {
            request = request.header("Authorization", format!("Bearer {key}"));
        }
    } else {
        if !key.is_empty() {
            request = request.header("x-api-key", key);
        }
        request = request.header("anthropic-version", ANTHROPIC_VERSION);
        if official {
            request = request.header("anthropic-beta", FALLBACK_BETA);
        }
    }

    let response = request
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
                    .or_else(|| v.get("message").and_then(Value::as_str).map(str::to_string))
            })
            .unwrap_or_else(|| text.chars().take(200).collect());
        let prefix = if official { "Claude API" } else { "API" };
        return Err(format!("{prefix} {status}: {detail}"));
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
    use super::{base64, endpoint_for, openai_messages};
    use serde_json::json;

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
    fn endpoint_for_handles_roots_v1_and_full_paths() {
        // Anthropic dialect
        assert_eq!(endpoint_for("http://127.0.0.1:20128", false), "http://127.0.0.1:20128/v1/messages");
        assert_eq!(endpoint_for("https://api.example.com/", false), "https://api.example.com/v1/messages");
        assert_eq!(endpoint_for("https://api.example.com/v1", false), "https://api.example.com/v1/messages");
        assert_eq!(endpoint_for("https://api.example.com/v1/messages", false), "https://api.example.com/v1/messages");
        // OpenAI dialect
        assert_eq!(endpoint_for("http://127.0.0.1:20128", true), "http://127.0.0.1:20128/v1/chat/completions");
        assert_eq!(endpoint_for("https://gateway.example.com/v1", true), "https://gateway.example.com/v1/chat/completions");
        assert_eq!(endpoint_for("https://gateway.example.com/v1/chat/completions", true), "https://gateway.example.com/v1/chat/completions");
    }

    #[test]
    fn openai_messages_converts_blocks_and_keeps_system_first() {
        let history = vec![
            json!({ "role": "user", "content": [
                { "type": "text", "text": "File: a.txt" },
                { "type": "text", "text": "hello" },
            ]}),
            json!({ "role": "assistant", "content": [{ "type": "text", "text": "hi" }] }),
        ];
        let out = openai_messages(&history, "sys");
        assert_eq!(out[0]["role"], "system");
        assert_eq!(out[0]["content"], "sys");
        assert_eq!(out[1]["role"], "user");
        assert_eq!(out[1]["content"][0]["type"], "text");
        assert_eq!(out[1]["content"][1]["text"], "hello");
        assert_eq!(out[2]["content"], "hi");
    }
}
