// Gemini through Google's native generateContent API, with Google Search
// grounding switched on, so the chat can answer about today: the weather, the
// news, a price, an opening time.
//
// The OpenAI-compatible endpoint (openai_compat.rs) carries no search tool,
// which is why Gemini goes this way and Gemma — which takes no tools — does
// not. The chat history stays in the OpenAI shape the rest of the app keeps;
// it is turned into Gemini's `contents` for each request.

use serde_json::{json, Value};

use crate::chat;
use crate::i18n::{t, tf};
use crate::openai_compat::{post_json, Auth, Provider};

const API_BASE: &str = "https://generativelanguage.googleapis.com/v1beta/models/";

/// Room for the answer and, on the 2.5 models, the thinking before it.
const MAX_OUTPUT_TOKENS: u32 = 8192;

/// Gemini models go through here; everything else keeps the OpenAI endpoint.
pub fn handles(p: &Provider, model: &str) -> bool {
    p.id == "google" && model.to_lowercase().starts_with("gemini")
}

/// One answer from Gemini, searching Google when the question needs it.
pub async fn reply(p: &Provider, model: &str, key: &str, history: &[Value], user: &Value) -> Result<String, String> {
    // The id lands in the URL path: only what a model id is ever made of.
    if model.is_empty() || !model.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_')) {
        return Err(tf("{name}: model not found (404). Pick another one above the chat box. {detail}", &[("name", p.name), ("detail", model)]));
    }
    let endpoint = reqwest::Url::parse(&format!("{API_BASE}{model}:generateContent")).map_err(|e| e.to_string())?;
    let body = request_body(&system_prompt(), history, user);
    let json = post_json(p, &endpoint, Auth::GoogApiKey(key), &body).await?;
    reply_text(p, &json)
}

/// Mochi's usual instructions in their web-search form, and the date, so
/// "today" and "this weekend" mean what the user means.
fn system_prompt() -> String {
    let now = crate::platform::local_time();
    format!(
        "{} Today's date is {:04}-{:02}-{:02}.",
        chat::system_prompt(true),
        now.year,
        now.month,
        now.day
    )
}

fn request_body(system: &str, history: &[Value], user: &Value) -> Value {
    let contents: Vec<Value> = history.iter().chain(std::iter::once(user)).map(to_content).collect();
    json!({
        "systemInstruction": { "parts": [{ "text": system }] },
        "contents": contents,
        "tools": [{ "google_search": {} }],
        "generationConfig": { "maxOutputTokens": MAX_OUTPUT_TOKENS },
    })
}

/// An OpenAI-shaped message (`role` + text or parts) as a Gemini content.
fn to_content(message: &Value) -> Value {
    let role = if message["role"] == "assistant" { "model" } else { "user" };
    let parts: Vec<Value> = match &message["content"] {
        Value::String(text) => vec![json!({ "text": text })],
        Value::Array(items) => items.iter().filter_map(to_part).collect(),
        _ => Vec::new(),
    };
    json!({ "role": role, "parts": parts })
}

fn to_part(item: &Value) -> Option<Value> {
    match item["type"].as_str()? {
        "text" => Some(json!({ "text": item["text"].as_str()? })),
        // A dropped picture: `data:<mime>;base64,<bytes>`.
        "image_url" => {
            let url = item.pointer("/image_url/url")?.as_str()?;
            let (mime, data) = url.strip_prefix("data:")?.split_once(";base64,")?;
            Some(json!({ "inline_data": { "mime_type": mime, "data": data } }))
        }
        _ => None,
    }
}

/// The answer's text, without the model's thoughts; or why there is none.
fn reply_text(p: &Provider, response: &Value) -> Result<String, String> {
    let text: String = response
        .pointer("/candidates/0/content/parts")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter(|part| part["thought"] != true)
                .filter_map(|part| part["text"].as_str())
                .collect()
        })
        .unwrap_or_default();
    let text = text.trim();
    if !text.is_empty() {
        return Ok(text.to_string());
    }
    if let Some(reason) = response.pointer("/promptFeedback/blockReason").and_then(Value::as_str) {
        return Err(format!("{}: {reason}", p.name));
    }
    if let Some(reason) = response.pointer("/candidates/0/finishReason").and_then(Value::as_str) {
        if reason != "STOP" {
            return Err(format!("{}: {reason}", p.name));
        }
    }
    if let Some(msg) = response.pointer("/error/message").and_then(Value::as_str) {
        return Err(format!("{}: {msg}", p.name));
    }
    Err(t("No response text."))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openai_compat::provider;

    #[test]
    fn only_gemini_on_google_searches() {
        let google = provider("google").unwrap();
        assert!(handles(google, "gemini-2.5-flash"));
        assert!(handles(google, "Gemini-3.5-Pro"));
        assert!(!handles(google, "gemma-4-31b-it"), "Gemma takes no tools");
        assert!(!handles(provider("openrouter").unwrap(), "gemini-2.5-flash"));
    }

    #[test]
    fn the_request_searches_and_carries_the_whole_conversation() {
        let history = vec![
            json!({"role":"user","content":"hi"}),
            json!({"role":"assistant","content":"hello"}),
        ];
        let user = json!({"role":"user","content":[
            {"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},
            {"type":"text","text":"what is this?"},
        ]});
        let body = request_body("sys", &history, &user);
        assert_eq!(body["tools"][0], json!({"google_search": {}}));
        assert_eq!(body["systemInstruction"]["parts"][0]["text"], "sys");
        let contents = body["contents"].as_array().unwrap();
        assert_eq!(contents.len(), 3);
        assert_eq!(contents[0], json!({"role":"user","parts":[{"text":"hi"}]}));
        assert_eq!(contents[1], json!({"role":"model","parts":[{"text":"hello"}]}));
        assert_eq!(contents[2]["parts"][0], json!({"inline_data":{"mime_type":"image/png","data":"AAAA"}}));
        assert_eq!(contents[2]["parts"][1], json!({"text":"what is this?"}));
    }

    #[test]
    fn the_prompt_claims_search_and_gives_the_date() {
        let prompt = system_prompt();
        assert!(prompt.contains("web search access"), "{prompt}");
        assert!(prompt.contains("Today's date is "), "{prompt}");
    }

    #[test]
    fn the_answer_is_read_without_thoughts_or_the_reason_given() {
        let p = provider("google").unwrap();
        let ok = json!({"candidates":[{"content":{"parts":[
            {"text":"thinking…","thought":true},
            {"text":"Sunny, "},
            {"text":"24 °C."},
        ]},"finishReason":"STOP"}]});
        assert_eq!(reply_text(p, &ok).unwrap(), "Sunny, 24 °C.");
        let blocked = json!({"promptFeedback":{"blockReason":"SAFETY"}});
        assert_eq!(reply_text(p, &blocked).unwrap_err(), "Google AI: SAFETY");
        let cut = json!({"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}]});
        assert_eq!(reply_text(p, &cut).unwrap_err(), "Google AI: MAX_TOKENS");
    }
}
