// Chat with a model running on the user's own machine (Ollama, LM Studio) — the same
// integration as LocalChat.swift: any server that speaks the OpenAI API. Those two
// need no key; "OpenAI-compatible" is the same for any other such server (Unsloth,
// vLLM, llama.cpp…), with an optional key.
//
// The answer is streamed token by token. Each step goes to the island as a
// `chat-delta` event carrying the text visible so far, and the island shows it
// growing; the reply of the command is the finished text.
//
// Nothing leaves the machine unless the user pointed the server address somewhere
// else: that address is the only place this module talks to.

use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::claude::{system_prompt, Chat, ChatContext, ChatReply};
use crate::island::WINDOW_LABEL;

const MAX_TOKENS: u32 = 4096;
/// A text file is sent inline up to this many characters; the rest is cut.
const MAX_INLINE_CHARS: usize = 24_000;
/// The island is told about new text at most this often.
const DELTA_INTERVAL: Duration = Duration::from_millis(1000 / 15);
/// Ollama and LM Studio ignore the key, but some OpenAI clients insist on sending one.
const NO_KEY: &str = "ollama";

fn bearer(key: Option<&str>) -> String {
    format!("Bearer {}", key.filter(|k| !k.is_empty()).unwrap_or(NO_KEY))
}
/// Models that embed or rank rather than chat are left out of the list.
const NOT_CHAT: &[&str] = &["embed", "bge-", "all-minilm", "clip", "rerank"];

/// A server that answered: its address as it will be stored, and the models it has.
#[derive(Debug, Serialize)]
pub struct Server {
    pub url: String,
    pub models: Vec<String>,
}

fn unreachable(url: &str) -> String {
    format!("Cannot reach {url}. Is the server running?")
}

/// Drops trailing slashes and the documentation sub-paths people paste (`/api`, `/v1`).
pub fn normalise_url(raw: &str) -> String {
    let mut s = raw.trim();
    while let Some(rest) = s.strip_suffix('/') {
        s = rest;
    }
    for suffix in ["/api", "/v1"] {
        if let Some(rest) = s.strip_suffix(suffix) {
            s = rest;
        }
    }
    s.to_string()
}

/// `delta.content` of one OpenAI server-sent event line; none for anything else
/// (other lines, `[DONE]`, a missing or null content).
fn parse_sse_delta(line: &str) -> Option<String> {
    let payload = line.strip_prefix("data: ")?;
    if payload == "[DONE]" {
        return None;
    }
    let json: Value = serde_json::from_str(payload).ok()?;
    json.pointer("/choices/0/delta/content")?.as_str().map(str::to_string)
}

/// Removes finished `<think>…</think>` blocks (reasoning models such as DeepSeek-R1).
fn filter_thinking_blocks(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("<think>") {
        let Some(len) = rest[start..].find("</think>") else { break };
        out.push_str(&rest[..start]);
        rest = &rest[start + len + "</think>".len()..];
    }
    out.push_str(rest);
    out.trim().to_string()
}

/// For the text shown while streaming: finished blocks go, and so does everything
/// after a block that has not been closed yet.
fn progressive_filter(text: &str) -> String {
    let cleaned = filter_thinking_blocks(text);
    match cleaned.find("<think>") {
        Some(at) => cleaned[..at].trim().to_string(),
        None => cleaned,
    }
}

/// The chat models a server has (`GET /v1/models`), or why it can't be reached.
pub async fn models(base: &str, key: Option<&str>) -> Result<Vec<String>, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|e| e.to_string())?;
    let reply = client
        .get(format!("{base}/v1/models"))
        .header("Authorization", bearer(key))
        .send()
        .await
        .map_err(|_| unreachable(base))?;
    if !reply.status().is_success() {
        return Err(unreachable(base));
    }
    let body: Value = reply.json().await.map_err(|_| unreachable(base))?;
    let items = body.get("data").and_then(Value::as_array).ok_or_else(|| unreachable(base))?;
    Ok(items
        .iter()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .filter(|id| !NOT_CHAT.iter().any(|n| id.to_lowercase().contains(n)))
        .map(str::to_string)
        .collect())
}

/// The "Connect" button: checks the server answers and reports what it has. An
/// empty address means the usual one on this machine.
pub async fn connect(url: &str, default_url: &str, key: Option<&str>) -> Result<Server, String> {
    let url = normalise_url(if url.trim().is_empty() { default_url } else { url });
    if url.is_empty() {
        return Err("Enter the server address first.".into());
    }
    let models = models(&url, key).await?;
    Ok(Server { url, models })
}

/// What the file adds to the first message: text inline (cut), anything else by name.
fn file_note(name: &str, path: &str) -> String {
    let ext = std::path::Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let binary = matches!(ext.as_str(), "pdf" | "jpg" | "jpeg" | "png" | "gif" | "webp");
    match std::fs::read_to_string(path) {
        Ok(text) if !binary => {
            let body: String = text.chars().take(MAX_INLINE_CHARS).collect();
            format!("File: {name}\nFile contents:\n{body}")
        }
        _ => format!("File: {name}"),
    }
}

/// One chat turn with a local model. The history is kept here, apart from Claude's
/// (whose messages carry tool blocks a local server would not understand).
pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    base: &str,
    key: Option<&str>,
    model: &str,
    language: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let base = normalise_url(base);
    if base.is_empty() {
        return Err("Connect a local model server in Settings first.".into());
    }
    if model.is_empty() {
        return Err("Pick a model in Settings → Local models first.".into());
    }

    let mut text = String::new();
    // File / window context rides along with the first message only.
    if chat.local.lock().unwrap().is_empty() {
        match &context {
            Some(ChatContext::File { name, path }) => text.push_str(&format!("{}\n\n", file_note(name, path))),
            Some(ChatContext::Window { app_name, title, url }) => {
                text.push_str(&format!("Context — App: {app_name}, Window: {title}"));
                if let Some(url) = url {
                    text.push_str(&format!(", URL: {url}"));
                }
                text.push_str("\n\n");
            }
            None => {}
        }
    }
    text.push_str(&query);

    let user = json!({ "role": "user", "content": text });
    let mut messages = vec![json!({ "role": "system", "content": local_system_prompt(language) })];
    messages.extend(chat.local.lock().unwrap().iter().cloned());
    messages.push(user.clone());

    let answer = stream(app, &base, key, model, &messages).await?;
    if answer.is_empty() {
        return Err("No response text.".into());
    }
    let mut history = chat.local.lock().unwrap();
    history.push(user);
    history.push(json!({ "role": "assistant", "content": answer }));
    Ok(ChatReply { text: answer })
}

/// Claude's system prompt, minus the web search a local model does not have.
fn local_system_prompt(language: &str) -> String {
    system_prompt(language).replace("You have web search access and can help", "You can help")
}

async fn stream(app: &AppHandle, base: &str, key: Option<&str>, model: &str, messages: &[Value]) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|e| e.to_string())?;
    let mut reply = client
        .post(format!("{base}/v1/chat/completions"))
        .header("Authorization", bearer(key))
        .json(&json!({ "model": model, "messages": messages, "stream": true, "max_tokens": MAX_TOKENS }))
        .send()
        .await
        .map_err(|_| unreachable(base))?;

    let status = reply.status();
    if status.as_u16() == 404 {
        return Err(format!("Model '{model}' is not installed."));
    }
    if !status.is_success() {
        let body = reply.text().await.unwrap_or_default();
        let why = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|v| v.pointer("/error/message").and_then(Value::as_str).map(str::to_string));
        return Err(why.unwrap_or_else(|| format!("HTTP {}", status.as_u16())));
    }

    let mut accumulated = String::new();
    let mut pending = Vec::<u8>::new();
    let mut last = Instant::now() - DELTA_INTERVAL;
    while let Some(chunk) = reply.chunk().await.map_err(|_| unreachable(base))? {
        pending.extend_from_slice(&chunk);
        // Whole lines only: a chunk may end in the middle of one, or of a character.
        while let Some(end) = pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line);
            if let Some(delta) = parse_sse_delta(line.trim_end()) {
                accumulated.push_str(&delta);
            }
        }
        if last.elapsed() >= DELTA_INTERVAL {
            last = Instant::now();
            let _ = app.emit_to(WINDOW_LABEL, "chat-delta", progressive_filter(&accumulated));
        }
    }
    // The last state always goes out, whatever the throttle skipped.
    let _ = app.emit_to(WINDOW_LABEL, "chat-delta", progressive_filter(&accumulated));
    Ok(filter_thinking_blocks(&accumulated))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_address_loses_slashes_and_the_paths_people_paste() {
        assert_eq!(normalise_url("  http://localhost:11434/  "), "http://localhost:11434");
        assert_eq!(normalise_url("http://localhost:11434/v1"), "http://localhost:11434");
        assert_eq!(normalise_url("http://localhost:1234/v1/"), "http://localhost:1234");
        assert_eq!(normalise_url("http://localhost:11434/api"), "http://localhost:11434");
        assert_eq!(normalise_url(""), "");
    }

    #[test]
    fn only_content_deltas_are_taken_from_the_event_stream() {
        let line = r#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#;
        assert_eq!(parse_sse_delta(line).as_deref(), Some("Hel"));
        assert_eq!(parse_sse_delta("data: [DONE]"), None);
        assert_eq!(parse_sse_delta(""), None);
        assert_eq!(parse_sse_delta(": keep-alive"), None);
        assert_eq!(parse_sse_delta(r#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), None);
        assert_eq!(parse_sse_delta(r#"data: {"choices":[{"delta":{"content":null}}]}"#), None);
        assert_eq!(parse_sse_delta("data: not json"), None);
    }

    #[test]
    fn finished_thinking_blocks_go_and_an_open_one_hides_what_follows() {
        assert_eq!(filter_thinking_blocks("<think>hmm</think>\n\nThe answer."), "The answer.");
        assert_eq!(filter_thinking_blocks("a<think>x</think>b<think>y</think>c"), "abc");
        assert_eq!(filter_thinking_blocks("plain"), "plain");
        // Streaming: nothing of an unfinished block shows.
        assert_eq!(progressive_filter("Sure. <think>let me think"), "Sure.");
        assert_eq!(progressive_filter("<think>still thinking"), "");
        assert_eq!(progressive_filter("<think>done</think>Visible <think>again"), "Visible");
        // A tag that is only half written is not a block yet.
        assert_eq!(progressive_filter("text <thi"), "text <thi");
    }

    /// One-shot HTTP server on a free port answering the next request with `body`.
    fn serve_once(status: &str, body: &str) -> String {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let reply = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        std::thread::spawn(move || {
            let (mut conn, _) = listener.accept().unwrap();
            let mut buf = [0u8; 2048];
            let _ = conn.read(&mut buf);
            let _ = conn.write_all(reply.as_bytes());
        });
        url
    }

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn the_model_list_leaves_out_embedding_models_and_says_when_nothing_answers() {
        let url = serve_once("200 OK", r#"{"data":[{"id":"llama3.2"},{"id":"nomic-embed-text"},{"id":"BGE-large"},{"id":"qwen2.5-coder"}]}"#);
        assert_eq!(block_on(models(&url, None)).unwrap(), vec!["llama3.2", "qwen2.5-coder"]);

        // Wrong status, not JSON, or nobody home: the same plain message.
        let url = serve_once("500 Internal Server Error", "{}");
        assert_eq!(block_on(models(&url, None)).unwrap_err(), format!("Cannot reach {url}. Is the server running?"));
        let url = serve_once("200 OK", "not json");
        assert!(block_on(models(&url, None)).unwrap_err().starts_with("Cannot reach"));
        assert!(block_on(models("http://127.0.0.1:1", None)).unwrap_err().starts_with("Cannot reach"));
    }

    #[test]
    fn connect_takes_the_usual_address_for_an_empty_field_and_cleans_a_pasted_one() {
        let url = serve_once("200 OK", r#"{"data":[{"id":"m"}]}"#);
        let server = block_on(connect(&format!("{url}/v1/"), "http://unused", None)).unwrap();
        assert_eq!(server.url, url);
        assert_eq!(server.models, vec!["m"]);
        let url = serve_once("200 OK", r#"{"data":[]}"#);
        assert_eq!(block_on(connect("  ", &url, None)).unwrap().url, url);
    }

    #[test]
    fn a_key_is_sent_as_the_bearer_and_without_one_the_placeholder_is() {
        assert_eq!(bearer(Some("sk-abc")), "Bearer sk-abc");
        assert_eq!(bearer(Some("")), "Bearer ollama");
        assert_eq!(bearer(None), "Bearer ollama");
        // No usual address and nothing typed: asked for, not guessed.
        assert_eq!(block_on(connect(" ", "", None)).unwrap_err(), "Enter the server address first.");
    }

    #[test]
    fn a_local_model_is_not_told_it_can_search_the_web() {
        let p = local_system_prompt("en");
        assert!(!p.contains("web search"));
        assert!(p.contains("You can help with"));
        assert!(system_prompt("en").contains("web search"));
    }

    #[test]
    fn text_files_go_inline_cut_and_everything_else_by_name() {
        let dir = std::env::temp_dir().join(format!("coucou-local-chat-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt = dir.join("notes.txt");
        std::fs::write(&txt, "x".repeat(MAX_INLINE_CHARS + 500)).unwrap();
        let note = file_note("notes.txt", txt.to_str().unwrap());
        let body = note.strip_prefix("File: notes.txt\nFile contents:\n").expect("inline text");
        assert_eq!(body.chars().count(), MAX_INLINE_CHARS);

        let png = dir.join("pic.png");
        std::fs::write(&png, "not really a picture").unwrap();
        assert_eq!(file_note("pic.png", png.to_str().unwrap()), "File: pic.png");
        assert_eq!(file_note("gone.txt", "/no/such/file"), "File: gone.txt");
        let _ = std::fs::remove_dir_all(dir);
    }
}
