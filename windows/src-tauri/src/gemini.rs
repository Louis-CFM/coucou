// Google Gemini API client — OpenAI-compatible endpoint as in ClaudeService.swift
// Endpoint: https://generativelanguage.googleapis.com/v1beta/openai/chat/completions
//
// The API key lives in the Windows Credential Manager or Secret Service
// ("google-api-key") and never leaves the backend.

use serde_json::{json, Value};

use crate::claude::{base64_for, Chat, ChatContext, ChatReply};
use crate::secrets;

pub const DEFAULT_MODEL: &str = "gemini-2.0-flash";
const ENDPOINT: &str = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
const MAX_INLINE_TEXT: u64 = 200_000;

const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

/// One chat turn using Google Gemini.
pub async fn send(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get("google-api-key")
        .ok_or_else(|| "Google API key missing. Open settings.".to_string())?;

    let is_first = chat.is_empty();

    // Prepare content parts or text for this turn
    let mut parts: Vec<Value> = Vec::new();

    if is_first {
        match &context {
            Some(ChatContext::File { name, path }) => {
                if let Some(block) = file_content_part(path) {
                    parts.push(block);
                }
                parts.push(json!({ "type": "text", "text": format!("File: {name}") }));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                let mut text = format!("Context — App: {app_name}, Window: {title}");
                if let Some(url) = url {
                    text.push_str(&format!(", URL: {url}"));
                }
                parts.push(json!({ "type": "text", "text": text }));
            }
            None => {}
        }
    }

    parts.push(json!({ "type": "text", "text": query }));

    // User message
    let user_msg = if parts.len() == 1 && parts[0].get("type").and_then(Value::as_str) == Some("text") {
        json!({
            "role": "user",
            "content": parts[0]["text"].as_str().unwrap_or(&query),
        })
    } else {
        json!({
            "role": "user",
            "content": parts,
        })
    };

    chat.push(user_msg);

    // Build messages array including system prompt at the top
    let mut messages: Vec<Value> = vec![
        json!({ "role": "system", "content": SYSTEM_PROMPT }),
    ];
    messages.extend(chat.snapshot());

    let body = json!({
        "model": model,
        "messages": messages,
    });

    let response = match call(&key, &body).await {
        Ok(v) => v,
        Err(err) => {
            chat.pop();
            return Err(err);
        }
    };

    let reply_text = response
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .map(|s| s.trim().to_string())
        .unwrap_or_default();

    if reply_text.is_empty() {
        chat.pop();
        return Err("No response text from Gemini.".into());
    }

    chat.push(json!({ "role": "assistant", "content": reply_text.clone() }));
    Ok(ChatReply { text: reply_text })
}

async fn call(key: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(ENDPOINT)
        .header("Authorization", format!("Bearer {key}"))
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

fn file_content_part(path: &str) -> Option<Value> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    let media_type = match ext.as_str() {
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    };

    if let Some(mime) = media_type {
        let bytes = std::fs::read(path).ok()?;
        let b64 = base64_for(&bytes);
        return Some(json!({
            "type": "image_url",
            "image_url": {
                "url": format!("data:{mime};base64,{b64}")
            }
        }));
    }

    let len = std::fs::metadata(path).ok()?.len();
    if len > MAX_INLINE_TEXT {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    Some(json!({ "type": "text", "text": format!("File contents:\n{text}") }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_model_is_gemini_2_flash() {
        assert_eq!(DEFAULT_MODEL, "gemini-2.0-flash");
    }

    #[test]
    fn system_prompt_forbids_markdown() {
        assert!(SYSTEM_PROMPT.contains("No markdown formatting"));
    }
}
