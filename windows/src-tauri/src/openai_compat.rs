// OpenAI-compatible chat client, used for OpenRouter.
//
// Same contract as claude.rs: one multi-turn chat, the API key never leaves the
// keychain, file bytes never cross the IPC boundary. Chat only: no tools are
// sent, so the model can answer but can never act on the machine.

use std::sync::Mutex;

use serde::Serialize;
use serde_json::{json, Value};

use crate::claude::{ChatContext, ChatReply};
use crate::secrets;

pub const OPENROUTER_BASE: &str = "https://openrouter.ai/api/v1";
pub const OPENROUTER_KEY: &str = "openrouter-api-key";
const MAX_TOKENS: u32 = 4096;
/// Text and code files are inlined; anything larger is skipped.
const MAX_INLINE_TEXT: u64 = 200_000;
/// Images are sent inline as data URLs; past this size they are skipped.
const MAX_IMAGE: u64 = 5_000_000;

const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You can help with questions, coding, writing, explanations and planning. You have no tools and no internet access: \
if something needs current information, say so. Respond in the user's language. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

#[derive(Default)]
pub struct OaiChat {
    /// User and assistant turns, OpenAI message format, without the system prompt.
    messages: Mutex<Vec<Value>>,
}

impl OaiChat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }
}

/// One chat turn against OpenRouter.
pub async fn send(
    chat: &OaiChat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get(OPENROUTER_KEY)
        .ok_or_else(|| "OpenRouter API key missing. Open settings.".to_string())?;
    if model.trim().is_empty() {
        return Err("Pick an OpenRouter model in settings.".into());
    }

    let first = chat.messages.lock().unwrap().is_empty();
    let mut content: Vec<Value> = Vec::new();
    // File / window context rides along with the first message only, as in claude.rs.
    if first {
        match &context {
            Some(ChatContext::File { name, path }) => {
                if let Some(part) = file_part(path) {
                    content.push(part);
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
    let user = json!({ "role": "user", "content": content });

    let mut messages = vec![json!({ "role": "system", "content": SYSTEM_PROMPT })];
    messages.extend(chat.messages.lock().unwrap().iter().cloned());
    messages.push(user.clone());

    let body = json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "messages": messages,
    });

    let response = call(&key, &body).await?;

    let text = response
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if text.is_empty() {
        // OpenRouter can return 200 with an error object (provider failure).
        if let Some(msg) = response.pointer("/error/message").and_then(Value::as_str) {
            return Err(format!("OpenRouter: {msg}"));
        }
        return Err("No response text.".into());
    }

    // Only a successful turn enters the history, so it always matches what the model saw.
    let mut history = chat.messages.lock().unwrap();
    history.push(user);
    history.push(json!({ "role": "assistant", "content": text }));
    Ok(ChatReply { text })
}

fn client(timeout_secs: u64) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .build()
        .map_err(|e| e.to_string())
}

async fn call(key: &str, body: &Value) -> Result<Value, String> {
    let response = client(120)?
        .post(format!("{OPENROUTER_BASE}/chat/completions"))
        .bearer_auth(key)
        // Optional attribution headers documented by OpenRouter.
        .header("X-Title", "Coucou")
        .header("HTTP-Referer", "https://github.com/Louis-CFM/coucou")
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v.pointer("/error/message").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(match status.as_u16() {
            401 => "OpenRouter rejected the API key (401). Check it in settings.".into(),
            402 => format!("OpenRouter: not enough credits (402). {detail}"),
            429 => format!("OpenRouter rate limit reached (429): {detail}. Free models have daily limits; try later or pick another model."),
            _ => format!("OpenRouter {status}: {detail}"),
        });
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub free: bool,
}

/// The public OpenRouter catalogue, text-output models only, free ones first.
/// No key needed for the list itself.
pub async fn list_models() -> Result<Vec<ModelInfo>, String> {
    let response = client(30)?
        .get(format!("{OPENROUTER_BASE}/models"))
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("OpenRouter models: HTTP {}", response.status()));
    }
    let json: Value = response.json().await.map_err(|e| e.to_string())?;
    let mut models: Vec<ModelInfo> = json
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|m| {
            m.pointer("/architecture/output_modalities")
                .and_then(Value::as_array)
                .map(|mods| mods.iter().any(|x| x.as_str() == Some("text")))
                .unwrap_or(true)
        })
        .filter_map(|m| {
            let id = m.get("id")?.as_str()?.to_string();
            let name = m.get("name").and_then(Value::as_str).unwrap_or(&id).to_string();
            let zero = |p: &str| m.pointer(p).and_then(Value::as_str).map(|v| v.parse::<f64>().ok() == Some(0.0)).unwrap_or(false);
            let free = id.ends_with(":free") || (zero("/pricing/prompt") && zero("/pricing/completion"));
            Some(ModelInfo { id, name, free })
        })
        .collect();
    models.sort_by(|a, b| b.free.cmp(&a.free).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    Ok(models)
}

/// Images → image_url data URL, text/code → inline text. PDFs and other binary
/// files are not sent (OpenAI-compatible APIs have no portable document part).
fn file_part(path: &str) -> Option<Value> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let len = std::fs::metadata(path).ok()?.len();
    let image = match ext.as_str() {
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    };
    if let Some(media) = image {
        if len > MAX_IMAGE {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        let url = format!("data:{media};base64,{}", crate::claude::base64_for(&bytes));
        return Some(json!({ "type": "image_url", "image_url": { "url": url } }));
    }
    if ext == "pdf" || len > MAX_INLINE_TEXT {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    Some(json!({ "type": "text", "text": format!("File contents:\n{text}") }))
}
