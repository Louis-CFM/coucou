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
    state: Mutex<Conversation>,
}

#[derive(Default)]
struct Conversation {
    messages: Vec<Value>,
    generation: u64,
    in_flight: bool,
}

impl Chat {
    pub fn reset(&self) {
        let mut state = self.state.lock().unwrap();
        state.messages.clear();
        state.generation = state.generation.wrapping_add(1);
        state.in_flight = false;
    }

    fn is_empty(&self) -> bool {
        self.state.lock().unwrap().messages.is_empty()
    }

    fn begin(&self, message: Value) -> Result<(u64, Vec<Value>), String> {
        let mut state = self.state.lock().unwrap();
        if state.in_flight {
            return Err("Claude is already answering. Wait or start a new chat.".into());
        }
        state.in_flight = true;
        state.messages.push(message);
        Ok((state.generation, state.messages.clone()))
    }

    fn rollback(&self, generation: u64) {
        let mut state = self.state.lock().unwrap();
        if state.generation == generation {
            state.messages.pop();
            state.in_flight = false;
        }
    }

    fn commit(&self, generation: u64, message: Value) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        if state.generation != generation {
            return Err("This reply belongs to a reset chat and was discarded.".into());
        }
        state.messages.push(message);
        state.in_flight = false;
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatContext {
    File {
        name: String,
        path: String,
    },
    Window {
        app_name: String,
        title: String,
        url: Option<String>,
    },
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
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get("anthropic-api-key")
        .ok_or_else(|| "API key missing. Open settings.".to_string())?;

    send_with_key(chat, model, query, context, &key, ENDPOINT).await
}

/// Keep the production credential and endpoint fixed in `send`; this private
/// seam lets the HTTP flow be exercised against a local mock server.
async fn send_with_key(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
    key: &str,
    endpoint: &str,
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
            Some(ChatContext::Window {
                app_name,
                title,
                url,
            }) => {
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

    let (generation, messages) = chat.begin(json!({ "role": "user", "content": content }))?;

    let body = json!({
        "model": model,
        "max_tokens": MAX_TOKENS,
        "system": SYSTEM_PROMPT,
        "tools": [{ "type": "web_search_20260209", "name": "web_search", "max_uses": 5 }],
        "fallbacks": "default",
        "messages": messages,
    });

    let response = match call(key, endpoint, &body).await {
        Ok(v) => v,
        Err(err) => {
            chat.rollback(generation); // never alter a newer conversation
            return Err(err);
        }
    };

    // A policy decline comes back as HTTP 200 with stop_reason "refusal".
    if response.get("stop_reason").and_then(Value::as_str) == Some("refusal") {
        chat.rollback(generation);
        let why = response
            .get("stop_details")
            .and_then(|d| d.get("explanation"))
            .and_then(Value::as_str)
            .unwrap_or("Claude declined this one.");
        return Err(why.to_string());
    }

    let Some(blocks) = response.get("content").and_then(Value::as_array).cloned() else {
        chat.rollback(generation);
        return Err("Unexpected API response.".into());
    };

    // Store the whole content — tool_use / tool_result blocks included — so the
    // next turn has the right context.

    let text = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();

    if text.is_empty() {
        chat.rollback(generation);
        return Err("No response text.".into());
    }
    chat.commit(
        generation,
        json!({ "role": "assistant", "content": blocks }),
    )?;
    Ok(ChatReply { text })
}

async fn call(key: &str, endpoint: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(endpoint)
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
    use super::{base64, send_with_key, Chat, ChatContext, ANTHROPIC_VERSION, FALLBACK_BETA};
    use serde_json::json;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::thread::{self, JoinHandle};

    struct MockRequest {
        headers: std::collections::HashMap<String, String>,
        body: serde_json::Value,
    }

    fn mock_server(
        responses: Vec<(u16, serde_json::Value)>,
    ) -> (String, JoinHandle<Vec<MockRequest>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            responses
                .into_iter()
                .map(|(status, response)| {
                    let (mut stream, _) = listener.accept().unwrap();
                    let request = read_request(&mut stream);
                    let body = serde_json::to_vec(&response).unwrap();
                    let reason = if status == 200 { "OK" } else { "Unauthorized" };
                    write!(
                        stream,
                        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                    stream.write_all(&body).unwrap();
                    request
                })
                .collect()
        });
        (endpoint, server)
    }

    fn read_request(stream: &mut TcpStream) -> MockRequest {
        let mut bytes = Vec::new();
        let mut chunk = [0_u8; 4096];
        let header_end = loop {
            let count = stream.read(&mut chunk).unwrap();
            assert_ne!(count, 0, "client closed before sending request headers");
            bytes.extend_from_slice(&chunk[..count]);
            if let Some(index) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                break index + 4;
            }
        };

        let header_text = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
        let headers = header_text
            .lines()
            .skip(1)
            .filter_map(|line| {
                let (name, value) = line.split_once(':')?;
                Some((name.trim().to_ascii_lowercase(), value.trim().to_string()))
            })
            .collect::<std::collections::HashMap<_, _>>();
        let content_length = headers
            .get("content-length")
            .unwrap()
            .parse::<usize>()
            .unwrap();
        while bytes.len() - header_end < content_length {
            let count = stream.read(&mut chunk).unwrap();
            assert_ne!(
                count, 0,
                "client closed before sending the full request body"
            );
            bytes.extend_from_slice(&chunk[..count]);
        }
        let body = serde_json::from_slice(&bytes[header_end..header_end + content_length]).unwrap();
        MockRequest { headers, body }
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

    #[test]
    fn reset_rejects_stale_rollback_and_commit_without_mutating_new_turn() {
        let chat = Chat::default();
        let stale_user = json!({ "role": "user", "content": "before reset" });
        let (stale_generation, _) = chat.begin(stale_user).unwrap();

        chat.reset();
        let current_user = json!({ "role": "user", "content": "after reset" });
        let (current_generation, messages) = chat.begin(current_user.clone()).unwrap();
        assert_ne!(stale_generation, current_generation);
        assert_eq!(messages, vec![current_user.clone()]);

        // An earlier request can finish after reset and after a new turn has
        // started. Its failure must not pop the new user's message or clear its
        // in-flight guard, and its successful response must not be committed.
        chat.rollback(stale_generation);
        assert!(chat
            .commit(
                stale_generation,
                json!({ "role": "assistant", "content": "stale reply" }),
            )
            .unwrap_err()
            .contains("reset chat"));
        {
            let state = chat.state.lock().unwrap();
            assert_eq!(state.messages, vec![current_user.clone()]);
            assert!(state.in_flight);
        }

        let current_assistant = json!({ "role": "assistant", "content": "current reply" });
        chat.commit(current_generation, current_assistant.clone())
            .unwrap();
        let state = chat.state.lock().unwrap();
        assert_eq!(state.messages, vec![current_user, current_assistant]);
        assert!(!state.in_flight);
    }

    #[test]
    fn begin_rejects_a_second_in_flight_request_and_rollback_releases_it() {
        let chat = Chat::default();
        let first_user = json!({ "role": "user", "content": "first" });
        let (generation, _) = chat.begin(first_user.clone()).unwrap();

        assert!(chat
            .begin(json!({ "role": "user", "content": "overlapping" }))
            .unwrap_err()
            .contains("already answering"));
        {
            let state = chat.state.lock().unwrap();
            assert_eq!(state.messages, vec![first_user]);
            assert!(state.in_flight);
        }

        chat.rollback(generation);
        let state = chat.state.lock().unwrap();
        assert!(state.messages.is_empty());
        assert!(!state.in_flight);
    }

    #[tokio::test]
    async fn send_posts_provider_headers_and_preserves_history_across_turns() {
        let assistant_blocks = json!([
            { "type": "text", "text": "I found the page." },
            { "type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": { "query": "Mochi" } },
            { "type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [{ "type": "web_search_result", "title": "Mochi", "url": "https://example.test/mochi" }] }
        ]);
        let (endpoint, server) = mock_server(vec![
            (
                200,
                json!({ "content": assistant_blocks, "stop_reason": "end_turn" }),
            ),
            (
                200,
                json!({ "content": [{ "type": "text", "text": "It describes Mochi." }], "stop_reason": "end_turn" }),
            ),
        ]);
        let chat = Chat::default();

        let first = send_with_key(
            &chat,
            "claude-test-model",
            "Find the Mochi page".into(),
            Some(ChatContext::Window {
                app_name: "Browser".into(),
                title: "Search tab".into(),
                url: Some("https://example.test".into()),
            }),
            "unit-test-key",
            &endpoint,
        )
        .await
        .unwrap();
        assert_eq!(first.text, "I found the page.");

        let second = send_with_key(
            &chat,
            "claude-test-model",
            "What does it say?".into(),
            None,
            "unit-test-key",
            &endpoint,
        )
        .await
        .unwrap();
        assert_eq!(second.text, "It describes Mochi.");

        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 2);
        for request in &requests {
            assert_eq!(request.headers.get("x-api-key").unwrap(), "unit-test-key");
            assert_eq!(
                request.headers.get("anthropic-version").unwrap(),
                ANTHROPIC_VERSION
            );
            assert_eq!(
                request.headers.get("anthropic-beta").unwrap(),
                FALLBACK_BETA
            );
            assert_eq!(
                request.headers.get("content-type").unwrap(),
                "application/json"
            );
            assert_eq!(request.body["model"], "claude-test-model");
            assert_eq!(request.body["max_tokens"], 4096);
        }

        assert_eq!(
            requests[0].body["messages"],
            json!([{
                "role": "user",
                "content": [
                    { "type": "text", "text": "Context — App: Browser, Window: Search tab, URL: https://example.test" },
                    { "type": "text", "text": "Find the Mochi page" }
                ]
            }])
        );
        assert_eq!(
            requests[1].body["messages"],
            json!([
                {
                    "role": "user",
                    "content": [
                        { "type": "text", "text": "Context — App: Browser, Window: Search tab, URL: https://example.test" },
                        { "type": "text", "text": "Find the Mochi page" }
                    ]
                },
                { "role": "assistant", "content": assistant_blocks },
                {
                    "role": "user",
                    "content": [{ "type": "text", "text": "What does it say?" }]
                }
            ])
        );
        let state = chat.state.lock().unwrap();
        assert_eq!(state.messages.len(), 4);
        assert!(!state.in_flight);
    }

    #[tokio::test]
    async fn send_rolls_back_user_message_after_api_error() {
        let (endpoint, server) = mock_server(vec![(
            401,
            json!({ "type": "error", "error": { "type": "authentication_error", "message": "invalid test key" } }),
        )]);
        let chat = Chat::default();

        let error = match send_with_key(
            &chat,
            "claude-test-model",
            "This request will fail".into(),
            None,
            "unit-test-key",
            &endpoint,
        )
        .await
        {
            Ok(_) => panic!("mock API failure should be returned to the caller"),
            Err(error) => error,
        };

        assert!(error.contains("Claude API 401"));
        assert!(error.contains("invalid test key"));
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 1);
        let state = chat.state.lock().unwrap();
        assert!(state.messages.is_empty());
        assert!(!state.in_flight);
    }
}
