// 9router — an OpenAI-compatible gateway the user runs themselves. Same shape
// as claude.rs: the key stays in the Credential Manager, the island only ever
// gets text back.
//
// The request/response mapping is kept in pure functions so it can be tested
// without a server.

use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use reqwest::Url;
use serde_json::{json, Value};

use crate::claude::{self, Chat, ChatContext, ChatReply};
use crate::secrets;
use crate::tools::{self, Backend, ToolRunner, Turn};

pub const SECRET_KEY: &str = "router-api-key";

const CHAT_TIMEOUT: Duration = Duration::from_secs(90);
const MODELS_TIMEOUT: Duration = Duration::from_secs(10);
const MODELS_TTL: Duration = Duration::from_secs(5 * 60);
const MAX_MODEL_LEN: usize = 200;

struct CachedModels {
    base: String,
    at: Instant,
    ids: Vec<String>,
}

static MODELS_CACHE: Mutex<Option<CachedModels>> = Mutex::new(None);

pub fn forget_models() {
    *MODELS_CACHE.lock().unwrap() = None;
}

/// Accepts https anywhere, plain http only to this machine or a private
/// network address, and returns the URL without a trailing slash.
pub fn normalize_base_url(raw: &str) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("9router base URL missing. Open settings.".into());
    }
    let url = Url::parse(raw).map_err(|_| "9router base URL is not a valid URL.".to_string())?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err("9router base URL must not contain a user name or password.".into());
    }
    if url.query().is_some() || url.fragment().is_some() {
        return Err("9router base URL must not contain ? or #.".into());
    }
    match url.scheme() {
        "https" => {}
        "http" if is_local_host(&url) => {}
        "http" => {
            return Err(
                "9router base URL must use https (plain http only to localhost or a private IP)."
                    .into(),
            )
        }
        _ => return Err("9router base URL must start with https://.".into()),
    }
    if url.host().is_none() {
        return Err("9router base URL has no host.".into());
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
}

fn is_local_host(url: &Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    if host.eq_ignore_ascii_case("localhost") {
        return true;
    }
    match host
        .trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<IpAddr>()
    {
        Ok(IpAddr::V4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
        Ok(IpAddr::V6(ip)) => {
            let first = ip.segments()[0];
            ip.is_loopback() || (first & 0xfe00) == 0xfc00 || (first & 0xffc0) == 0xfe80
        }
        Err(_) => false,
    }
}

/// Model ids go into a JSON body, never a URL, but stay bounded and printable.
pub fn validate_model(model: &str) -> Result<String, String> {
    let model = model.trim();
    if model.is_empty() {
        return Err("Pick a model first.".into());
    }
    if model.len() > MAX_MODEL_LEN || model.chars().any(char::is_control) {
        return Err("That model id is not valid.".into());
    }
    Ok(model.to_string())
}

/// `{"data":[{"id":"…"}]}` → sorted, de-duplicated ids.
pub fn parse_models(body: &str) -> Result<Vec<String>, String> {
    let value: Value = serde_json::from_str(body)
        .map_err(|_| "9router sent an unreadable model list.".to_string())?;
    let data = value
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| "9router sent an unexpected model list.".to_string())?;
    let mut ids: Vec<String> = data
        .iter()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_string)
        .collect();
    ids.sort();
    ids.dedup();
    Ok(ids)
}

/// Readable error for a non-2xx answer. Understands both `{"error":"…"}` and
/// the OpenAI shape `{"error":{"message":"…"}}`; anything else is cut short.
pub fn error_message(status: u16, body: &str) -> String {
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            let err = v.get("error")?;
            err.as_str()
                .or_else(|| err.get("message").and_then(Value::as_str))
                .map(str::to_string)
        })
        .unwrap_or_else(|| body.trim().chars().take(200).collect());
    let detail: String = detail.chars().take(300).collect();
    let lead = match status {
        401 => "9router rejected the API key (401)".to_string(),
        403 => "9router refused access (403)".to_string(),
        404 => "9router endpoint not found (404) — check the base URL".to_string(),
        _ => format!("9router error {status}"),
    };
    if detail.is_empty() {
        lead
    } else {
        format!("{lead}: {detail}")
    }
}

/// Shown under the answer when the model would not take the task tools.
pub const NO_TOOLS_NOTE: &str =
    "(This 9router model did not accept tools, so the chat cannot start tasks with it. Pick another model to start tasks.)";

fn text_of(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The shared history is stored in Anthropic's block shape so either provider
/// can continue it. With `with_tools`, tool_use blocks become `tool_calls` and
/// tool_result blocks become `tool` messages; without, 9router only gets the
/// text blocks. Anthropic server-tool blocks (web search) are always dropped.
pub fn to_openai_messages(history: &[Value], with_tools: bool) -> Vec<Value> {
    let mut out = Vec::new();
    for m in history {
        let Some(role) = m.get("role").and_then(Value::as_str) else { continue };
        let blocks = match m.get("content") {
            Some(Value::String(s)) => vec![json!({ "type": "text", "text": s })],
            Some(Value::Array(b)) => b.clone(),
            _ => continue,
        };
        let text = text_of(&blocks);
        if with_tools && role == "assistant" {
            let calls: Vec<Value> = tools::parse_anthropic_calls(&blocks)
                .into_iter()
                .map(|c| {
                    let args = if c.input.is_object() { c.input } else { json!({}) };
                    json!({ "id": c.id, "type": "function",
                            "function": { "name": c.name, "arguments": args.to_string() } })
                })
                .collect();
            if !calls.is_empty() {
                let content = if text.trim().is_empty() { Value::Null } else { Value::String(text) };
                out.push(json!({ "role": "assistant", "content": content, "tool_calls": calls }));
                continue;
            }
        }
        if with_tools && role == "user" {
            for b in &blocks {
                if b.get("type").and_then(Value::as_str) == Some("tool_result") {
                    out.push(json!({
                        "role": "tool",
                        "tool_call_id": b.get("tool_use_id").cloned().unwrap_or(Value::Null),
                        "content": b.get("content").and_then(Value::as_str).unwrap_or(""),
                    }));
                }
            }
        }
        if !text.trim().is_empty() {
            out.push(json!({ "role": role, "content": text }));
        }
    }
    out
}

/// `tools: None` is the plain body for a model without tool support;
/// `Some((defaults, allow))` adds the task tools, with tool_choice "none"
/// when the loop wants a final answer.
pub fn build_chat_body(model: &str, history: &[Value], tools: Option<(&tools::ToolDefaults, bool)>, memory_context: Option<&str>) -> Value {
    let guidance = if tools.is_some() { tools::GUIDANCE } else { "" };
    let system = format!("{}{guidance}", claude::SYSTEM_PROMPT_NO_SEARCH);
    let mut messages = vec![json!({ "role": "system", "content": system })];
    if let Some(memory_context) = memory_context {
        messages.push(json!({ "role": "developer", "content": memory_context }));
    }
    messages.extend(to_openai_messages(history, tools.is_some()));
    let mut body = json!({ "model": model, "messages": messages, "stream": false });
    if let Some((defaults, allow)) = tools {
        body["tools"] = json!(tools::openai_tools(defaults, tools::ToolAccess::for_memory_context(memory_context)));
        body["tool_choice"] = json!(if allow { "auto" } else { "none" });
    }
    body
}

/// `choices[0].message` → the loop's Turn, in Anthropic block shape for the
/// history. Content may be a string, a list of text parts, or null next to
/// tool_calls.
pub fn parse_turn(body: &str) -> Result<Turn, String> {
    let value: Value =
        serde_json::from_str(body).map_err(|_| "9router sent an unreadable reply.".to_string())?;
    if let Some(err) = value.get("error") {
        let detail = err
            .as_str()
            .or_else(|| err.get("message").and_then(Value::as_str))
            .unwrap_or("unknown error");
        return Err(format!("9router error: {detail}"));
    }
    let message = value
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .filter(|m| m.is_object())
        .ok_or_else(|| "9router sent an unexpected reply.".to_string())?;
    let text = match message.get("content") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    };
    let text = text.trim().to_string();
    let calls = tools::parse_openai_calls(message);
    let mut blocks = Vec::new();
    if !text.is_empty() {
        blocks.push(json!({ "type": "text", "text": text }));
    }
    for c in &calls {
        let input = if c.input.is_object() { c.input.clone() } else { json!({}) };
        blocks.push(json!({ "type": "tool_use", "id": c.id, "name": c.name, "input": input }));
    }
    Ok(Turn { blocks, text, calls, note: None })
}

/// A 4xx on a request with tools most likely means the model or upstream does
/// not take them: retry once without. Auth, a wrong URL and rate limits are
/// real errors.
pub fn should_retry_without_tools(status: u16) -> bool {
    (400..500).contains(&status) && ![401, 403, 404, 408, 429].contains(&status)
}

/// Windows' own TLS stack, so a gateway certificate trusted in the Windows
/// certificate store works here exactly as it does for curl.
pub(crate) fn client(timeout: Duration) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .use_native_tls()
        .timeout(timeout)
        .build()
        .map_err(|e| e.to_string())
}

pub(crate) fn network_error(err: reqwest::Error, timeout: Duration) -> String {
    if err.is_timeout() {
        format!("9router timed out after {} s.", timeout.as_secs())
    } else if err.is_connect() {
        "Could not reach 9router — check the base URL and your network.".into()
    } else {
        format!("Network error talking to 9router: {}", err.without_url())
    }
}

pub(crate) fn api_key() -> Result<String, String> {
    secrets::get(SECRET_KEY).ok_or_else(|| "9router API key missing. Open settings.".to_string())
}

pub async fn models(base: &str, refresh: bool) -> Result<Vec<String>, String> {
    let base = normalize_base_url(base)?;
    if !refresh {
        if let Some(c) = MODELS_CACHE.lock().unwrap().as_ref() {
            if c.base == base && c.at.elapsed() < MODELS_TTL {
                return Ok(c.ids.clone());
            }
        }
    }
    let key = api_key()?;
    let response = client(MODELS_TIMEOUT)?
        .get(format!("{base}/models"))
        .bearer_auth(&key)
        .send()
        .await
        .map_err(|e| network_error(e, MODELS_TIMEOUT))?;
    let status = response.status();
    let text = response
        .text()
        .await
        .map_err(|e| network_error(e, MODELS_TIMEOUT))?;
    if !status.is_success() {
        return Err(error_message(status.as_u16(), &text));
    }
    let ids = parse_models(&text)?;
    *MODELS_CACHE.lock().unwrap() = Some(CachedModels {
        base,
        at: Instant::now(),
        ids: ids.clone(),
    });
    Ok(ids)
}

struct Router {
    base: String,
    model: String,
    key: String,
    defaults: tools::ToolDefaults,
    /// Cleared after the gateway refused a request with tools; the rest of
    /// this turn goes without them.
    tools_ok: bool,
    memory_context: Option<String>,
}

impl Router {
    async fn post(&self, body: &Value) -> Result<String, (u16, String)> {
        let response = client(CHAT_TIMEOUT)
            .map_err(|e| (0, e))?
            .post(format!("{}/chat/completions", self.base))
            .bearer_auth(&self.key)
            .json(body)
            .send()
            .await
            .map_err(|e| (0, network_error(e, CHAT_TIMEOUT)))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| (0, network_error(e, CHAT_TIMEOUT)))?;
        if !status.is_success() {
            return Err((status.as_u16(), error_message(status.as_u16(), &text)));
        }
        Ok(text)
    }

    async fn plain(&self, history: &[Value]) -> Result<Turn, String> {
        let body = build_chat_body(&self.model, history, None, self.memory_context.as_deref());
        let text = self.post(&body).await.map_err(|(_, e)| e)?;
        let mut turn = parse_turn(&text)?;
        turn.calls.clear();
        turn.blocks.retain(|b| b.get("type").and_then(Value::as_str) == Some("text"));
        Ok(turn)
    }
}

impl Backend for Router {
    async fn complete(&mut self, history: Vec<Value>, allow_tools: bool) -> Result<Turn, String> {
        if !self.tools_ok {
            return self.plain(&history).await;
        }
        let body = build_chat_body(&self.model, &history, Some((&self.defaults, allow_tools)), self.memory_context.as_deref());
        match self.post(&body).await {
            Ok(text) => match parse_turn(&text) {
                Ok(turn) => return Ok(turn),
                // A 200 carrying an error object: treated like a 4xx.
                Err(err) if err.starts_with("9router error:") => {
                    crate::log::line("chat 9router refused the request with tools (error body)");
                }
                Err(err) => return Err(err),
            },
            Err((status, _)) if should_retry_without_tools(status) => {
                crate::log::line(format!("chat 9router refused the request with tools ({status})"));
            }
            Err((_, err)) => return Err(err),
        }
        self.tools_ok = false;
        let mut turn = self.plain(&history).await?;
        turn.note = Some(NO_TOOLS_NOTE.into());
        Ok(turn)
    }
}

/// One chat turn through 9router, with the task tools. History semantics match
/// claude::send: the user turn is dropped again if the call fails before any
/// action ran.
pub(crate) async fn send<R: ToolRunner>(
    chat: &Chat,
    base: &str,
    model: &str,
    query: String,
    context: Option<ChatContext>,
    memory_context: Option<String>,
    runner: &mut R,
) -> Result<ChatReply, String> {
    let base = normalize_base_url(base)?;
    let model = validate_model(model)?;
    let key = api_key()?;

    let mut content = if chat.is_empty() {
        claude::context_blocks(&context)
    } else {
        Vec::new()
    };
    if content
        .iter()
        .any(|b| b.get("type").and_then(Value::as_str) != Some("text"))
    {
        return Err(
            "9router chat takes text files only. PDFs and images need the Anthropic provider."
                .into(),
        );
    }
    content.push(json!({ "type": "text", "text": query }));

    let access = tools::ToolAccess::for_memory_context(memory_context.as_deref());
    let mut backend = Router { base, model, key, defaults: runner.defaults(), tools_ok: true, memory_context };
    tools::run_turn_with_access(chat, json!({ "role": "user", "content": content }), &mut backend, runner, access).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_url_accepts_https_and_strips_trailing_slashes() {
        assert_eq!(
            normalize_base_url(" https://192.168.123.45/9router/v1/ ").unwrap(),
            "https://192.168.123.45/9router/v1"
        );
        assert_eq!(
            normalize_base_url("https://router.example.com//").unwrap(),
            "https://router.example.com"
        );
        assert_eq!(
            normalize_base_url("https://router.example.com").unwrap(),
            "https://router.example.com"
        );
        assert_eq!(
            normalize_base_url("HTTPS://Router.Example.com/v1").unwrap(),
            "https://router.example.com/v1"
        );
    }

    #[test]
    fn base_url_allows_http_only_to_local_or_private_hosts() {
        for ok in [
            "http://localhost:20128/v1",
            "http://127.0.0.1/v1",
            "http://192.168.123.45/9router/v1",
            "http://10.0.0.5/v1",
            "http://172.16.1.1/v1",
            "http://[::1]:8080/v1",
            "http://[fd00::1]/v1",
        ] {
            assert!(normalize_base_url(ok).is_ok(), "{ok}");
        }
        for bad in [
            "http://router.example.com/v1",
            "http://8.8.8.8/v1",
            "http://172.32.0.1/v1",
            "ftp://192.168.123.45/v1",
            "file:///C:/x",
            "192.168.123.45/9router/v1",
            "https://user:pw@router.example.com/v1",
            "https://router.example.com/v1?x=1",
            "https://router.example.com/v1#frag",
            "",
            "   ",
        ] {
            assert!(normalize_base_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn model_ids_are_bounded() {
        assert_eq!(
            validate_model(" cc-claude-opus-5-5 ").unwrap(),
            "cc-claude-opus-5-5"
        );
        assert!(validate_model("").is_err());
        assert!(validate_model("a\nb").is_err());
        assert!(validate_model(&"x".repeat(201)).is_err());
    }

    #[test]
    fn models_are_parsed_sorted_and_deduplicated() {
        let body = r#"{"object":"list","data":[
            {"id":"cc-claude-opus-5-5","object":"model"},
            {"id":"gpt-5"},{"id":"cc-claude-opus-5-5"},{"id":""},{"no":"id"}]}"#;
        assert_eq!(
            parse_models(body).unwrap(),
            vec!["cc-claude-opus-5-5", "gpt-5"]
        );
        assert!(parse_models("{}").is_err());
        assert!(parse_models("not json").is_err());
        assert_eq!(
            parse_models(r#"{"data":[]}"#).unwrap(),
            Vec::<String>::new()
        );
    }

    #[test]
    fn error_bodies_are_readable() {
        assert_eq!(
            error_message(401, r#"{"error":"API key required for remote API access"}"#),
            "9router rejected the API key (401): API key required for remote API access"
        );
        assert_eq!(
            error_message(
                400,
                r#"{"error":{"message":"model not found","type":"invalid_request_error"}}"#
            ),
            "9router error 400: model not found"
        );
        assert_eq!(
            error_message(502, "Bad Gateway"),
            "9router error 502: Bad Gateway"
        );
        assert_eq!(error_message(500, ""), "9router error 500");
        assert!(error_message(500, &"x".repeat(5000)).len() < 260);
    }

    #[test]
    fn chat_body_has_system_prompt_history_and_no_stream() {
        let history = vec![
            json!({ "role": "user", "content": [
                { "type": "text", "text": "File: notes.txt" },
                { "type": "text", "text": "hi" }
            ] }),
            json!({ "role": "assistant", "content": [
                { "type": "server_tool_use", "id": "x", "name": "web_search" },
                { "type": "text", "text": "hello" }
            ] }),
            json!({ "role": "user", "content": [{ "type": "image", "source": {} }] }),
            json!({ "role": "user", "content": "again" }),
        ];
        let body = build_chat_body("cc-claude-opus-5-5", &history, None, None);
        assert_eq!(body["model"], "cc-claude-opus-5-5");
        assert_eq!(body["stream"], false);
        assert!(body.get("tools").is_none());
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 4);
        assert_eq!(messages[0]["role"], "system");
        assert!(messages[0]["content"].as_str().unwrap().contains("Mochi"));
        assert!(!messages[0]["content"]
            .as_str()
            .unwrap()
            .contains("web search"));
        assert!(!messages[0]["content"].as_str().unwrap().contains("start_task"));
        assert_eq!(
            messages[1],
            json!({ "role": "user", "content": "File: notes.txt\nhi" })
        );
        assert_eq!(
            messages[2],
            json!({ "role": "assistant", "content": "hello" })
        );
        assert_eq!(messages[3], json!({ "role": "user", "content": "again" }));

        let with_memory = build_chat_body("m", &history, None, Some("untrusted recalled data"));
        let memory_messages = with_memory["messages"].as_array().unwrap();
        assert_eq!(memory_messages[0], messages[0]);
        assert_eq!(memory_messages[1], json!({ "role": "developer", "content": "untrusted recalled data" }));
        assert!(!memory_messages[0]["content"].as_str().unwrap().contains("untrusted recalled data"));
    }

    #[test]
    fn chat_reply_is_parsed() {
        let ok = r#"{"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"  Bonjour  "},"finish_reason":"stop"}]}"#;
        let turn = parse_turn(ok).unwrap();
        assert_eq!(turn.text, "Bonjour");
        assert!(turn.calls.is_empty());
        assert_eq!(turn.blocks, vec![json!({ "type": "text", "text": "Bonjour" })]);
        let parts = r#"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#;
        assert_eq!(parse_turn(parts).unwrap().text, "a\nb");
        assert_eq!(parse_turn(r#"{"choices":[{"message":{"content":""}}]}"#).unwrap().text, "");
        assert!(parse_turn(r#"{"choices":[{"message":{"content":null}}]}"#).unwrap().blocks.is_empty());
        assert!(parse_turn(r#"{"choices":[]}"#).is_err());
        assert!(parse_turn(r#"{"choices":[{"message":null}]}"#).is_err());
        assert!(parse_turn("<html>").is_err());
        assert_eq!(
            parse_turn(r#"{"error":{"message":"upstream overloaded"}}"#).unwrap_err(),
            "9router error: upstream overloaded"
        );
        assert_eq!(
            parse_turn(r#"{"error":"quota"}"#).unwrap_err(),
            "9router error: quota"
        );
    }

    #[test]
    fn tool_calls_become_tool_use_blocks() {
        let body = r#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
            {"id":"call_1","type":"function","function":{"name":"start_task","arguments":"{\"agent\":\"codex\",\"prompt\":\"p\"}"}},
            {"id":"call_2","type":"function","function":{"name":"start_task","arguments":"oops"}}]},"finish_reason":"tool_calls"}]}"#;
        let turn = parse_turn(body).unwrap();
        assert_eq!(turn.text, "");
        assert_eq!(turn.calls.len(), 2);
        assert_eq!(turn.blocks[0], json!({ "type": "tool_use", "id": "call_1", "name": "start_task",
                                           "input": { "agent": "codex", "prompt": "p" } }));
        assert_eq!(turn.blocks[1]["input"], json!({}));
        assert_eq!(turn.calls[1].input, Value::Null);
    }

    #[test]
    fn tool_body_maps_history_to_openai_tool_messages() {
        let history = vec![
            json!({ "role": "user", "content": [{ "type": "text", "text": "start codex" }] }),
            json!({ "role": "assistant", "content": [
                { "type": "text", "text": "Sure." },
                { "type": "tool_use", "id": "toolu_1", "name": "start_task", "input": { "agent": "codex", "prompt": "p" } }
            ] }),
            json!({ "role": "user", "content": [
                { "type": "tool_result", "tool_use_id": "toolu_1", "content": "Started Codex (cli)." }
            ] }),
        ];
        let d = tools::ToolDefaults::default();
        let body = build_chat_body("m", &history, Some((&d, true)), None);
        assert_eq!(body["tool_choice"], "auto");
        assert_eq!(body["tools"][0]["function"]["name"], "start_task");
        let m = body["messages"].as_array().unwrap();
        assert!(m[0]["content"].as_str().unwrap().contains("start_task"));
        assert_eq!(m.len(), 4);
        assert_eq!(m[2]["role"], "assistant");
        assert_eq!(m[2]["content"], "Sure.");
        assert_eq!(m[2]["tool_calls"][0]["id"], "toolu_1");
        let args: Value = serde_json::from_str(m[2]["tool_calls"][0]["function"]["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(args, json!({ "agent": "codex", "prompt": "p" }));
        assert_eq!(m[3], json!({ "role": "tool", "tool_call_id": "toolu_1", "content": "Started Codex (cli)." }));
        assert_eq!(build_chat_body("m", &history, Some((&d, false)), None)["tool_choice"], "none");
        // Without tools the tool turns collapse to their text.
        let plain = build_chat_body("m", &history, None, None);
        assert_eq!(plain["messages"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn only_tool_refusals_fall_back_to_plain_chat() {
        for s in [400, 422] {
            assert!(should_retry_without_tools(s), "{s}");
        }
        for s in [0, 200, 401, 403, 404, 408, 429, 500, 502] {
            assert!(!should_retry_without_tools(s), "{s}");
        }
    }

    /// Real 9router + real launch: the model must call start_task and Codex
    /// must open in a new terminal. Uses the saved base URL (or the test URL
    /// below), the saved model, and the key from the Credential Manager.
    /// `cargo test -p coucou real_router_starts_codex -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn real_router_starts_codex() {
        struct Live {
            started: usize,
        }
        impl ToolRunner for Live {
            fn defaults(&self) -> tools::ToolDefaults {
                tools::ToolDefaults::default()
            }
            fn sessions(&self) -> Vec<tools::SessionInfo> {
                Vec::new()
            }
            async fn start(&mut self, request: crate::launch::LaunchRequest) -> Result<crate::launch::LaunchOutcome, String> {
                self.started += 1;
                crate::launch::execute(&request).map(|(_, o)| o)
            }
            fn robot(&mut self, _task: String) -> Result<String, String> {
                Err("Not in this test.".into())
            }
        }

        let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(r"..\target\launchtest");
        std::fs::create_dir_all(&folder).unwrap();
        let folder = crate::launch::strip_verbatim(&std::fs::canonicalize(&folder).unwrap().to_string_lossy());
        let settings = crate::settings::load();
        let base = if settings.router_base_url.trim().is_empty() {
            "https://hindsight.example.com/hindsight".to_string()
        } else {
            settings.router_base_url.clone()
        };
        let model = std::env::var("COUCOU_ROUTER_MODEL").unwrap_or(settings.model.clone());
        println!("base={base} model={model}");

        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let chat = Chat::default();
        let mut runner = Live { started: 0 };
        let query = format!("start a codex task in {folder} to reply with just: ok");
        let reply = rt
            .block_on(send(&chat, &base, &model, query, None, None, &mut runner))
            .expect("chat failed");
        println!("reply: {}", reply.text);
        for a in &reply.actions {
            println!("action: {} {} {} {} | {}", a.kind, a.agent, a.target, a.folder, a.message);
        }
        assert_eq!(runner.started, 1, "the model did not call start_task exactly once");
        assert_eq!(reply.actions.len(), 1);
        assert_eq!(reply.actions[0].kind, "started");
        assert_eq!(reply.actions[0].agent, "codex");
        assert_eq!(reply.actions[0].target, "cli");
        assert_eq!(reply.actions[0].folder, "launchtest");
    }
}
