// Gemini API client — alternative provider for the island chat.
// Mirrors claude.rs shape (Chat history + file context) but talks to
// https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
// API key lives in the Credential Manager under "gemini-api-key".

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::secrets;

const MAX_INLINE_TEXT: u64 = 200_000;

pub const DEFAULT_GEMINI_MODEL: &str = "gemini-2.5-flash";

pub const GEMINI_MODELS: &[&str] = &[
    "gemini-2.5-flash",
    "gemini-2.5-pro",
    "gemini-2.0-flash",
];

const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You can help with anything — research, coding, places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough but concise. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

#[derive(Default)]
pub struct GeminiChat {
    /// Simplified history: alternating user/model turns as plain text.
    /// (Gemini tool_use blocks are not needed — no web_search here yet.)
    messages: Mutex<Vec<Value>>,
}

impl GeminiChat {
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
pub enum GeminiContext {
    File { name: String, path: String },
    Window { app_name: String, title: String, url: Option<String> },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeminiReply {
    pub text: String,
}

pub async fn send(
    chat: &GeminiChat,
    model: &str,
    query: String,
    context: Option<GeminiContext>,
) -> Result<GeminiReply, String> {
    let key = secrets::get("gemini-api-key")
        .ok_or_else(|| "Gemini API key missing. Open settings.".to_string())?;

    let model = if model.is_empty() { DEFAULT_GEMINI_MODEL } else { model };

    // First turn may carry file/window context. Files ride as real parts —
    // images/PDF as inlineData so the model actually sees them (a bare
    // filename is what used to produce "I can't see images"), text inline.
    let mut lead_parts: Vec<Value> = Vec::new();
    let mut full_query = String::new();
    if chat.is_empty() {
        match &context {
            Some(GeminiContext::File { name, path }) => {
                match content_block(path) {
                    Some(block) => {
                        lead_parts.push(block);
                        full_query.push_str(&format!("File: {name}\n\n"));
                    }
                    None => {
                        full_query.push_str(&format!("File: {name} (could not read contents)\n\n"));
                    }
                }
            }
            Some(GeminiContext::Window { app_name, title, url }) => {
                full_query.push_str(&format!("Context — App: {app_name}, Window: {title}"));
                if let Some(url) = url {
                    full_query.push_str(&format!(", URL: {url}"));
                }
                full_query.push_str("\n\n");
            }
            None => {}
        }
    }
    full_query.push_str(&query);
    lead_parts.push(json!({ "text": full_query }));

    chat.push(json!({ "role": "user", "parts": lead_parts }));

    let body = json!({
        "system_instruction": { "parts": [{ "text": SYSTEM_PROMPT }] },
        "contents": chat.snapshot(),
        "generationConfig": { "maxOutputTokens": 4096, "temperature": 0.7 },
    });

    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent",
        urlencoding_safe(model)
    );

    let response = call(&url, &key, &body).await.map_err(|e| {
        chat.pop();
        e
    })?;

    let text = response
        .get("candidates")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("content"))
        .and_then(|c| c.get("parts"))
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
        .trim()
        .to_string();

    if text.is_empty() {
        // Surface API-level error message when present.
        if let Some(err) = response.get("error").and_then(|e| e.get("message")).and_then(Value::as_str) {
            chat.pop();
            return Err(format!("Gemini API: {err}"));
        }
        chat.pop();
        return Err("No response text.".into());
    }

    chat.push(json!({ "role": "model", "parts": [{ "text": text.clone() }] }));
    Ok(GeminiReply { text })
}

async fn call(url: &str, key: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(url)
        .header("x-goog-api-key", key)
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(format!("Gemini API {status}: {detail}"));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

/// File → Gemini part. Mirrors the Claude `file_block` mapping:
/// PDF/images ride as inlineData (base64) so the model sees them;
/// text/code rides inline; anything else is None (caller says so in text).
fn content_block(path: &str) -> Option<Value> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    let media_type = match ext.as_str() {
        "pdf" => Some("application/pdf"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    };

    if let Some(media) = media_type {
        // Captures and photos run a few MB — still fine for one turn.
        if std::fs::metadata(path).ok()?.len() > 20_000_000 {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        return Some(json!({
            "inlineData": { "mimeType": media, "data": crate::claude::base64_for(&bytes) },
        }));
    }

    let len = std::fs::metadata(path).ok()?.len();
    if len > MAX_INLINE_TEXT {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    Some(json!({ "text": format!("File contents:\n{text}") }))
}

fn urlencoding_safe(model: &str) -> String {
    // Model ids are `[a-z0-9.-]` — no encoding needed, but never pass slashes.
    model.replace('/', "_").replace(' ', "-")
}
