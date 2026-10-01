// AI providers — presets, endpoint resolution and the OpenAI-compatible
// translation layer. claude.rs owns the conversation state (kept in Anthropic
// block format) and the system prompt; this module decides where each turn
// goes and how it is encoded on the wire.

use serde_json::{json, Value};

use crate::{secrets, settings::Settings};

const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Server-side fallback: on a policy decline the API retries the same request on
/// a fallback model inside the same call, so the island never shows a dead end.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ApiFormat {
    Anthropic,
    OpenAi,
}

impl ApiFormat {
    /// Only the custom preset stores a format string — anything but "anthropic"
    /// means OpenAI-compatible.
    pub fn parse(s: &str) -> Self {
        if s.eq_ignore_ascii_case("anthropic") {
            Self::Anthropic
        } else {
            Self::OpenAi
        }
    }
}

pub struct Preset {
    pub id: &'static str,
    /// Name shown in errors: "OpenRouter API 401: …".
    pub label: &'static str,
    /// Base URL used when settings.provider_url is empty; "" for custom.
    pub base_url: &'static str,
    pub format: ApiFormat,
    /// Credential Manager entry; None = no key needed (local server).
    pub secret: Option<&'static str>,
}

pub const PRESETS: &[Preset] = &[
    Preset {
        id: "anthropic",
        label: "Anthropic",
        base_url: "https://api.anthropic.com",
        format: ApiFormat::Anthropic,
        secret: Some("anthropic-api-key"),
    },
    Preset {
        id: "openai",
        label: "OpenAI",
        base_url: "https://api.openai.com",
        format: ApiFormat::OpenAi,
        secret: Some("openai-api-key"),
    },
    Preset {
        id: "openrouter",
        label: "OpenRouter",
        base_url: "https://openrouter.ai/api/v1",
        format: ApiFormat::OpenAi,
        secret: Some("openrouter-api-key"),
    },
    Preset {
        id: "groq",
        label: "Groq",
        base_url: "https://api.groq.com/openai/v1",
        format: ApiFormat::OpenAi,
        secret: Some("groq-api-key"),
    },
    Preset {
        id: "deepseek",
        label: "DeepSeek",
        base_url: "https://api.deepseek.com",
        format: ApiFormat::OpenAi,
        secret: Some("deepseek-api-key"),
    },
    Preset {
        id: "ollama",
        label: "Ollama",
        base_url: "http://localhost:11434",
        format: ApiFormat::OpenAi,
        secret: None,
    },
    Preset {
        id: "custom",
        label: "Custom",
        base_url: "",
        format: ApiFormat::OpenAi, // replaced by settings.provider_format
        secret: Some("custom-api-key"),
    },
];

/// An unknown or absent provider falls back to Anthropic, so a settings.json
/// written by an older build keeps working exactly as before.
pub fn preset(id: &str) -> &'static Preset {
    PRESETS.iter().find(|p| p.id == id).unwrap_or(&PRESETS[0])
}

pub struct Target {
    pub label: &'static str,
    /// Full chat endpoint, already normalized.
    pub url: String,
    pub format: ApiFormat,
    /// None → send no Authorization header (local servers).
    pub key: Option<String>,
}

/// Resolves everything a chat turn needs, reading the key from the
/// Credential Manager. The key never leaves the Rust side.
pub fn target(settings: &Settings) -> Result<Target, String> {
    let preset = preset(&settings.provider);
    let base = settings.provider_url.trim().trim_end_matches('/');
    let base = if base.is_empty() { preset.base_url } else { base };
    if base.is_empty() {
        return Err("Custom provider needs a base URL. Open settings.".into());
    }
    let format = if preset.id == "custom" {
        ApiFormat::parse(&settings.provider_format)
    } else {
        preset.format
    };
    let key = match preset.secret {
        None => None,
        Some(name) => {
            Some(secrets::get(name).ok_or_else(|| "API key missing. Open settings.".to_string())?)
        }
    };
    Ok(Target { label: preset.label, url: chat_url(base, format), format, key })
}

/// Adds the chat path to a base URL, tolerating the usual shapes: with or
/// without /v1, trailing slash, or even the full endpoint already typed in.
pub fn chat_url(base: &str, format: ApiFormat) -> String {
    let base = base.trim_end_matches('/');
    match format {
        ApiFormat::Anthropic => {
            if base.ends_with("/v1/messages") {
                base.into()
            } else if base.ends_with("/v1") {
                format!("{base}/messages")
            } else {
                format!("{base}/v1/messages")
            }
        }
        ApiFormat::OpenAi => {
            if base.ends_with("/chat/completions") {
                base.into()
            } else if base.ends_with("/v1") {
                format!("{base}/chat/completions")
            } else {
                format!("{base}/v1/chat/completions")
            }
        }
    }
}

/// Chat history in Anthropic blocks → a /chat/completions request body.
/// Images become image_url parts; PDF documents are rejected with a clear
/// message; tool_use blocks are dropped (web search is Anthropic-only).
pub fn openai_body(
    model: &str,
    system: &str,
    history: &[Value],
    max_tokens: u32,
) -> Result<Value, String> {
    let mut messages = vec![json!({ "role": "system", "content": system })];
    for message in history {
        let role = if message.get("role").and_then(Value::as_str) == Some("assistant") {
            "assistant"
        } else {
            "user"
        };
        let Some(blocks) = message.get("content").and_then(Value::as_array) else {
            // A plain string content — pass it through as-is.
            let text = message.get("content").and_then(Value::as_str).unwrap_or("");
            messages.push(json!({ "role": role, "content": text }));
            continue;
        };

        if role == "assistant" {
            let text = block_text(blocks);
            messages.push(json!({ "role": "assistant", "content": text }));
            continue;
        }
        if blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("document")) {
            return Err("PDF files are only supported with Anthropic.".into());
        }

        let has_image = blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("image"));
        if !has_image {
            messages.push(json!({ "role": "user", "content": block_text(blocks) }));
            continue;
        }
        let mut parts: Vec<Value> = Vec::new();
        for block in blocks {
            match block.get("type").and_then(Value::as_str) {
                Some("text") => {
                    let text = block.get("text").and_then(Value::as_str).unwrap_or("");
                    if !text.is_empty() {
                        parts.push(json!({ "type": "text", "text": text }));
                    }
                }
                Some("image") => {
                    let source = block.get("source");
                    let (Some(media), Some(data)) = (
                        source.and_then(|s| s.get("media_type")).and_then(Value::as_str),
                        source.and_then(|s| s.get("data")).and_then(Value::as_str),
                    ) else {
                        continue;
                    };
                    parts.push(json!({
                        "type": "image_url",
                        "image_url": { "url": format!("data:{media};base64,{data}") },
                    }));
                }
                _ => {}
            }
        }
        messages.push(json!({ "role": "user", "content": parts }));
    }
    Ok(json!({ "model": model, "max_tokens": max_tokens, "messages": messages }))
}

/// Concatenates the text blocks, dropping tool_use and anything else.
fn block_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// choices[0].message.content as a String — the content may be a plain string
/// or, on some providers, an array of parts.
pub fn openai_text(response: &Value) -> Option<String> {
    let content = response
        .get("choices")?
        .get(0)?
        .get("message")?
        .get("content")?;
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(parts) => Some(
            parts
                .iter()
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        _ => None,
    }
}

/// Readable error message for both API families.
pub fn error_detail(body_text: &str) -> String {
    if let Ok(v) = serde_json::from_str::<Value>(body_text) {
        // {"error": {"message": "…"}} — Anthropic, OpenAI, OpenRouter, Groq, DeepSeek.
        if let Some(error) = v.get("error") {
            if let Some(s) = error.get("message").and_then(Value::as_str) {
                return s.to_string();
            }
            if let Some(s) = error.as_str() {
                return s.to_string(); // Ollama: {"error": "…"}
            }
        }
        if let Some(s) = v.get("message").and_then(Value::as_str) {
            return s.to_string();
        }
    }
    body_text.chars().take(200).collect()
}

/// POST with the headers each family expects. 90 s timeout, as before.
pub async fn post(target: &Target, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let mut request = client
        .post(&target.url)
        .header("content-type", "application/json")
        .json(body);
    match target.format {
        ApiFormat::Anthropic => {
            request = request
                .header("x-api-key", target.key.as_deref().unwrap_or(""))
                .header("anthropic-version", ANTHROPIC_VERSION)
                .header("anthropic-beta", FALLBACK_BETA);
        }
        ApiFormat::OpenAi => {
            if let Some(key) = &target.key {
                request = request.header("authorization", format!("Bearer {key}"));
            }
        }
    }

    let response = request
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        // Surface the API's own message, which is what makes a bad key obvious.
        return Err(format!("{} API {status}: {}", target.label, error_detail(&text)));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_url_adds_the_right_path() {
        assert_eq!(
            chat_url("https://api.anthropic.com", ApiFormat::Anthropic),
            "https://api.anthropic.com/v1/messages"
        );
        assert_eq!(
            chat_url("https://api.anthropic.com/v1", ApiFormat::Anthropic),
            "https://api.anthropic.com/v1/messages"
        );
        assert_eq!(
            chat_url("https://api.anthropic.com/v1/messages", ApiFormat::Anthropic),
            "https://api.anthropic.com/v1/messages"
        );
        assert_eq!(
            chat_url("https://proxy.example.com/", ApiFormat::Anthropic),
            "https://proxy.example.com/v1/messages"
        );

        assert_eq!(
            chat_url("https://api.openai.com", ApiFormat::OpenAi),
            "https://api.openai.com/v1/chat/completions"
        );
        assert_eq!(
            chat_url("https://api.openai.com/v1/", ApiFormat::OpenAi),
            "https://api.openai.com/v1/chat/completions"
        );
        assert_eq!(
            chat_url("https://openrouter.ai/api/v1", ApiFormat::OpenAi),
            "https://openrouter.ai/api/v1/chat/completions"
        );
        assert_eq!(
            chat_url("https://api.groq.com/openai/v1", ApiFormat::OpenAi),
            "https://api.groq.com/openai/v1/chat/completions"
        );
        assert_eq!(
            chat_url("http://localhost:11434", ApiFormat::OpenAi),
            "http://localhost:11434/v1/chat/completions"
        );
        assert_eq!(
            chat_url("http://localhost:11434/v1/chat/completions", ApiFormat::OpenAi),
            "http://localhost:11434/v1/chat/completions"
        );
    }

    #[test]
    fn openai_body_translates_a_text_only_history() {
        let history = vec![
            json!({ "role": "user", "content": [{ "type": "text", "text": "hi" }] }),
            json!({ "role": "assistant", "content": [
                { "type": "text", "text": "hello" },
                { "type": "tool_use", "id": "t1", "name": "web_search", "input": {} },
            ] }),
        ];
        let body = openai_body("m", "sys", &history, 100).unwrap();
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[0]["content"], "sys");
        assert_eq!(messages[1]["role"], "user");
        assert_eq!(messages[1]["content"], "hi");
        assert_eq!(messages[2]["role"], "assistant");
        assert_eq!(messages[2]["content"], "hello"); // tool_use dropped
        assert_eq!(body["max_tokens"], json!(100));
    }

    #[test]
    fn openai_body_maps_images_to_image_url_parts() {
        let history = vec![json!({ "role": "user", "content": [
            { "type": "image", "source": { "type": "base64", "media_type": "image/png", "data": "AAA" } },
            { "type": "text", "text": "what is this?" },
        ] })];
        let body = openai_body("m", "sys", &history, 100).unwrap();
        let content = body["messages"][1]["content"].as_array().unwrap();
        assert_eq!(content[0]["type"], "image_url");
        assert_eq!(content[0]["image_url"]["url"], "data:image/png;base64,AAA");
        assert_eq!(content[1], json!({ "type": "text", "text": "what is this?" }));
    }

    #[test]
    fn openai_body_rejects_pdfs() {
        let history = vec![json!({ "role": "user", "content": [
            { "type": "document", "source": { "type": "base64", "media_type": "application/pdf", "data": "AAA" } },
        ] })];
        assert_eq!(
            openai_body("m", "sys", &history, 100).unwrap_err(),
            "PDF files are only supported with Anthropic."
        );
    }

    #[test]
    fn error_detail_reads_every_shape() {
        assert_eq!(error_detail(r#"{"error":{"message":"bad key"}}"#), "bad key");
        assert_eq!(error_detail(r#"{"error":"model not found"}"#), "model not found");
        assert_eq!(error_detail(r#"{"message":"nope"}"#), "nope");
        assert_eq!(error_detail("plain text"), "plain text");
        let long = "x".repeat(300);
        assert_eq!(error_detail(&long).chars().count(), 200);
    }
}
