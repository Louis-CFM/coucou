// Claude API client — the same integration as ClaudeService.swift: multi-turn
// chat with web search, and files sent as document/image/text blocks.
//
// Everything happens here rather than in the island: the API key never leaves
// the Credential Manager, and file bytes never cross the IPC boundary.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{log, secrets};

const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Server-side fallback: on a policy decline the API retries the same request on
/// a fallback model inside the same call, so the island never shows a dead end.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const MAX_TOKENS: u32 = 4096;
/// Text and code files are inlined; anything larger is skipped, as on macOS.
const MAX_INLINE_TEXT: u64 = 200_000;

pub const DEFAULT_MODEL: &str = "claude-opus-5";

/// Follows "You are <name>, " (see `system_prompt`).
const SYSTEM_PROMPT: &str = "a personal AI assistant living at the top of the user's screen. \
You have web search access and can help with absolutely anything: research, coding, finding places, recommendations, tasks, questions. \
Respond in the user's language. Be thorough and complete, with as much detail as the task requires. \
Format with Markdown: short paragraphs, lists where they help, code in backticks or fenced blocks. \
Put the key words and phrases the user should notice in **bold** (a few per answer, never whole sentences). \
End every reply with one last line holding only a JSON object with how you feel about it, for your avatar to act out, \
exactly like {\"mood\":\"happy\"}. Pick one of: happy, sad, shy, angry, thankful, welcome, scared, celebration, surprised, proud. \
Write nothing after that line and never mention it.";

/// The moods the avatar can act out (see the end of SYSTEM_PROMPT).
const MOODS: [&str; 10] =
    ["happy", "sad", "shy", "angry", "thankful", "welcome", "scared", "celebration", "surprised", "proud"];

/// Splits the trailing `{"mood": "…"}` off a reply. Tolerates a code fence
/// around it and stray whitespace; an unknown or missing mood leaves the text
/// as it is.
pub fn take_mood(text: &str) -> (String, Option<String>) {
    let Some(start) = text.rfind('{') else { return (text.to_string(), None) };
    let tail = text[start..].trim().trim_end_matches('`').trim();
    let Ok(value) = serde_json::from_str::<Value>(tail) else { return (text.to_string(), None) };
    let Some(mood) = value.get("mood").and_then(Value::as_str).map(str::to_lowercase) else {
        return (text.to_string(), None);
    };
    if !MOODS.contains(&mood.as_str()) {
        return (text.to_string(), None);
    }
    let body = text[..start].trim_end();
    let body = body.strip_suffix("```json").or_else(|| body.strip_suffix("```")).unwrap_or(body).trim_end();
    (body.to_string(), Some(mood))
}

/// The system prompt, with the name the user gave Mochi in Settings.
fn system_prompt(name: &str) -> String {
    let name: String = name.trim().chars().take(32).collect();
    let name = if name.is_empty() { "Mochi".to_string() } else { name };
    format!("You are {name}, {SYSTEM_PROMPT}")
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
    /// Something the user should know about how this answer was made, e.g. the
    /// image was left out.
    pub notice: Option<String>,
    /// An image went to the model (and it answered): it can see images.
    pub sent_image: bool,
    /// How the model felt about its answer, for Mochi to act out.
    pub mood: Option<String>,
    /// Images, video or speech the model made (see media.rs).
    pub media: Vec<crate::media::MediaFile>,
}

/// The error a text-only model's image refusal is reported as, so the island
/// can ask whether to send without the image instead of wasting a request.
pub const IMAGES_UNSUPPORTED: &str = "IMAGES_UNSUPPORTED";

/// Where a chat turn goes: the Claude API, or any OpenAI-compatible
/// `/chat/completions` endpoint, with the Credential Manager name of its key.
pub enum Provider {
    Claude { model: String },
    Custom { endpoint: String, model: String, key: String },
}

fn is_image(path: &str) -> bool {
    let ext = std::path::Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "gif" | "webp")
}

/// One chat turn. Returns the assistant's text, or a message the island shows
/// in the note view.
pub async fn send(
    chat: &Chat,
    provider: &Provider,
    name: &str,
    query: String,
    context: Option<ChatContext>,
    text_only: bool,
) -> Result<ChatReply, String> {
    let system = system_prompt(name);
    let key = match provider {
        Provider::Claude { .. } => secrets::get("anthropic-api-key"),
        // The older single custom key still works for any provider.
        Provider::Custom { key, .. } => secrets::get(key).or_else(|| secrets::get("custom-api-key")),
    }
    .ok_or_else(|| "No API key for this model's provider yet. Add it in Settings → Models.".to_string())?;

    let mut content: Vec<Value> = Vec::new();

    // File / window context rides along with the first message only, exactly
    // like ClaudeService.chat().
    if chat.is_empty() {
        match &context {
            Some(ChatContext::File { name, path }) => {
                if text_only && is_image(path) {
                    content.push(json!({ "type": "text", "text": format!("[An image ({name}) was attached, but the user chose to send text only.]") }));
                } else if let Some(block) = file_block(path) {
                    content.push(block);
                }
                content.push(json!({ "type": "text", "text": format!("File: {name}") }));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                let mut text = format!("Context. App: {app_name}, Window: {title}");
                if let Some(url) = url {
                    text.push_str(&format!(", URL: {url}"));
                }
                content.push(json!({ "type": "text", "text": text }));
            }
            None => {}
        }
    }
    content.push(json!({ "type": "text", "text": query }));

    let sent_image = content.iter().any(|b| b["type"] == "image");
    let left_out = text_only && matches!(&context, Some(ChatContext::File { path, .. }) if is_image(path));
    chat.push(json!({ "role": "user", "content": content }));
    let notice = left_out.then(|| "Sent without the image.".to_string());

    let model = match provider {
        Provider::Claude { model } => model,
        Provider::Custom { endpoint, model, .. } => {
            return match call_openai(&key, endpoint, model, &system, &chat.snapshot(), sent_image).await {
                Ok(text) => {
                    // Stored in the Claude shape so switching provider mid-chat still works.
                    chat.push(json!({ "role": "assistant", "content": [{ "type": "text", "text": text }] }));
                    let (text, mood) = take_mood(&text);
                    Ok(ChatReply { text, notice, sent_image, mood, media: Vec::new() })
                }
                Err(err) => {
                    chat.pop();
                    Err(err)
                }
            };
        }
    };

    let body = json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": system,
        "tools": [{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }],
        "fallbacks": "default",
        "messages": chat.snapshot(),
    });

    let response = match call(&key, &body).await {
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

    let Some(blocks) = response.get("content").and_then(Value::as_array).cloned() else {
        chat.pop();
        return Err("Unexpected API response.".into());
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
    let (text, mood) = take_mood(&text);
    Ok(ChatReply { text, notice, sent_image, mood, media: Vec::new() })
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

/// One OpenAI-compatible turn (no web search: that tool is Claude-only). Many
/// models (most of Groq's, for one) take text only and reject an image outright
/// with a 4xx: that comes back as IMAGES_UNSUPPORTED, so the island can ask
/// before sending again without it.
async fn call_openai(
    key: &str,
    endpoint: &str,
    model: &str,
    system: &str,
    history: &[Value],
    with_image: bool,
) -> Result<String, String> {
    if model.trim().is_empty() {
        return Err("This model has no model name. Fix it in Settings → Models.".into());
    }
    let base = endpoint.trim().trim_end_matches('/');
    let url = if base.ends_with("/chat/completions") {
        base.to_string()
    } else {
        format!("{base}/chat/completions")
    };

    let mut messages = vec![json!({ "role": "system", "content": system })];
    messages.extend(history.iter().map(|m| to_openai(m, true)));
    let body = json!({ "model": model.trim(), "max_tokens": MAX_TOKENS, "messages": messages });

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .post(&url)
        .bearer_auth(key)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    let parsed: Option<Value> = serde_json::from_str(&text).ok();
    if !status.is_success() {
        let detail = api_detail(&text);
        if with_image && matches!(status.as_u16(), 400 | 415 | 422) {
            log::line(format!("custom provider refused the image: {status} {detail}"));
            return Err(IMAGES_UNSUPPORTED.into());
        }
        return Err(friendly_error(status.as_u16(), &detail, model));
    }
    let reply = parsed
        .as_ref()
        .and_then(|v| v.pointer("/choices/0/message/content"))
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    if reply.is_empty() {
        return Err("No response text.".into());
    }
    Ok(reply.to_string())
}

/// The provider's own error message out of an error body. OpenRouter:
/// {error:{message}}; NIM: {detail} or {error:"..."}; anything else: the start
/// of the body.
pub(crate) fn api_detail(text: &str) -> String {
    serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| {
            v.pointer("/error/message")
                .or_else(|| v.get("error"))
                .or_else(|| v.get("detail"))
                .map(|d| d.as_str().map(str::to_string).unwrap_or_else(|| d.to_string()))
        })
        .unwrap_or_else(|| text.chars().take(200).collect())
}

/// An API failure in words a non-technical user can act on. The raw detail is
/// kept at the end for anyone who needs it.
pub(crate) fn friendly_error(status: u16, detail: &str, model: &str) -> String {
    let hint = match status {
        401 | 403 => "The API key was refused. Check it in Settings.".to_string(),
        404 => format!("The model \"{}\" wasn't found at this provider. Check the model name in Settings.", model.trim()),
        413 => "That was too much to send at once. Try a shorter message or a smaller file.".to_string(),
        429 => "The provider is rate-limiting you. Wait a moment and try again.".to_string(),
        500..=599 => "The provider is having trouble right now. Try again in a moment.".to_string(),
        _ => "The provider couldn't handle that request.".to_string(),
    };
    format!("{hint}\n\n({status}: {detail})")
}

/// One Claude-shaped history message → OpenAI shape. Text-only turns become a
/// plain string (the most widely supported form); images become data URLs, or
/// a note that one was attached when `images` is false (text-only models);
/// PDFs and tool blocks have no portable equivalent and are dropped.
fn to_openai(message: &Value, images: bool) -> Value {
    let role = message.get("role").and_then(Value::as_str).unwrap_or("user");
    let blocks = message.get("content").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut parts = Vec::new();
    let mut has_image = false;
    for b in &blocks {
        match b.get("type").and_then(Value::as_str) {
            Some("text") => parts.push(json!({ "type": "text", "text": b["text"] })),
            Some("image") if role == "user" && !images => {
                parts.push(json!({ "type": "text", "text": "[The user attached an image here, but you can't see images. If the question depends on it, say so briefly.]" }))
            }
            Some("image") if role == "user" => {
                has_image = true;
                let src = &b["source"];
                let url = format!(
                    "data:{};base64,{}",
                    src["media_type"].as_str().unwrap_or(""),
                    src["data"].as_str().unwrap_or("")
                );
                parts.push(json!({ "type": "image_url", "image_url": { "url": url } }));
            }
            Some("document") => {
                parts.push(json!({ "type": "text", "text": "[PDF attached, but this provider can not read PDFs]" }))
            }
            _ => {}
        }
    }
    if has_image {
        return json!({ "role": role, "content": parts });
    }
    let text = parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n");
    json!({ "role": role, "content": text })
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

    let (text, lang) = read_text(path)?;
    // As Markdown, so the model reads it as code in the right language.
    Some(json!({ "type": "text", "text": format!("```{lang}\n{}\n```", text.trim_end()) }))
}

/// A text or code file's contents and its Markdown language name, if it is
/// small enough to inline and really text.
pub fn read_text(path: &str) -> Option<(String, String)> {
    if std::fs::metadata(path).ok()?.len() > MAX_INLINE_TEXT {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    if text.contains('\0') {
        return None;
    }
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let lang = match ext.as_str() {
        "rs" => "rust",
        "py" => "python",
        "js" | "mjs" | "cjs" => "javascript",
        "ts" | "mts" | "cts" => "typescript",
        "tsx" => "tsx",
        "jsx" => "jsx",
        "ps1" | "psm1" => "powershell",
        "bat" | "cmd" => "batch",
        "sh" | "bash" | "zsh" => "bash",
        "cs" => "csharp",
        "cpp" | "cc" | "cxx" | "hpp" | "hh" => "cpp",
        "h" => "c",
        "kt" | "kts" => "kotlin",
        "rb" => "ruby",
        "yml" => "yaml",
        "md" => "markdown",
        "txt" | "log" => "",
        other => other,
    };
    Some((text, lang.to_string()))
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
    use super::{base64, to_openai};
    use serde_json::json;

    #[test]
    fn to_openai_flattens_text_and_maps_images() {
        let text = json!({ "role": "assistant", "content": [
            { "type": "text", "text": "a" }, { "type": "web_search_tool_result" }, { "type": "text", "text": "b" } ] });
        assert_eq!(to_openai(&text, true), json!({ "role": "assistant", "content": "a\nb" }));

        let img = json!({ "role": "user", "content": [
            { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": "QQ==" } },
            { "type": "text", "text": "hi" } ] });
        assert_eq!(to_openai(&img, true)["content"][0]["image_url"]["url"], "data:image/png;base64,QQ==");
        assert_eq!(to_openai(&img, true)["content"][1]["text"], "hi");
        // Text-only models get one plain string that mentions the image.
        let blind = to_openai(&img, false);
        assert!(blind["content"].is_string());
        assert!(blind["content"].as_str().unwrap().contains("attached an image"));
    }

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

#[cfg(test)]
mod mood_tests {
    use super::take_mood;

    #[test]
    fn trailing_mood_is_split_off() {
        assert_eq!(take_mood("Done!\n{\"mood\":\"happy\"}"), ("Done!".into(), Some("happy".into())));
        assert_eq!(
            take_mood("Hi\n\n```json\n{ \"mood\": \"Thankful\" }\n```\n"),
            ("Hi".into(), Some("thankful".into()))
        );
        // Unknown mood, or JSON that is the answer itself: left alone.
        assert_eq!(take_mood("x {\"mood\":\"bored\"}").1, None);
        assert_eq!(take_mood("Use {\"a\": 1} here.").1, None);
        assert_eq!(take_mood("No mood at all").0, "No mood at all");
    }
}
