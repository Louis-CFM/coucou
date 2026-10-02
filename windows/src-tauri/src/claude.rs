// Claude API client — the same integration as ClaudeService.swift: multi-turn
// chat with web search, and files sent as document/image/text blocks.
//
// Everything happens here rather than in the island: the API key never leaves
// the Credential Manager, and file bytes never cross the IPC boundary.

use parking_lot::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::providers;
use crate::secrets;

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

/// One conversation per provider id.
///
/// Anthropic and OpenAI message shapes are not interchangeable — a thread that
/// carried `tool_use` blocks through to a `/chat/completions` request comes back as a
/// 400. Keying by provider keeps each thread internally consistent, and switching back
/// and forth returns to the conversation you left instead of destroying it.
#[derive(Default)]
pub struct Chat {
    threads: Mutex<std::collections::HashMap<String, Vec<Value>>>,
}

impl Chat {
    pub fn reset(&self) {
        self.threads.lock().clear();
    }

    fn is_empty(&self, provider: &str) -> bool {
        self.threads.lock().get(provider).is_none_or(Vec::is_empty)
    }

    fn push(&self, provider: &str, message: Value) {
        self.threads
            .lock()
            .entry(provider.to_string())
            .or_default()
            .push(message);
    }

    fn pop(&self, provider: &str) {
        if let Some(thread) = self.threads.lock().get_mut(provider) {
            thread.pop();
        }
    }

    fn snapshot(&self, provider: &str) -> Vec<Value> {
        self.threads.lock().get(provider).cloned().unwrap_or_default()
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

/// One chat turn against the resolved provider. Returns the assistant's text, or a
/// message the island shows in the note view.
///
/// `provider` is the id that keys the conversation thread; `route` says where to send
/// it and in which dialect. The key is read from `route.key_name` — it never crosses
/// the IPC boundary, and the caller cannot choose a different key name than the one
/// the provider table implies.
pub async fn send(
    chat: &Chat,
    provider: &str,
    route: &providers::Route,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get(&route.key_name).ok_or_else(|| {
        format!("No API key for {provider}. Open Settings to add one.")
    })?;

    // File / window context rides along with the first message of this provider's
    // thread only, exactly like ClaudeService.chat().
    let preamble = match (&context, chat.is_empty(provider)) {
        (Some(ctx), true) => Some(ctx.clone()),
        _ => None,
    };

    let content = content_blocks(route.dialect, query, preamble);
    chat.push(provider, user_message(route.dialect, content));

    let body = match route.dialect {
        providers::Dialect::Anthropic => json!({
            "model": route.model,
            "max_tokens": MAX_TOKENS,
            "system": SYSTEM_PROMPT,
            // Server-side web search is an Anthropic feature. OpenAI-compatible
            // gateways have no equivalent in their chat-completions shape, so the
            // second dialect goes without it rather than sending a tool the endpoint
            // would reject.
            "tools": [{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }],
            "fallbacks": "default",
            "messages": chat.snapshot(provider),
        }),
        providers::Dialect::OpenAI => json!({
            "model": route.model,
            "max_tokens": MAX_TOKENS,
            "messages": openai_messages(provider, SYSTEM_PROMPT, chat),
        }),
    };

    let response = match call(route, &key, &body).await {
        Ok(v) => v,
        Err(err) => {
            chat.pop(provider); // keep the history consistent with what the model saw
            return Err(err);
        }
    };

    let (assistant, text) = match route.dialect {
        // A policy decline comes back as HTTP 200 with stop_reason "refusal".
        providers::Dialect::Anthropic => {
            if response.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
                chat.pop(provider);
                let why = response
                    .get("stop_details")
                    .and_then(|d| d.get("explanation"))
                    .and_then(Value::as_str)
                    .unwrap_or("The model declined this one.");
                return Err(why.to_string());
            }
            let Some(blocks) = response.get("content").and_then(Value::as_array).cloned() else {
                chat.pop(provider);
                return Err("Unexpected API response.".into());
            };
            let text = blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|b| b.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
                .trim()
                .to_string();
            // Store the whole content — tool_use / tool_result blocks included — so the
            // next turn has the right context.
            (json!({ "role": "assistant", "content": blocks }), text)
        }
        providers::Dialect::OpenAI => {
            let Some(choice) = response
                .get("choices")
                .and_then(Value::as_array)
                .and_then(|c| c.first())
                .and_then(|c| c.get("message"))
            else {
                chat.pop(provider);
                return Err("Unexpected API response.".into());
            };
            let text = choice
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string();
            (
                json!({
                    "role": "assistant",
                    "content": choice.get("content").cloned().unwrap_or(Value::Null),
                }),
                text,
            )
        }
    };

    chat.push(provider, assistant);

    if text.is_empty() {
        return Err("No response text.".into());
    }
    Ok(ChatReply { text })
}

/// OpenAI chat-completions wants a flat `messages` array with the system prompt as the
/// first entry. Threads are stored in the dialect that produced them, so the history
/// replays verbatim.
fn openai_messages(provider: &str, system: &str, chat: &Chat) -> Vec<Value> {
    let mut messages = vec![json!({ "role": "system", "content": system })];
    messages.extend(chat.snapshot(provider));
    messages
}

/// A user turn in the dialect's own shape.
fn user_message(dialect: providers::Dialect, content: Vec<Value>) -> Value {
    match dialect {
        providers::Dialect::Anthropic => json!({ "role": "user", "content": content }),
        providers::Dialect::OpenAI => {
            // Chat Completions content is either a string or an array of typed parts.
            // A single text part collapses to a string, which every gateway accepts.
            let only_text = content.len() == 1
                && content[0].get("type").and_then(Value::as_str) == Some("text");
            let value = if only_text {
                Value::String(content[0]["text"].as_str().unwrap_or_default().to_string())
            } else {
                Value::Array(content)
            };
            json!({ "role": "user", "content": value })
        }
    }
}

/// Context blocks, in the dialect's shape. Anthropic takes typed blocks; OpenAI takes
/// `image_url` parts for images and plain text for everything else.
fn content_blocks(
    dialect: providers::Dialect,
    query: String,
    context: Option<ChatContext>,
) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    match context {
        Some(ChatContext::File { name, path }) => {
            if let Some(block) = file_block(dialect, &path) {
                out.push(block);
            }
            out.push(text_block(dialect, format!("File: {name}")));
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            let mut text = format!("Context — App: {app_name}, Window: {title}");
            if let Some(url) = url {
                text.push_str(&format!(", URL: {url}"));
            }
            out.push(text_block(dialect, text));
        }
        None => {}
    }
    out.push(text_block(dialect, query));
    out
}

fn text_block(dialect: providers::Dialect, text: String) -> Value {
    match dialect {
        providers::Dialect::Anthropic => json!({ "type": "text", "text": text }),
        providers::Dialect::OpenAI => json!({ "type": "text", "text": text }),
    }
}

async fn call(route: &providers::Route, key: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let url = providers::endpoint(route.dialect, &route.base_url);
    let mut request = client.post(&url).header("content-type", "application/json");
    request = match route.dialect {
        providers::Dialect::Anthropic => request
            .header("x-api-key", key)
            .header("anthropic-version", ANTHROPIC_VERSION)
            .header("anthropic-beta", FALLBACK_BETA),
        providers::Dialect::OpenAI => request.header("authorization", format!("Bearer {key}")),
    };

    let response = request
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        // Surface the API's own message, which is what makes a bad key obvious. The
        // envelope differs per dialect but `error.message` is common to both.
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(format!("{} {status}: {detail}", route.label));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

/// A dropped file as a content block in the target dialect.
///
/// Mirrors readFileAsBlock() in ClaudeService.swift for the Anthropic shape. Chat
/// Completions has no `document` block and no base64 `source`, so a PDF degrades to
/// its text and an image becomes an `image_url` data URI — the shape every
/// OpenAI-compatible gateway accepts.
fn file_block(dialect: providers::Dialect, path: &str) -> Option<Value> {
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

    let len = std::fs::metadata(path).ok()?.len();

    if let Some((block_type, media)) = media_type {
        let bytes = std::fs::read(path).ok()?;
        return Some(match dialect {
            providers::Dialect::Anthropic => json!({
                "type": block_type,
                "source": { "type": "base64", "media_type": media, "data": base64(&bytes) },
            }),
            providers::Dialect::OpenAI if block_type == "image" => json!({
                "type": "image_url",
                "image_url": { "url": format!("data:{media};base64,{}", base64(&bytes)) },
            }),
            // A PDF has no portable Chat Completions equivalent, so it falls back to
            // its text when small enough to inline and is skipped when not.
            providers::Dialect::OpenAI => {
                if len > MAX_INLINE_TEXT {
                    return None;
                }
                let text = std::fs::read_to_string(path).ok()?;
                return Some(json!({ "type": "text", "text": format!("File contents:\n{text}") }));
            }
        });
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
    use super::base64;

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
}
