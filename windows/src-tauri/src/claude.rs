// Claude API client — the same integration as ClaudeService.swift: multi-turn
// chat with web search, and files sent as document/image/text blocks.
//
// Everything happens here rather than in the island: the API key never leaves
// the Credential Manager, and file bytes never cross the IPC boundary.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::secrets;

const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
pub const DEFAULT_OLLAMA_ENDPOINT: &str = "http://127.0.0.1:11434/api/chat";
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
pub async fn send(
    chat: &Chat,
    provider: &str,
    model: &str,
    ollama_endpoint: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
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

    let messages = chat.snapshot();
    let (endpoint, body, headers) = match provider {
        "ollama" => {
            let endpoint = if ollama_endpoint.trim().is_empty() {
                DEFAULT_OLLAMA_ENDPOINT
            } else {
                ollama_endpoint.trim()
            };
            let body = json!({
                "model": model,
                "stream": false,
                "messages": ollama_messages(&messages),
            });
            (endpoint.to_string(), body, ProviderHeaders::Ollama)
        }
        "anthropic" | "" => {
            let key = secrets::get("anthropic-api-key")
                .ok_or_else(|| "Anthropic API key missing. Open settings.".to_string())?;
            let body = json!({
                "model": model,
                "max_tokens": MAX_TOKENS,
                "system": SYSTEM_PROMPT,
                "tools": [{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }],
                "fallbacks": "default",
                "messages": messages,
            });
            (ENDPOINT.to_string(), body, ProviderHeaders::Anthropic(key))
        }
        other => return Err(format!("Unsupported chat provider: {other}")),
    };

    let response = match call(&endpoint, &headers, &body).await {
        Ok(v) => v,
        Err(err) => {
            chat.pop(); // keep the history consistent with what the model saw
            return Err(err);
        }
    };

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

    let blocks = match response_blocks(&headers, &response) {
        Ok(blocks) => blocks,
        Err(error) => {
            chat.pop();
            return Err(error.into());
        }
    };

    // Store the whole content — tool_use / tool_result blocks included — so the
    // next turn has the right context.
    chat.push(json!({ "role": "assistant", "content": blocks.clone() }));

    let text = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();

    if text.is_empty() {
        return Err("No response text.".into());
    }
    Ok(ChatReply { text })
}

enum ProviderHeaders {
    Anthropic(String),
    Ollama,
}

async fn call(endpoint: &str, headers: &ProviderHeaders, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(endpoint)
        .headers(match headers {
            ProviderHeaders::Anthropic(key) => {
                let mut h = reqwest::header::HeaderMap::new();
                h.insert("x-api-key", key.parse().map_err(|_| "Invalid Anthropic API key".to_string())?);
                h.insert("anthropic-version", ANTHROPIC_VERSION.parse().unwrap());
                h.insert("anthropic-beta", FALLBACK_BETA.parse().unwrap());
                h
            }
            ProviderHeaders::Ollama => reqwest::header::HeaderMap::new(),
        })
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(provider_error(headers, status.as_u16(), &text));
    }

    fn provider_error(headers: &ProviderHeaders, status: u16, text: &str) -> String {
        let detail = serde_json::from_str::<Value>(text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| text.chars().take(200).collect());
        let name = if matches!(headers, ProviderHeaders::Ollama) { "Ollama" } else { "Claude API" };
        format!("{name} HTTP {status}: {detail}")
    }

    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

fn ollama_messages(messages: &[Value]) -> Vec<Value> {
    messages
        .iter()
        .filter_map(|message| {
            let role = message.get("role")?.as_str()?;
            let content = message.get("content")?;
            let text = if let Some(text) = content.as_str() {
                text.to_string()
            } else {
                content
                    .as_array()?
                    .iter()
                    .filter_map(|block| block.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            Some(json!({ "role": role, "content": text }))
        })
        .collect()
}

fn response_blocks(headers: &ProviderHeaders, response: &Value) -> Result<Vec<Value>, &'static str> {
    if matches!(headers, ProviderHeaders::Ollama) {
        let text = response
            .pointer("/message/content")
            .and_then(Value::as_str)
            .ok_or("Unexpected Ollama response.")?;
        if text.trim().is_empty() {
            return Err("No response text.");
        }
        Ok(vec![json!({ "type": "text", "text": text })])
    } else {
        response
            .get("content")
            .and_then(Value::as_array)
            .cloned()
            .ok_or("Unexpected API response.")
    }
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
    use super::{base64, ollama_messages, provider_error, response_blocks, ProviderHeaders};
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
    fn ollama_request_messages_are_text_only() {
        let messages = ollama_messages(&[json!({
            "role": "user",
            "content": [{"type": "text", "text": "hello"}, {"type": "text", "text": "world"}]
        })]);
        assert_eq!(messages, vec![json!({"role": "user", "content": "hello\nworld"})]);
    }

    #[test]
    fn ollama_response_requires_message_content() {
        let headers = ProviderHeaders::Ollama;
        assert_eq!(
            response_blocks(&headers, &json!({"message": {"content": "ok"}})).unwrap(),
            vec![json!({"type": "text", "text": "ok"})]
        );
        assert!(response_blocks(&headers, &json!({"message": {}})).is_err());
        assert!(response_blocks(&headers, &json!({"message": {"content": ""}})).is_err());
    }

    #[test]
    fn provider_errors_surface_json_message_and_bound_plain_text() {
        let headers = ProviderHeaders::Ollama;
        assert_eq!(
            provider_error(&headers, 404, r#"{"error":{"message":"model not found"}}"#),
            "Ollama HTTP 404: model not found"
        );
        assert!(provider_error(&headers, 500, &"x".repeat(300)).len() < 220);
    }
}
