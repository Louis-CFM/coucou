// Chat through Open WebUI, so the conversation also lands in its chat history.
//
// The chat is created in Open WebUI first; every turn then goes to its
// completion endpoint with that chat's id, and Open WebUI stores the question
// and the answer itself, the same way its own page does. The model's context
// comes from that stored history, so only the new question is sent.
//
// Like the other model servers, the address the user connected is the only
// place this module talks to, and the key only ever goes there.

use std::collections::HashMap;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use reqwest::Url;
use serde_json::{json, Map, Value};
use tauri::{AppHandle, Emitter};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo, Thread};
use crate::i18n::t;
use crate::island::WINDOW_LABEL;
use crate::local_chat::{self, Server};
use crate::net;

pub const ID: &str = "openwebui";
/// Credential store entry of the Open WebUI API key, bound to its address.
pub const KEY: &str = "open-webui-key";

/// Open WebUI answers a whole turn at once: the model may take its time.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(300);
const QUICK_TIMEOUT: Duration = Duration::from_secs(15);
/// A model set to stream in Open WebUI answers into the chat, not the request:
/// the stored chat is read until the answer is done.
const POLL_INTERVAL: Duration = Duration::from_secs(1);
const POLL_ROUNDS: u32 = 300;

fn need_key() -> String {
    t("Add an Open WebUI API key in Settings → Local models first.")
}

/// `Authorization` for Open WebUI, which refuses requests without a key.
fn auth(key: Option<&str>) -> Result<String, String> {
    match key.filter(|k| !k.is_empty()) {
        Some(k) => Ok(local_chat::bearer(Some(k))),
        None => Err(need_key()),
    }
}

/// A request that failed: the HTTP status when the server answered, and what to show.
struct Failure {
    status: Option<u16>,
    message: String,
}

impl From<String> for Failure {
    fn from(message: String) -> Self {
        Failure { status: None, message }
    }
}

impl From<Failure> for String {
    fn from(f: Failure) -> Self {
        f.message
    }
}

async fn get_json(base: &Url, key: Option<&str>, path: &str) -> Result<Value, Failure> {
    let request = net::client(base, QUICK_TIMEOUT)?.get(net::join(base, path));
    call(base, key, request).await
}

async fn post_json(base: &Url, key: Option<&str>, path: &str, body: &Value, timeout: Duration) -> Result<Value, Failure> {
    let request = net::client(base, timeout)?.post(net::join(base, path)).json(body);
    call(base, key, request).await
}

async fn call(base: &Url, key: Option<&str>, request: reqwest::RequestBuilder) -> Result<Value, Failure> {
    let response = request
        .header("Authorization", auth(key)?)
        .send()
        .await
        .map_err(|_| local_chat::unreachable(base))?;
    let status = response.status().as_u16();
    if matches!(status, 401 | 403) {
        return Err(Failure { status: Some(status), message: t("The server refused the key. Check it, then connect again.") });
    }
    if !response.status().is_success() {
        let body = net::read_capped(response, net::MAX_ERROR_BODY).await.unwrap_or_default();
        let detail = net::error_detail(&body);
        let message = if detail.is_empty() { format!("HTTP {status}") } else { detail };
        return Err(Failure { status: Some(status), message });
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    // A streamed turn answers `null`: the answer is in the stored chat.
    match serde_json::from_slice(&bytes) {
        Ok(v) => Ok(v),
        Err(_) if bytes.is_empty() => Ok(Value::Null),
        Err(_) => Err(local_chat::unreachable(base).into()),
    }
}

/// True when Open WebUI says the chat is not there any more.
async fn chat_gone(base: &Url, key: Option<&str>, chat_id: &str) -> bool {
    matches!(get_json(base, key, &format!("api/v1/chats/{chat_id}")).await, Err(Failure { status: Some(404 | 401), .. }))
}

// ── Models ────────────────────────────────────────────────────────────────────

/// `GET /api/models`: the models this account may use, by id and name.
pub async fn list(base: &Url, key: Option<&str>) -> Result<Vec<ModelInfo>, String> {
    let body = get_json(base, key, "api/models").await.map_err(String::from)?;
    parse_models(&body).ok_or_else(|| local_chat::unreachable(base))
}

fn parse_models(body: &Value) -> Option<Vec<ModelInfo>> {
    let items = body.get("data")?.as_array()?;
    Some(
        items
            .iter()
            .filter_map(|m| {
                let id = m.get("id")?.as_str()?.to_string();
                let label = m.get("name").and_then(Value::as_str).filter(|n| !n.is_empty()).unwrap_or(&id).to_string();
                // A model made in Open WebUI's workspace sits on a base model.
                let custom = m.pointer("/info/base_model_id").and_then(Value::as_str).is_some_and(|b| !b.is_empty());
                Some(ModelInfo { id, label, group: custom.then_some(GROUP_CUSTOM) })
            })
            .collect(),
    )
}

const GROUP_USED: &str = "used";
const GROUP_CUSTOM: &str = "custom";
/// How many of the most used models lead the list.
const MOST_USED: usize = 8;
/// "Most used" counts the messages of this many days.
const USAGE_DAYS: u64 = 90;

/// Messages per model over the last `USAGE_DAYS`, from Open WebUI's analytics.
/// Only an admin's key may read them; anyone else gets the list unranked.
async fn usage(base: &Url, key: Option<&str>) -> HashMap<String, u64> {
    let since = now_secs().saturating_sub(USAGE_DAYS * 24 * 3600);
    let Ok(body) = get_json(base, key, &format!("api/v1/analytics/models?start_date={since}")).await else {
        return HashMap::new();
    };
    parse_usage(&body)
}

fn parse_usage(body: &Value) -> HashMap<String, u64> {
    let Some(items) = body.get("models").and_then(Value::as_array) else { return HashMap::new() };
    items
        .iter()
        .filter_map(|m| Some((m.get("model_id")?.as_str()?.to_string(), m.get("count")?.as_u64()?)))
        .collect()
}

/// The most used models first, then the workspace's own models, then the rest
/// by name.
fn rank(mut models: Vec<ModelInfo>, usage: &HashMap<String, u64>) -> Vec<ModelInfo> {
    let mut used: Vec<(u64, usize)> = models
        .iter()
        .enumerate()
        .filter_map(|(i, m)| usage.get(&m.id).filter(|n| **n > 0).map(|n| (*n, i)))
        .collect();
    used.sort_by(|a, b| b.0.cmp(&a.0));
    used.truncate(MOST_USED);
    for (_, i) in &used {
        models[*i].group = Some(GROUP_USED);
    }
    let order = |m: &ModelInfo| match m.group {
        Some(GROUP_USED) => (0, std::cmp::Reverse(usage.get(&m.id).copied().unwrap_or(0)), String::new()),
        Some(_) => (1, std::cmp::Reverse(0), m.label.to_lowercase()),
        None => (2, std::cmp::Reverse(0), m.label.to_lowercase()),
    };
    models.sort_by_cached_key(order);
    models
}

pub async fn models(server: &Server) -> Result<Vec<ModelInfo>, String> {
    let base = local_chat::base_url(server)?;
    let models = list(&base, server.key.as_deref()).await?;
    if models.is_empty() {
        return Err(t("Open WebUI has no models for this account."));
    }
    Ok(rank(models, &usage(&base, server.key.as_deref()).await))
}

// ── Messages as Open WebUI stores them ────────────────────────────────────────

/// A new message id. Not a secret, only unique: two hashers with fresh random
/// keys from the standard library, laid out as a version 4 UUID like the ids
/// Open WebUI makes itself.
fn new_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut bytes = [0u8; 16];
    for half in bytes.chunks_mut(8) {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u128(nanos);
        half.copy_from_slice(&h.finish().to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// One message of the chat's history tree.
fn node(id: &str, parent: Option<&str>, role: &str, content: &str, model: &str, at: u64) -> Value {
    let mut n = json!({
        "id": id, "parentId": parent, "childrenIds": [], "role": role,
        "content": content, "timestamp": at,
    });
    if role == "assistant" {
        n["model"] = json!(model);
        n["modelName"] = json!(model);
        n["modelIdx"] = json!(0);
        n["done"] = json!(true);
    } else {
        n["models"] = json!([model]);
    }
    n
}

/// A new chat holding the turns another provider answered before, so Open
/// WebUI's copy of the conversation is complete. Returns it with the id of
/// its last message.
fn new_chat(history: &[Value], model: &str, at: u64) -> (Value, Option<String>) {
    let mut messages = Map::new();
    let mut list = Vec::new();
    let mut last: Option<String> = None;
    for turn in history {
        let (Some(role), Some(content)) = (turn["role"].as_str(), turn["content"].as_str()) else { continue };
        let id = new_id();
        let n = node(&id, last.as_deref(), role, content, model, at);
        if let Some(parent) = last.as_deref().and_then(|p| messages.get_mut(p)) {
            parent["childrenIds"].as_array_mut().unwrap().push(json!(id));
        }
        list.push(json!({ "id": id, "role": role, "content": content, "timestamp": at }));
        messages.insert(id.clone(), n);
        last = Some(id);
    }
    let chat = json!({
        "chat": {
            "title": "New Chat",
            "models": [model],
            "history": { "messages": messages, "currentId": last },
            "messages": list,
            "tags": [],
            "timestamp": at * 1000,
        }
    });
    (chat, last)
}

/// The turn: Open WebUI stores `user_message` under `parent` and the answer
/// under `answer_id`, names the chat after a first exchange, and searches the
/// web first when asked to. Its search only runs for a turn whose function
/// calling is `legacy`; `native` would hand the model a tool coucou has no
/// loop to answer, so the turn says so when searching.
#[allow(clippy::too_many_arguments)]
fn completion(model: &str, system: &str, thread: &Thread, user_id: &str, answer_id: &str, text: &str, at: u64, web_search: bool) -> Value {
    let mut body = json!({
        "features": { "web_search": web_search },
        "model": model,
        "stream": false,
        "chat_id": thread.id,
        "id": answer_id,
        "parent_id": thread.last,
        "messages": [
            { "role": "system", "content": system },
            { "role": "user", "content": text },
        ],
        "user_message": node(user_id, thread.last.as_deref(), "user", text, model, at),
        "background_tasks": { "title_generation": thread.last.is_none() },
    });
    if web_search {
        body["params"] = json!({ "function_calling": "legacy" });
    }
    body
}

/// Only `{{NAME}}` keys with short values go on: the page is ours, but what
/// reaches a server is checked here.
fn template_variables(variables: chat::PromptVariables) -> chat::PromptVariables {
    let name = |k: &str| {
        k.len() <= 40
            && k.strip_prefix("{{").and_then(|k| k.strip_suffix("}}")).is_some_and(|n| {
                !n.is_empty() && n.chars().all(|c| c.is_ascii_uppercase() || c == '_')
            })
    };
    variables.into_iter().filter(|(k, v)| name(k) && v.len() <= 100).collect()
}

fn answer_in_reply(reply: &Value) -> Option<String> {
    reply.pointer("/choices/0/message/content").and_then(Value::as_str).map(str::to_string)
}

/// The answer as the stored chat has it: its text, and whether it is finished.
fn answer_in_chat(chat: &Value, answer_id: &str) -> Option<(String, bool)> {
    let m = chat.pointer("/chat/history/messages")?.get(answer_id)?;
    let text = m.get("content").and_then(Value::as_str).unwrap_or("").to_string();
    Some((text, m.get("done").and_then(Value::as_bool).unwrap_or(false)))
}

/// What Open WebUI wrote on the answer when a filter or the model failed.
fn error_in_chat(chat: &Value, answer_id: &str) -> Option<String> {
    let m = chat.pointer("/chat/history/messages")?.get(answer_id)?;
    let e = m.get("error")?;
    e.get("content").and_then(Value::as_str).or_else(|| e.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

/// Reads the stored chat until the answer is done, showing it as it grows.
async fn wait_for_answer(app: &AppHandle, base: &Url, key: Option<&str>, chat_id: &str, answer_id: &str) -> Result<String, String> {
    let path = format!("api/v1/chats/{chat_id}");
    for _ in 0..POLL_ROUNDS {
        tokio::time::sleep(POLL_INTERVAL).await;
        let stored = get_json(base, key, &path).await.map_err(String::from)?;
        if let Some((text, done)) = answer_in_chat(&stored, answer_id) {
            let _ = app.emit_to(WINDOW_LABEL, "chat-delta", local_chat::filter_thinking_blocks(&text));
            if done {
                return match error_in_chat(&stored, answer_id) {
                    Some(error) if text.trim().is_empty() => Err(error),
                    _ => Ok(text),
                };
            }
        }
    }
    Err(t("No response text."))
}

// ── A turn ────────────────────────────────────────────────────────────────────

pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    server: &Server,
    model: &str,
    query: String,
    context: Option<ChatContext>,
    variables: chat::PromptVariables,
    web_search: bool,
) -> Result<ChatReply, String> {
    let base = local_chat::base_url(server)?;
    let key = server.key.as_deref();
    auth(key)?;
    if model.is_empty() {
        return Err(t("Pick a model above the chat box first."));
    }
    let turn = chat.begin(ID);
    let at = now_secs();

    let thread = match turn.thread.clone() {
        Some(thread) => thread,
        None => {
            let (body, last) = new_chat(&turn.history, model, at);
            let created = post_json(&base, key, "api/v1/chats/new", &body, QUICK_TIMEOUT).await.map_err(String::from)?;
            let id = created.get("id").and_then(Value::as_str).ok_or_else(|| local_chat::unreachable(&base))?;
            let thread = Thread { id: id.to_string(), last };
            // Kept even if this turn fails, so a retry lands in the same chat.
            chat.set_thread(&turn, Some(thread.clone()));
            thread
        }
    };

    let text = local_chat::user_text(turn.first, context.as_ref(), &query);
    let (user_id, answer_id) = (new_id(), new_id());
    let system = chat::system_prompt(web_search);
    let mut body = completion(model, &system, &thread, &user_id, &answer_id, &text, at, web_search);
    body["variables"] = json!(template_variables(variables));
    let reply = match post_json(&base, key, "api/chat/completions", &body, ANSWER_TIMEOUT).await {
        Ok(reply) => reply,
        // A missing model is a 404 too: only a chat that is gone starts a new one.
        Err(f) if f.status == Some(404) && chat_gone(&base, key, &thread.id).await => {
            chat.set_thread(&turn, None);
            return Err(t("This chat was deleted in Open WebUI. Send again to start a new one."));
        }
        Err(f) => return Err(f.message),
    };
    let answer = match answer_in_reply(&reply).filter(|a| !a.trim().is_empty()) {
        Some(answer) => answer,
        None => wait_for_answer(app, &base, key, &thread.id, &answer_id).await?,
    };
    if answer.trim().is_empty() {
        let stored = get_json(&base, key, &format!("api/v1/chats/{}", thread.id)).await.map_err(String::from)?;
        if let Some(error) = error_in_chat(&stored, &answer_id) {
            return Err(error);
        }
    }
    let answer = local_chat::filter_thinking_blocks(&answer);
    if answer.is_empty() {
        return Err(t("No response text."));
    }

    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(&turn, json!({ "role": "user", "content": text }), json!({ "role": "assistant", "content": answer }), &plain, &answer);
    chat.set_thread(&turn, Some(Thread { id: thread.id, last: Some(answer_id) }));
    Ok(ChatReply { text: answer })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::tests::serve_once;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn the_key_has_a_credential_store_entry() {
        assert!(crate::secrets::KNOWN_KEYS.contains(&KEY));
        assert_eq!(local_chat::key_entry(ID), Some(KEY));
    }

    #[test]
    fn ids_look_like_uuids_and_never_repeat() {
        let a = new_id();
        assert_eq!(a.len(), 36);
        assert_eq!(&a[14..15], "4");
        assert!(a.chars().all(|c| c == '-' || c.is_ascii_hexdigit()));
        let ids: std::collections::HashSet<String> = (0..1000).map(|_| new_id()).collect();
        assert_eq!(ids.len(), 1000);
    }

    #[test]
    fn a_new_chat_carries_the_earlier_turns_as_a_linked_history() {
        let (body, last) = new_chat(&[], "m", 10);
        assert_eq!(last, None);
        assert_eq!(body.pointer("/chat/models"), Some(&json!(["m"])));
        assert_eq!(body.pointer("/chat/history/currentId"), Some(&Value::Null));

        let history = [json!({"role":"user","content":"hi"}), json!({"role":"assistant","content":"hello"})];
        let (body, last) = new_chat(&history, "m", 10);
        let messages = body.pointer("/chat/history/messages").unwrap().as_object().unwrap();
        assert_eq!(messages.len(), 2);
        let answer = &messages[last.as_deref().unwrap()];
        assert_eq!(answer["role"], "assistant");
        assert_eq!(answer["done"], true);
        let question = &messages[answer["parentId"].as_str().unwrap()];
        assert_eq!(question["content"], "hi");
        assert_eq!(question["childrenIds"], json!([last.unwrap()]));
        assert_eq!(body.pointer("/chat/messages").unwrap().as_array().unwrap().len(), 2);
    }

    #[test]
    fn a_turn_names_its_chat_and_hangs_under_the_last_answer() {
        let first = Thread { id: "c".into(), last: None };
        let body = completion("m", "sys", &first, "u", "a", "q", 5, true);
        assert_eq!(body.pointer("/features/web_search"), Some(&json!(true)));
        assert_eq!(body.pointer("/params/function_calling"), Some(&json!("legacy")));
        assert_eq!(body["chat_id"], "c");
        assert_eq!(body["id"], "a");
        assert_eq!(body["stream"], false);
        assert_eq!(body.pointer("/user_message/id"), Some(&json!("u")));
        assert_eq!(body.pointer("/user_message/parentId"), Some(&Value::Null));
        assert_eq!(body.pointer("/background_tasks/title_generation"), Some(&json!(true)));
        let later = Thread { id: "c".into(), last: Some("a0".into()) };
        let body = completion("m", "sys", &later, "u", "a", "q", 5, false);
        assert_eq!(body.pointer("/features/web_search"), Some(&json!(false)));
        assert!(body.get("params").is_none());
        assert_eq!(body.pointer("/user_message/parentId"), Some(&json!("a0")));
        assert_eq!(body["parent_id"], "a0");
        assert_eq!(body.pointer("/background_tasks/title_generation"), Some(&json!(false)));
    }

    #[test]
    fn the_answer_comes_from_the_reply_or_from_the_stored_chat() {
        let reply = json!({"choices":[{"message":{"role":"assistant","content":"Hi!"}}]});
        assert_eq!(answer_in_reply(&reply).as_deref(), Some("Hi!"));
        assert_eq!(answer_in_reply(&Value::Null), None);
        let stored = json!({"chat":{"history":{"messages":{"a":{"content":"Hal","done":false}}}}});
        assert_eq!(answer_in_chat(&stored, "a"), Some(("Hal".into(), false)));
        assert_eq!(answer_in_chat(&stored, "b"), None);
        // A filter that failed leaves its message on the answer.
        let failed = json!({"chat":{"history":{"messages":{"a":{"content":"","done":true,"error":{"content":"ZoneInfo keys must be normalized relative paths, got: "}}}}}});
        assert_eq!(error_in_chat(&failed, "a").as_deref(), Some("ZoneInfo keys must be normalized relative paths, got:"));
        assert_eq!(error_in_chat(&stored, "a"), None);
    }

    #[test]
    fn models_are_listed_by_name_and_a_missing_key_is_refused_before_any_request() {
        let body = json!({"data":[{"id":"llama3","name":"Llama 3"},{"id":"bare"}]});
        let models = parse_models(&body).unwrap();
        assert_eq!(models[0], ModelInfo { id: "llama3".into(), label: "Llama 3".into(), group: None });
        assert_eq!(models[1].label, "bare");

        let raw = br#"{"data":[{"id":"m","name":"M"}]}"#;
        let u = serve_once("200 OK", &format!("Content-Length: {}\r\n", raw.len()), raw.to_vec());
        let base = net::normalise_server_url(&u).unwrap();
        assert_eq!(block_on(list(&base, Some("sk-x"))).unwrap()[0].id, "m");
        assert_eq!(block_on(list(&base, None)).unwrap_err(), need_key());
    }

    #[test]
    fn a_missing_chat_is_told_from_any_other_failure() {
        let gone = br#"{"detail":"We could not find what you're looking for :/"}"#;
        let u = serve_once("404 Not Found", &format!("Content-Length: {}\r\n", gone.len()), gone.to_vec());
        assert!(block_on(chat_gone(&net::normalise_server_url(&u).unwrap(), Some("sk-x"), "c")));
        let u = serve_once("500 Internal Server Error", "Content-Length: 2\r\n", b"{}".to_vec());
        assert!(!block_on(chat_gone(&net::normalise_server_url(&u).unwrap(), Some("sk-x"), "c")));
    }

    #[test]
    fn the_most_used_lead_then_the_workspace_models_then_the_rest_by_name() {
        let body = json!({"data": [
            {"id": "zeta", "name": "Zeta"},
            {"id": "reviewer", "name": "Code Reviewer", "info": {"base_model_id": "gpt"}},
            {"id": "gpt", "name": "GPT"},
            {"id": "alpha", "name": "alpha"},
            {"id": "summarizer", "name": "Summarizer", "info": {"base_model_id": "gpt"}},
            {"id": "plain", "name": "Plain", "info": {"base_model_id": null}}
        ]});
        let usage = parse_usage(&json!({"models": [
            {"model_id": "summarizer", "count": 42}, {"model_id": "gpt", "count": 17},
            {"model_id": "gone", "count": 9}, {"model_id": "zeta", "count": 0}
        ]}));
        let ranked = rank(parse_models(&body).unwrap(), &usage);
        let ids: Vec<&str> = ranked.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["summarizer", "gpt", "reviewer", "alpha", "plain", "zeta"]);
        let groups: Vec<Option<&str>> = ranked.iter().map(|m| m.group).collect();
        assert_eq!(groups, [Some("used"), Some("used"), Some("custom"), None, None, None]);
        // Without analytics (not an admin) nothing is "used".
        let unranked = rank(parse_models(&body).unwrap(), &HashMap::new());
        assert_eq!(unranked[0].id, "reviewer");
        assert!(unranked.iter().all(|m| m.group != Some("used")));
    }

    #[test]
    fn only_template_variables_go_to_the_server() {
        let mut v = chat::PromptVariables::new();
        v.insert("{{CURRENT_TIMEZONE}}".into(), "Europe/Paris".into());
        v.insert("{{CURRENT_DATETIME}}".into(), "2026-10-10 18:05:00".into());
        v.insert("token".into(), "x".into());
        v.insert("{{lower}}".into(), "x".into());
        v.insert("{{LONG}}".into(), "x".repeat(101));
        let kept = template_variables(v);
        assert_eq!(kept.keys().collect::<Vec<_>>(), ["{{CURRENT_DATETIME}}", "{{CURRENT_TIMEZONE}}"]);
    }

    #[test]
    fn a_streamed_turn_answers_null() {
        let u = serve_once("200 OK", "Content-Length: 4\r\n", b"null".to_vec());
        let base = net::normalise_server_url(&u).unwrap();
        let reply = block_on(post_json(&base, Some("sk-x"), "api/chat/completions", &json!({}), QUICK_TIMEOUT)).ok().unwrap();
        assert_eq!(answer_in_reply(&reply), None);
    }
}
