// Chat with a model server the user runs: Ollama, LM Studio, or any other
// server that speaks the OpenAI API (vLLM, llama.cpp, Unsloth…) — the same
// integration as LocalChat.swift, plus that last one.
//
// The answer is streamed token by token. Each step goes to the island as a
// `chat-delta` event carrying the text visible so far, and the island shows it
// growing; the reply of the command is the finished text. `<think>` blocks of
// reasoning models stay hidden while open and are dropped from the answer.
//
// Nothing leaves the machine unless the user pointed the server address
// somewhere else: that address is the only place this module talks to.

use std::time::{Duration, Instant};

use reqwest::Url;
use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::island::WINDOW_LABEL;
use crate::settings::Settings;
use crate::i18n::{t, tf};
use crate::{net, open_webui, secrets};

/// Credential store entry of the key of the user's own OpenAI-compatible server.
pub const CUSTOM_KEY: &str = "openai-compatible-key";

const MAX_TOKENS: u32 = 4096;
/// A text file is sent inline up to this many characters; the rest is cut.
const MAX_INLINE_CHARS: usize = 24_000;
/// The island is told about new text at most this often.
const DELTA_INTERVAL: Duration = Duration::from_millis(1000 / 15);
/// Ceilings for a streamed answer: one event line, and the whole answer.
const MAX_LINE: usize = 1024 * 1024;
const MAX_ANSWER: usize = 4 * 1024 * 1024;
/// Ollama and LM Studio ignore the key, but some clients insist on sending one.
const NO_KEY: &str = "ollama";
/// Models that embed or rank rather than chat are left out of the list.
const NOT_CHAT: &[&str] = &["embed", "bge-", "all-minilm", "clip", "rerank"];

// ── The custom server's key ───────────────────────────────────────────────────
//
// The key is stored together with the one address it was entered for, and is
// only ever sent there. The address in the settings, or the one given to
// "Connect", can be changed from the page; the key cannot follow it. And a key
// never goes over plain http to another machine.

#[derive(Serialize, serde::Deserialize)]
struct BoundKey {
    url: String,
    key: String,
}

fn may_carry_key(url: &Url) -> bool {
    url.scheme() == "https" || net::is_loopback_url(url)
}

/// Credential store entry of a server's key: the custom server and Open WebUI have one.
pub fn key_entry(id: &str) -> Option<&'static str> {
    match id {
        "custom" => Some(CUSTOM_KEY),
        open_webui::ID => Some(open_webui::KEY),
        _ => None,
    }
}

/// Settings → Local models: stores the key for the address typed next to it.
pub fn set_key(id: &str, typed_url: &str, key: &str) -> Result<(), String> {
    let entry = key_entry(id).ok_or_else(|| format!("No key for {id}"))?;
    let url = net::normalise_server_url(typed_url)?;
    if !may_carry_key(&url) {
        return Err(t("A key is only sent over https, or to a server on this computer."));
    }
    let bound = BoundKey { url: url.as_str().trim_end_matches('/').to_string(), key: key.trim().to_string() };
    let value = serde_json::to_string(&bound).map_err(|e| e.to_string())?;
    secrets::set(entry, &value)
}

/// The key stored under `entry`, if it was entered for exactly this address.
pub fn bound_key(entry: &str, url: &Url) -> Option<String> {
    let stored = secrets::get(entry)?;
    key_for(&stored, url)
}

fn key_for(stored: &str, url: &Url) -> Option<String> {
    let bound: BoundKey = serde_json::from_str(stored).ok()?;
    (may_carry_key(url) && bound.url == url.as_str().trim_end_matches('/') && !bound.key.is_empty())
        .then_some(bound.key)
}

/// A model server as the settings describe it.
pub struct Server {
    pub id: &'static str,
    pub name: &'static str,
    /// As stored: empty until the user connects it.
    pub url: String,
    pub key: Option<String>,
}

/// Ollama, LM Studio, "custom" or Open WebUI, from the settings; None for any other id.
pub fn server(settings: &Settings, id: &str) -> Option<Server> {
    let keyed = |url: &str, entry| net::normalise_server_url(url).ok().and_then(|u| bound_key(entry, &u));
    let (id, name, url, key) = match id {
        "ollama" => ("ollama", "Ollama", &settings.ollama_url, None),
        "lmstudio" => ("lmstudio", "LM Studio", &settings.lmstudio_url, None),
        "custom" => {
            let key = keyed(&settings.custom_url, CUSTOM_KEY);
            ("custom", crate::i18n::n_("OpenAI-compatible server"), &settings.custom_url, key)
        }
        open_webui::ID => {
            let key = keyed(&settings.open_webui_url, open_webui::KEY);
            (open_webui::ID, "Open WebUI", &settings.open_webui_url, key)
        }
        _ => return None,
    };
    Some(Server { id, name, url: url.clone(), key })
}

/// The usual address of a server on this machine; none for "custom". Ollama's
/// own OLLAMA_HOST wins when it is set, as the Ollama CLI does.
fn usual_address(id: &str) -> Option<String> {
    match id {
        "ollama" => Some(
            std::env::var("OLLAMA_HOST")
                .ok()
                .filter(|v| !v.trim().is_empty())
                .unwrap_or_else(|| "http://127.0.0.1:11434".into()),
        ),
        "lmstudio" => Some("http://127.0.0.1:1234".into()),
        _ => None,
    }
}

pub(crate) fn bearer(key: Option<&str>) -> String {
    format!("Bearer {}", key.filter(|k| !k.is_empty()).unwrap_or(NO_KEY))
}

pub(crate) fn unreachable(url: &Url) -> String {
    tf("Cannot reach {url}. Is the server running?", &[("url", url.as_str().trim_end_matches('/'))])
}

pub(crate) fn base_url(server: &Server) -> Result<Url, String> {
    if server.url.trim().is_empty() {
        return Err(tf("Connect {name} in Settings → Local models first.", &[("name", &t(server.name))]));
    }
    net::normalise_server_url(&server.url)
}

/// What the "Connect" button reports: the address as it will be stored, the
/// chat models the server has, and whether the address is this machine.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Connected {
    pub url: String,
    pub models: Vec<String>,
    pub loopback: bool,
}

/// Settings → Local models → Connect: does the server answer, and which models
/// does it have? An empty address means the usual one on this machine.
pub async fn connect(id: &str, typed: &str) -> Result<Connected, String> {
    let raw = if typed.trim().is_empty() { usual_address(id).unwrap_or_default() } else { typed.to_string() };
    let url = net::normalise_server_url(&raw)?;
    let key = key_entry(id).and_then(|entry| bound_key(entry, &url));
    let models = if id == open_webui::ID {
        open_webui::list(&url, key.as_deref()).await?.into_iter().map(|m| m.id).collect()
    } else {
        list(&url, key.as_deref()).await?
    };
    Ok(Connected {
        url: url.as_str().trim_end_matches('/').to_string(),
        models,
        loopback: net::is_loopback_url(&url),
    })
}

/// The models of a connected server, for the picker in the chat view.
pub async fn models(server: &Server) -> Result<Vec<ModelInfo>, String> {
    let url = base_url(server)?;
    let models = list(&url, server.key.as_deref()).await?;
    if models.is_empty() {
        return Err(tf("No models yet. Download one in {name} first.", &[("name", &t(server.name))]));
    }
    Ok(models.into_iter().map(|id| ModelInfo { label: id.clone(), id, group: None }).collect())
}

/// `GET /v1/models`, chat models only, or why the server can't be reached.
async fn list(base: &Url, key: Option<&str>) -> Result<Vec<String>, String> {
    let response = net::client(base, Duration::from_secs(5))?
        .get(net::join(base, "v1/models"))
        .header("Authorization", bearer(key))
        .send()
        .await
        .map_err(|_| unreachable(base))?;
    if matches!(response.status().as_u16(), 401 | 403) {
        return Err(t("The server refused the key. Check it, then connect again."));
    }
    if !response.status().is_success() {
        return Err(unreachable(base));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    let body: Value = serde_json::from_slice(&bytes).map_err(|_| unreachable(base))?;
    parse_models(&body).ok_or_else(|| unreachable(base))
}

fn parse_models(body: &Value) -> Option<Vec<String>> {
    let items = body.get("data")?.as_array()?;
    Some(
        items
            .iter()
            .filter_map(|m| m.get("id").and_then(Value::as_str))
            .filter(|id| !NOT_CHAT.iter().any(|n| id.to_lowercase().contains(n)))
            .map(str::to_string)
            .collect(),
    )
}

// ── Messages ──────────────────────────────────────────────────────────────────

/// What a dropped file adds to the first message: text inline (cut), anything
/// else by name only.
fn file_note(name: &str, path: &str) -> String {
    let ext = std::path::Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let binary = matches!(ext.as_str(), "pdf" | "jpg" | "jpeg" | "png" | "gif" | "webp");
    // Read no more than the inline limit can use (4 bytes per character at most).
    let text = if binary { None } else { read_prefix(path, MAX_INLINE_CHARS * 4) };
    match text {
        Some(text) if !text.is_empty() => {
            let mut body: String = text.chars().take(MAX_INLINE_CHARS).collect();
            if body.len() < text.len() {
                body.push_str("\n[truncated]");
            }
            format!("File: {name}\nFile contents:\n{body}")
        }
        _ => format!("File: {name}"),
    }
}

/// The first `limit` bytes of a file as UTF-8 text (a character cut in half at
/// the end is dropped), or None for a file that is not text.
fn read_prefix(path: &str, limit: usize) -> Option<String> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path).ok()?.take(limit as u64).read_to_end(&mut bytes).ok()?;
    match String::from_utf8(bytes) {
        Ok(text) => Some(text),
        Err(e) if e.utf8_error().error_len().is_none() => {
            let valid = e.utf8_error().valid_up_to();
            let mut bytes = e.into_bytes();
            bytes.truncate(valid);
            String::from_utf8(bytes).ok()
        }
        Err(_) => None,
    }
}

pub(crate) fn user_text(first: bool, context: Option<&ChatContext>, query: &str) -> String {
    match context.filter(|_| first) {
        Some(ChatContext::File { name, path }) => format!("{}\n\n{query}", file_note(name, path)),
        Some(ChatContext::Window { app_name, title, url }) => {
            format!("{}\n\n{query}", chat::window_line(app_name, title, url.as_deref()))
        }
        None => query.to_string(),
    }
}

fn request_body(model: &str, system: &str, history: &[Value], user: &Value) -> Value {
    let mut messages = vec![json!({ "role": "system", "content": system })];
    messages.extend(history.iter().cloned());
    messages.push(user.clone());
    json!({ "model": model, "messages": messages, "stream": true, "max_tokens": MAX_TOKENS })
}

/// One chat turn with a model server.
pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    server: &Server,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let base = base_url(server)?;
    if model.is_empty() {
        return Err(t("Pick a model above the chat box first."));
    }
    let turn = chat.begin(server.id);
    let user = json!({ "role": "user", "content": user_text(turn.first, context.as_ref(), &query) });
    let body = request_body(model, &chat::system_prompt(false), &turn.history, &user);

    let answer = stream(&base, server.key.as_deref(), model, &body, |visible| {
        let _ = app.emit_to(WINDOW_LABEL, "chat-delta", visible);
    })
    .await?;
    if answer.is_empty() {
        return Err(t("No response text."));
    }
    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(&turn, user, json!({ "role": "assistant", "content": answer }), &plain, &answer);
    Ok(ChatReply { text: answer })
}

// ── Streaming ─────────────────────────────────────────────────────────────────

/// One server-sent event line: `Some(Ok(text))` for a content delta,
/// `Some(Err(message))` for an error event, None for anything else (other
/// lines, `[DONE]`, a delta without content, such as reasoning-only ones).
fn parse_sse_line(line: &str) -> Option<Result<String, String>> {
    let payload = line.strip_prefix("data:")?.trim_start();
    if payload == "[DONE]" {
        return None;
    }
    let json: Value = serde_json::from_str(payload).ok()?;
    if let Some(msg) = json.pointer("/error/message").and_then(Value::as_str) {
        return Some(Err(msg.to_string()));
    }
    json.pointer("/choices/0/delta/content")?.as_str().map(|s| Ok(s.to_string()))
}

/// Removes finished `<think>…</think>` blocks (reasoning models such as DeepSeek-R1).
pub(crate) fn filter_thinking_blocks(text: &str) -> String {
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

/// For the text shown while streaming: finished blocks go, and so does
/// everything after a block that has not been closed yet.
fn progressive_filter(text: &str) -> String {
    let cleaned = filter_thinking_blocks(text);
    match cleaned.find("<think>") {
        Some(at) => cleaned[..at].trim().to_string(),
        None => cleaned,
    }
}

/// Posts the request and reads the event stream. `on_delta` gets the visible
/// text at most 15 times a second, and once more at the end; the result is the
/// whole answer without its thinking.
async fn stream(
    base: &Url,
    key: Option<&str>,
    model: &str,
    body: &Value,
    mut on_delta: impl FnMut(String),
) -> Result<String, String> {
    let mut reply = net::client(base, Duration::from_secs(300))?
        .post(net::join(base, "v1/chat/completions"))
        .header("Authorization", bearer(key))
        .json(body)
        .send()
        .await
        .map_err(|_| unreachable(base))?;

    let status = reply.status();
    if status.as_u16() == 404 {
        return Err(tf("{model} isn't installed. Pick another model above the chat box.", &[("model", model)]));
    }
    if !status.is_success() {
        let body = net::read_capped(reply, net::MAX_ERROR_BODY).await.unwrap_or_default();
        let detail = net::error_detail(&body);
        return Err(if detail.is_empty() { format!("HTTP {}", status.as_u16()) } else { detail });
    }

    let mut accumulated = String::new();
    let mut pending = Vec::<u8>::new();
    let mut last = Instant::now().checked_sub(DELTA_INTERVAL).unwrap_or_else(Instant::now);
    while let Some(chunk) = reply.chunk().await.map_err(|_| unreachable(base))? {
        pending.extend_from_slice(&chunk);
        // Whole lines only: a chunk may end in the middle of one, or of a character.
        while let Some(end) = pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = pending.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line);
            match parse_sse_line(line.trim_end()) {
                Some(Ok(delta)) => accumulated.push_str(&delta),
                Some(Err(message)) => return Err(message),
                None => {}
            }
        }
        if pending.len() > MAX_LINE || accumulated.len() > MAX_ANSWER {
            return Err(t("The server's answer is too large."));
        }
        if last.elapsed() >= DELTA_INTERVAL {
            last = Instant::now();
            on_delta(progressive_filter(&accumulated));
        }
    }
    // A last line without its newline.
    if let Some(Ok(delta)) = parse_sse_line(String::from_utf8_lossy(&pending).trim_end()) {
        accumulated.push_str(&delta);
    }
    // The last state always goes out, whatever the throttle skipped.
    on_delta(progressive_filter(&accumulated));
    Ok(filter_thinking_blocks(&accumulated))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::tests::serve_once;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    fn url(s: &str) -> Url {
        net::normalise_server_url(s).unwrap()
    }

    #[test]
    fn only_content_deltas_are_taken_from_the_event_stream() {
        let line = r#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#;
        assert_eq!(parse_sse_line(line), Some(Ok("Hel".into())));
        let line = r#"data:{"choices":[{"delta":{"content":"lo"}}]}"#;
        assert_eq!(parse_sse_line(line), Some(Ok("lo".into())));
        assert_eq!(parse_sse_line("data: [DONE]"), None);
        assert_eq!(parse_sse_line(""), None);
        assert_eq!(parse_sse_line(": keep-alive"), None);
        assert_eq!(parse_sse_line(r#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), None);
        assert_eq!(parse_sse_line(r#"data: {"choices":[{"delta":{"content":null,"reasoning_content":"x"}}]}"#), None);
        assert_eq!(parse_sse_line("data: not json"), None);
        assert_eq!(parse_sse_line(r#"data: {"error":{"message":"out of memory"}}"#), Some(Err("out of memory".into())));
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

    #[test]
    fn the_request_streams_with_system_history_and_the_new_turn() {
        let history = vec![json!({"role":"user","content":"a"}), json!({"role":"assistant","content":"b"})];
        let body = request_body("llama3.2", "sys", &history, &json!({"role":"user","content":"c"}));
        assert_eq!(body["stream"], true);
        assert_eq!(body["model"], "llama3.2");
        assert_eq!(body["messages"].as_array().unwrap().len(), 4);
        assert_eq!(body["messages"][0]["role"], "system");
    }

    #[test]
    fn a_key_is_sent_as_the_bearer_and_without_one_the_placeholder_is() {
        assert_eq!(bearer(Some("sk-abc")), "Bearer sk-abc");
        assert_eq!(bearer(Some("")), "Bearer ollama");
        assert_eq!(bearer(None), "Bearer ollama");
    }

    #[test]
    fn a_server_that_is_not_connected_says_so() {
        let s = Settings::default();
        let ollama = server(&s, "ollama").unwrap();
        assert_eq!(base_url(&ollama).unwrap_err(), "Connect Ollama in Settings → Local models first.");
        assert!(server(&s, "openai").is_none());
        assert_eq!(usual_address("lmstudio").as_deref(), Some("http://127.0.0.1:1234"));
        assert_eq!(usual_address("custom"), None);
    }

    #[test]
    fn the_model_list_leaves_out_embedding_models_and_says_when_nothing_answers() {
        let body = br#"{"data":[{"id":"llama3.2"},{"id":"nomic-embed-text"},{"id":"BGE-large"},{"id":"qwen2.5-coder"}]}"#;
        let u = serve_once("200 OK", &format!("Content-Length: {}\r\n", body.len()), body.to_vec());
        assert_eq!(block_on(list(&url(&u), None)).unwrap(), vec!["llama3.2", "qwen2.5-coder"]);

        let u = serve_once("500 Internal Server Error", "Content-Length: 2\r\n", b"{}".to_vec());
        assert!(block_on(list(&url(&u), None)).unwrap_err().starts_with("Cannot reach"));
        let u = serve_once("200 OK", "Content-Length: 8\r\n", b"not json".to_vec());
        assert!(block_on(list(&url(&u), None)).unwrap_err().starts_with("Cannot reach"));
        assert!(block_on(list(&url("http://127.0.0.1:1"), None)).unwrap_err().starts_with("Cannot reach"));
        let u = serve_once("401 Unauthorized", "Content-Length: 2\r\n", b"{}".to_vec());
        assert!(block_on(list(&url(&u), Some("bad"))).unwrap_err().contains("refused the key"));
    }

    #[test]
    fn connect_cleans_a_pasted_address_and_reports_whether_it_is_this_machine() {
        let body = br#"{"data":[{"id":"m"}]}"#;
        let u = serve_once("200 OK", &format!("Content-Length: {}\r\n", body.len()), body.to_vec());
        let c = block_on(connect("lmstudio", &format!("{u}/v1/"))).unwrap();
        assert_eq!(c.url, u);
        assert_eq!(c.models, vec!["m"]);
        assert!(c.loopback);
        assert_eq!(block_on(connect("custom", " ")).unwrap_err(), "Enter the server address first.");
        assert!(block_on(connect("custom", "file:///etc")).is_err());
    }

    #[test]
    fn the_stream_is_read_line_by_line_and_thinking_stays_hidden() {
        let events = [
            r#"{"choices":[{"delta":{"content":"<think>\nstep "}}]}"#,
            r#"{"choices":[{"delta":{"content":"one\n</think>"}}]}"#,
            r#"{"choices":[{"delta":{"content":null,"reasoning_content":"internal"}}]}"#,
            r###"{"choices":[{"delta":{"content":"## Answer\n\n"}}]}"###,
            r#"{"choices":[{"delta":{"content":"- **item 1**\n"}}]}"#,
            r#"{"choices":[{"delta":{"content":"```python\nprint('hello')\n```"}}]}"#,
        ];
        let mut body = String::new();
        for e in events {
            body.push_str(&format!("data: {e}\n\n"));
        }
        body.push_str("data: [DONE]\n\n");
        let u = serve_once("200 OK", "Content-Type: text/event-stream\r\n", body.into_bytes());
        let mut seen = Vec::new();
        let answer = block_on(stream(&url(&u), None, "m", &json!({}), |v| seen.push(v))).unwrap();
        assert_eq!(answer, "## Answer\n\n- **item 1**\n```python\nprint('hello')\n```");
        assert_eq!(seen.last().unwrap(), &answer);
        assert!(seen.iter().all(|v| !v.contains("step") && !v.contains("internal")));
    }

    #[test]
    fn stream_errors_say_what_happened() {
        let u = serve_once("404 Not Found", "Content-Length: 2\r\n", b"{}".to_vec());
        let err = block_on(stream(&url(&u), None, "unknown-model", &json!({}), |_| {})).unwrap_err();
        assert_eq!(err, "unknown-model isn't installed. Pick another model above the chat box.");
        let body = br#"{"error":{"message":"context too long"}}"#;
        let u = serve_once("400 Bad Request", &format!("Content-Length: {}\r\n", body.len()), body.to_vec());
        assert_eq!(block_on(stream(&url(&u), None, "m", &json!({}), |_| {})).unwrap_err(), "context too long");
        let u = serve_once("200 OK", "", b"data: {\"error\":{\"message\":\"crashed\"}}\n".to_vec());
        assert_eq!(block_on(stream(&url(&u), None, "m", &json!({}), |_| {})).unwrap_err(), "crashed");
    }

    #[test]
    fn an_endless_line_is_cut_off() {
        let u = serve_once("200 OK", "", vec![b'x'; MAX_LINE + 10]);
        let err = block_on(stream(&url(&u), None, "m", &json!({}), |_| {})).unwrap_err();
        assert_eq!(err, "The server's answer is too large.");
    }

    #[test]
    fn text_files_go_inline_cut_and_everything_else_by_name() {
        let dir = std::env::temp_dir().join(format!("coucou-local-chat-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt = dir.join("notes.txt");
        std::fs::write(&txt, "é".repeat(MAX_INLINE_CHARS + 500)).unwrap();
        let note = file_note("notes.txt", txt.to_str().unwrap());
        let body = note.strip_prefix("File: notes.txt\nFile contents:\n").expect("inline text");
        let body = body.strip_suffix("\n[truncated]").expect("marked as cut");
        assert_eq!(body.chars().count(), MAX_INLINE_CHARS);

        let small = dir.join("small.md");
        std::fs::write(&small, "# hi").unwrap();
        assert_eq!(file_note("small.md", small.to_str().unwrap()), "File: small.md\nFile contents:\n# hi");

        let png = dir.join("pic.png");
        std::fs::write(&png, "not really a picture").unwrap();
        assert_eq!(file_note("pic.png", png.to_str().unwrap()), "File: pic.png");
        assert_eq!(file_note("gone.txt", "/no/such/file"), "File: gone.txt");
        let bin = dir.join("blob.bin");
        std::fs::write(&bin, [0xff, 0xfe, 0x00, 0x80]).unwrap();
        assert_eq!(file_note("blob.bin", bin.to_str().unwrap()), "File: blob.bin");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_custom_key_only_goes_to_the_address_it_was_entered_for() {
        let url = |u: &str| net::normalise_server_url(u).unwrap();
        let stored = serde_json::to_string(&BoundKey { url: "https://llm.example.com".into(), key: "sk-1".into() }).unwrap();
        assert_eq!(key_for(&stored, &url("https://llm.example.com")).as_deref(), Some("sk-1"));
        assert_eq!(key_for(&stored, &url("https://attacker.example")), None);
        assert_eq!(key_for(&stored, &url("http://llm.example.com")), None);
        // A plain string (the page can write one through secret_set) binds nothing.
        assert_eq!(key_for("sk-raw", &url("https://llm.example.com")), None);
        let local = serde_json::to_string(&BoundKey { url: "http://127.0.0.1:8080".into(), key: "k".into() }).unwrap();
        assert_eq!(key_for(&local, &url("http://127.0.0.1:8080")).as_deref(), Some("k"));
        assert!(!may_carry_key(&url("http://192.168.1.20:8080")));
    }
}
