// Claude API client — the same integration as ClaudeService.swift: multi-turn
// chat with web search, and files sent as document/image/text blocks.
//
// Everything happens here rather than in the island: the API key never leaves
// the credential store, and file bytes never cross the IPC boundary.
//
// COUCOU_ANTHROPIC_BASE_URL points the chat at an Anthropic-compatible gateway
// instead (issue #180). Only that variable is read: Claude Code's own
// ANTHROPIC_BASE_URL may name a proxy the user never meant to hand this key to.

use std::sync::OnceLock;
use std::time::Duration;

use reqwest::Url;
use serde_json::{json, Value};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::i18n::{t, tf};
use crate::{net, secrets};

/// Credential store entry of the Anthropic API key.
pub const KEY: &str = "anthropic-api-key";
const DEFAULT_ENDPOINT: &str = "https://api.anthropic.com/v1/messages";
const BASE_URL_VAR: &str = "COUCOU_ANTHROPIC_BASE_URL";
const ANTHROPIC_VERSION: &str = "2023-06-01";
/// Server-side fallback: on a policy decline the API retries the same request on
/// a fallback model inside the same call, so the island never shows a dead end.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const MAX_TOKENS: u32 = 4096;
/// Text and code files are inlined; anything larger is skipped, as on macOS.
const MAX_INLINE_TEXT: u64 = 200_000;

pub const DEFAULT_MODEL: &str = "claude-opus-5";

/// The Messages endpoint: Anthropic's, or the gateway in COUCOU_ANTHROPIC_BASE_URL.
/// Read once; the gateway's host (never the key) goes to the log once.
fn endpoint() -> Result<Url, String> {
    static ENDPOINT: OnceLock<Result<Url, String>> = OnceLock::new();
    ENDPOINT
        .get_or_init(|| {
            let raw = std::env::var(BASE_URL_VAR)
                .ok()
                .filter(|v| !v.trim().is_empty());
            let resolved = match raw {
                None => Ok(Url::parse(DEFAULT_ENDPOINT).expect("valid default endpoint")),
                Some(raw) => net::anthropic_endpoint(&raw),
            };
            match &resolved {
                Ok(url) if url.as_str() != DEFAULT_ENDPOINT => crate::log::line(format!(
                    "chat: Claude requests go to {} ({BASE_URL_VAR})",
                    net::host_for_log(url)
                )),
                Err(err) => crate::log::line(format!("chat: {err}")),
                _ => {}
            }
            resolved
        })
        .clone()
}

/// The model list endpoint next to the Messages one.
fn models_endpoint(messages: &Url) -> Url {
    let mut url = messages.clone();
    let path = url.path().trim_end_matches("/messages").to_string();
    url.set_path(&format!("{path}/models"));
    url.set_query(Some("limit=100"));
    url
}

/// The user's content blocks for one turn. File / window context rides along
/// with the first message only, exactly like ClaudeService.chat().
fn user_content(first: bool, context: Option<&ChatContext>, query: &str) -> Vec<Value> {
    let mut content: Vec<Value> = Vec::new();
    if first {
        match context {
            Some(ChatContext::File { name, path }) => {
                if let Some(block) = file_block(path) {
                    content.push(block);
                }
                content.push(json!({ "type": "text", "text": format!("File: {name}") }));
            }
            Some(ChatContext::Window {
                app_name,
                title,
                url,
            }) => {
                let line = chat::window_line(app_name, title, url.as_deref());
                content.push(json!({ "type": "text", "text": line }));
            }
            None => {}
        }
    }
    content.push(json!({ "type": "text", "text": query }));
    content
}

fn request_body(model: &str, system: &str, history: &[Value], user: &Value) -> Value {
    let mut messages = history.to_vec();
    messages.push(user.clone());
    json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": system,
        "tools": [{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }],
        "fallbacks": "default",
        "messages": messages,
    })
}

/// The assistant's full text from a Messages API content array — the same as
/// claudeResponseText() on the Mac (#67). Web search answers interleave text
/// with tool blocks, and citations split a sentence across adjacent text
/// blocks: every text block is kept, joined as is, and only the whole trimmed.
pub fn response_text(content: &[Value]) -> Option<String> {
    let text: String = content
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect();
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// The content blocks to keep in the history and the text to show, or why there are none.
fn interpret(response: &Value) -> Result<(Vec<Value>, String), String> {
    // A policy decline comes back as HTTP 200 with stop_reason "refusal".
    if response.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        let why = response
            .pointer("/stop_details/explanation")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| t("Claude declined this one."));
        return Err(why);
    }
    let blocks = response
        .get("content")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(|| t("Unexpected API response."))?;
    let text = response_text(&blocks).ok_or_else(|| t("No response text."))?;
    Ok((blocks, text))
}

/// One chat turn. Returns the assistant's text, or a message the island shows
/// in the note view.
pub async fn send(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get(KEY).ok_or_else(|| t("API key missing. Open settings."))?;
    let endpoint = endpoint()?;

    let turn = chat.begin(chat::ANTHROPIC);
    let user =
        json!({ "role": "user", "content": user_content(turn.first, context.as_ref(), &query) });
    let body = request_body(model, &chat::system_prompt(true), &turn.history, &user);

    let response = call(&endpoint, &key, &body).await?;
    let (blocks, text) = interpret(&response)?;

    // Store the whole content — tool_use / tool_result blocks included — so the
    // next turn has the right context.
    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(
        &turn,
        user,
        json!({ "role": "assistant", "content": blocks }),
        &plain,
        &text,
    );
    Ok(ChatReply { text })
}

async fn call(endpoint: &Url, key: &str, body: &Value) -> Result<Value, String> {
    let response = net::client(endpoint, Duration::from_secs(90))?
        .post(endpoint.clone())
        .header("x-api-key", key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .header("anthropic-beta", FALLBACK_BETA)
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| tf("Network error: {error}", &[("error", &e.to_string())]))?;

    let status = response.status();
    if !status.is_success() {
        // Surface the API's own message, which is what makes a bad key obvious.
        let body = net::read_capped(response, net::MAX_ERROR_BODY)
            .await
            .unwrap_or_default();
        return Err(format!("Claude API {status}: {}", net::error_detail(&body)));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    serde_json::from_slice(&bytes)
        .map_err(|e| tf("Bad API response: {error}", &[("error", &e.to_string())]))
}

/// The models on the user's Anthropic account, newest first, as the API lists them.
pub async fn models(key: &str) -> Result<Vec<ModelInfo>, String> {
    let url = models_endpoint(&endpoint()?);
    let response = net::client(&url, Duration::from_secs(10))?
        .get(url.clone())
        .header("x-api-key", key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .send()
        .await
        .map_err(|e| tf("Network error: {error}", &[("error", &e.to_string())]))?;
    let status = response.status();
    if !status.is_success() {
        let body = net::read_capped(response, net::MAX_ERROR_BODY)
            .await
            .unwrap_or_default();
        return Err(format!("Claude API {status}: {}", net::error_detail(&body)));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    let json: Value = serde_json::from_slice(&bytes).map_err(|_| t("Unexpected API response."))?;
    Ok(parse_models(&json))
}

fn parse_models(json: &Value) -> Vec<ModelInfo> {
    json.get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let id = m.get("id")?.as_str()?.to_string();
            let label = m
                .get("display_name")
                .and_then(Value::as_str)
                .unwrap_or(&id)
                .to_string();
            Some(ModelInfo { id, label })
        })
        .collect()
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
/// Also used for Stripe's basic auth and the images sent to other providers.
pub(crate) fn base64_for(bytes: &[u8]) -> String {
    base64(bytes)
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[n as usize & 63] as char
        } else {
            '='
        });
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

    fn texts(parts: &[&str]) -> Vec<Value> {
        parts
            .iter()
            .map(|t| json!({ "type": "text", "text": t }))
            .collect()
    }

    #[test]
    fn every_text_block_is_kept_in_order_without_added_separators() {
        assert_eq!(
            response_text(&texts(&["Simple answer."])).as_deref(),
            Some("Simple answer.")
        );
        let content = vec![
            json!({"type":"text","text":"I'll look that up.\n"}),
            json!({"type":"server_tool_use","id":"srvtoolu_01","name":"web_search","input":{"query":"test"}}),
            json!({"type":"web_search_tool_result","tool_use_id":"srvtoolu_01","content":[]}),
            json!({"type":"text","text":"The answer is 42."}),
        ];
        assert_eq!(
            response_text(&content).as_deref(),
            Some("I'll look that up.\nThe answer is 42.")
        );
        // An empty leading block does not hide the answer.
        let content = vec![
            json!({"type":"text","text":""}),
            json!({"type":"web_search_tool_result","tool_use_id":"b","content":[]}),
            json!({"type":"text","text":"Here is the actual answer."}),
        ];
        assert_eq!(
            response_text(&content).as_deref(),
            Some("Here is the actual answer.")
        );
        // Citations split a sentence across blocks: no newline is inserted.
        assert_eq!(
            response_text(&texts(&["Paris is the ", "capital", " of France."])).as_deref(),
            Some("Paris is the capital of France.")
        );
        // Search result text never leaks into the answer.
        let content = vec![
            json!({"type":"text","text":"Answer."}),
            json!({"type":"web_search_tool_result","tool_use_id":"a","content":[{"type":"web_search_result","title":"Page","text":"Leak"}]}),
        ];
        assert_eq!(response_text(&content).as_deref(), Some("Answer."));
        assert_eq!(
            response_text(&[json!({"type":"server_tool_use","id":"x"})]),
            None
        );
        assert_eq!(response_text(&texts(&["", "  \n"])), None);
    }

    #[test]
    fn a_refusal_or_an_empty_answer_is_an_error() {
        let refusal = json!({"stop_reason":"refusal","stop_details":{"explanation":"Not this."},"content":[]});
        assert_eq!(interpret(&refusal).unwrap_err(), "Not this.");
        assert_eq!(
            interpret(&json!({"stop_reason":"refusal"})).unwrap_err(),
            "Claude declined this one."
        );
        assert_eq!(
            interpret(&json!({"id":"x"})).unwrap_err(),
            "Unexpected API response."
        );
        assert_eq!(
            interpret(&json!({"content":[]})).unwrap_err(),
            "No response text."
        );
        let (blocks, text) =
            interpret(&json!({"content":[{"type":"text","text":" Hi "}]})).unwrap();
        assert_eq!(text, "Hi");
        assert_eq!(blocks.len(), 1);
    }

    #[test]
    fn the_request_carries_history_web_search_and_the_new_turn_last() {
        let history = vec![
            json!({"role":"user","content":"a"}),
            json!({"role":"assistant","content":"b"}),
        ];
        let user = json!({"role":"user","content":[{"type":"text","text":"c"}]});
        let body = request_body("claude-x", "sys", &history, &user);
        assert_eq!(body["model"], "claude-x");
        assert_eq!(body["system"], "sys");
        assert_eq!(body["max_tokens"], MAX_TOKENS);
        assert_eq!(body["tools"][0]["name"], "web_search");
        assert_eq!(body["messages"].as_array().unwrap().len(), 3);
        assert_eq!(body["messages"][2], user);
    }

    #[test]
    fn context_is_sent_with_the_first_turn_only() {
        let ctx = ChatContext::Window {
            app_name: "Edge".into(),
            title: "Docs".into(),
            url: Some("https://x.dev".into()),
        };
        let first = user_content(true, Some(&ctx), "q");
        assert_eq!(first.len(), 2);
        assert_eq!(
            first[0]["text"],
            "Context — App: Edge, Window: Docs, URL: https://x.dev"
        );
        assert_eq!(
            user_content(false, Some(&ctx), "q"),
            vec![json!({"type":"text","text":"q"})]
        );
        // A file that cannot be read still names itself.
        let ctx = ChatContext::File {
            name: "gone.pdf".into(),
            path: "/no/such/gone.pdf".into(),
        };
        assert_eq!(
            user_content(true, Some(&ctx), "q")[0]["text"],
            "File: gone.pdf"
        );
    }

    #[test]
    fn the_model_list_sits_next_to_the_messages_endpoint() {
        let url = Url::parse(DEFAULT_ENDPOINT).unwrap();
        assert_eq!(
            models_endpoint(&url).as_str(),
            "https://api.anthropic.com/v1/models?limit=100"
        );
        let url = net::anthropic_endpoint("https://gw.example.com/anthropic").unwrap();
        assert_eq!(
            models_endpoint(&url).as_str(),
            "https://gw.example.com/anthropic/v1/models?limit=100"
        );
        let list = json!({"data":[{"id":"claude-opus-5","display_name":"Claude Opus 5"},{"id":"claude-x"},{"nope":1}]});
        assert_eq!(
            parse_models(&list),
            vec![
                ModelInfo {
                    id: "claude-opus-5".into(),
                    label: "Claude Opus 5".into()
                },
                ModelInfo {
                    id: "claude-x".into(),
                    label: "claude-x".into()
                },
            ]
        );
    }
}
