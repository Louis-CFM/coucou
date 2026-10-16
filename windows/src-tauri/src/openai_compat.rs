// Cloud providers that speak the OpenAI chat completions API: OpenAI, Google AI
// (Gemini's OpenAI-compatible endpoint, as ClaudeService.swift uses it),
// OpenRouter and DeepSeek. One table describes them; one client talks to all of
// them.
//
// Same contract as claude.rs: the key never leaves the credential store and
// file bytes never cross the IPC boundary. Chat only — no tools are sent, so
// the model can answer but never act on the machine.

use std::time::Duration;

use reqwest::Url;
use serde_json::{json, Value};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::i18n::{t, tf};
use crate::{net, secrets};

pub struct Provider {
    pub id: &'static str,
    pub name: &'static str,
    pub base_url: &'static str,
    /// Credential store entry of its API key.
    pub key: &'static str,
    /// Relative to `base_url`.
    pub models_path: &'static str,
    pub default_model: &'static str,
    /// Model ids containing any of these are not chat models.
    pub not_chat: &'static [&'static str],
    /// OpenAI's reasoning models refuse `max_tokens` and want
    /// `max_completion_tokens`; the compatible APIs take the older name.
    pub max_tokens_field: &'static str,
    /// Extra JSON merged into every request body for this provider only.
    pub extra_body: Option<&'static str>,
    /// Model ids (a substring match) that read text only: a dropped picture is
    /// refused rather than sent, because a name it cannot see helps nobody.
    /// Empty when every model the provider offers takes a picture.
    pub text_only: &'static [&'static str],
    /// The model to point at when a picture meets a text-only one. Set
    /// wherever `text_only` is (a test holds the two together).
    pub alternative: Option<&'static str>,
}

pub const PROVIDERS: &[Provider] = &[
    Provider {
        id: "openai",
        name: "OpenAI",
        base_url: "https://api.openai.com/v1",
        key: "openai-api-key",
        models_path: "models",
        default_model: "gpt-4o",
        not_chat: &[
            "embed", "tts", "whisper", "dall-e", "audio", "realtime", "moderat", "codex",
            "computer-use", "transcribe", "image", "sora", "babbage", "davinci", "instruct",
        ],
        max_tokens_field: "max_completion_tokens",
        extra_body: None,
        text_only: &[],
        alternative: None,
    },
    Provider {
        id: "google",
        name: "Google AI",
        base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
        key: "google-api-key",
        models_path: "models",
        default_model: "gemini-2.0-flash",
        not_chat: &["embed", "imagen", "veo", "aqa", "tts", "audio", "live"],
        max_tokens_field: "max_tokens",
        extra_body: None,
        text_only: &[],
        alternative: None,
    },
    Provider {
        id: "openrouter",
        name: "OpenRouter",
        base_url: "https://openrouter.ai/api/v1",
        key: "openrouter-api-key",
        models_path: "models",
        default_model: "openrouter/auto",
        not_chat: &[],
        max_tokens_field: "max_tokens",
        extra_body: None,
        text_only: &[],
        alternative: None,
    },
    Provider {
        id: "deepseek",
        name: "DeepSeek",
        base_url: "https://api.deepseek.com/v1",
        key: "deepseek-api-key",
        models_path: "models",
        default_model: "deepseek-v4-pro",
        // Its list only ever holds chat models.
        not_chat: &[],
        max_tokens_field: "max_tokens",
        // V4 models think before answering by default: slower, and the
        // reasoning tokens come out of the same budget as the answer.
        extra_body: Some(r#"{"thinking":{"type":"disabled"}}"#),
        // The two models differ on pictures: flash sees them, v4-pro does not.
        text_only: &["v4-pro"],
        alternative: Some("deepseek-flash"),
    },
];

pub fn provider(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

const MAX_TOKENS: u32 = 4096;
/// Text and code files are inlined; anything larger is skipped.
const MAX_INLINE_TEXT: u64 = 200_000;
/// Images are sent inline as data URLs; past this size they are skipped.
const MAX_IMAGE: u64 = 5_000_000;

fn url(p: &Provider, tail: &str) -> Result<Url, String> {
    let base = Url::parse(p.base_url).map_err(|e| e.to_string())?;
    Url::parse(&net::join(&base, tail)).map_err(|e| e.to_string())
}

/// Whether the chosen model reads a dropped picture. A provider's models can
/// differ — DeepSeek's flash sees one, its v4-pro does not.
fn reads_images(p: &Provider, model: &str) -> bool {
    !p.text_only.iter().any(|text_only| model.contains(text_only))
}

/// A picture the chosen model cannot read: better said out loud, with the model
/// that can, than sent as a name the answer will quietly ignore.
fn text_only_refusal(
    p: &Provider,
    model: &str,
    first: bool,
    context: Option<&ChatContext>,
) -> Option<String> {
    if !first || reads_images(p, model) {
        return None;
    }
    let alternative = p.alternative?;
    let ChatContext::File { path, .. } = context? else { return None };
    image_media(path)?;
    Some(tf(
        "{name}'s {model} reads text only. Switch to {alternative} above the chat box to send a picture.",
        &[("name", p.name), ("model", model), ("alternative", alternative)],
    ))
}

/// The user's message for one turn: plain text, or text and an image part
/// when the first turn carries a dropped picture.
fn user_message(images: bool, first: bool, context: Option<&ChatContext>, query: &str) -> Value {
    let mut prefix = String::new();
    let mut image = None;
    match context.filter(|_| first) {
        Some(ChatContext::File { name, path }) => match file_part(path, images) {
            Some(FilePart::Image(part)) => {
                image = Some(part);
                prefix = format!("File: {name}\n\n");
            }
            Some(FilePart::Text(body)) => prefix = format!("File: {name}\nFile contents:\n{body}\n\n"),
            None => prefix = format!("File: {name}\n\n"),
        },
        Some(ChatContext::Window { app_name, title, url }) => {
            prefix = format!("{}\n\n", chat::window_line(app_name, title, url.as_deref()));
        }
        None => {}
    }
    let text = format!("{prefix}{query}");
    match image {
        None => json!({ "role": "user", "content": text }),
        Some(part) => json!({ "role": "user", "content": [part, { "type": "text", "text": text }] }),
    }
}

fn request_body(p: &Provider, model: &str, system: &str, history: &[Value], user: &Value) -> Value {
    let mut messages = vec![json!({ "role": "system", "content": system })];
    messages.extend(history.iter().cloned());
    messages.push(user.clone());
    let mut body = json!({ "model": model, "messages": messages });
    body[p.max_tokens_field] = json!(MAX_TOKENS);
    if let Some(extra) = p.extra_body {
        if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(extra) {
            for (name, value) in map {
                body[name] = value;
            }
        }
    }
    body
}

/// The answer's text, or the error the provider put in a 200 reply
/// (OpenRouter does when the upstream model fails).
fn reply_text(p: &Provider, response: &Value) -> Result<String, String> {
    let text = response
        .pointer("/choices/0/message/content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if !text.is_empty() {
        return Ok(text);
    }
    if let Some(msg) = response.pointer("/error/message").and_then(Value::as_str) {
        return Err(format!("{}: {msg}", p.name));
    }
    Err(t("No response text."))
}

fn status_error(p: &Provider, status: u16, detail: &str) -> String {
    match status {
        401 | 403 => tf(
            "{name} rejected the API key ({status}). Check it in Settings.",
            &[("name", p.name), ("status", &status.to_string())],
        ),
        402 => tf("{name}: not enough credits (402). {detail}", &[("name", p.name), ("detail", detail)]),
        404 => tf(
            "{name}: model not found (404). Pick another one above the chat box. {detail}",
            &[("name", p.name), ("detail", detail)],
        ),
        429 => tf("{name} rate limit reached (429): {detail}", &[("name", p.name), ("detail", detail)]),
        _ => format!("{} {status}: {detail}", p.name),
    }
}

/// One chat turn with a cloud provider.
pub async fn send(
    chat: &Chat,
    p: &'static Provider,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get(p.key).ok_or_else(|| tf("{name} API key missing. Add it in Settings.", &[("name", p.name)]))?;
    if model.is_empty() {
        return Err(tf("Pick a {name} model above the chat box.", &[("name", p.name)]));
    }
    let turn = chat.begin(p.id);
    if let Some(refusal) = text_only_refusal(p, model, turn.first, context.as_ref()) {
        return Err(refusal);
    }
    let user = user_message(reads_images(p, model), turn.first, context.as_ref(), &query);
    let body = request_body(p, model, &chat::system_prompt(false), &turn.history, &user);

    let endpoint = url(p, "chat/completions")?;
    let response = net::client(&endpoint, Duration::from_secs(90))?
        .post(endpoint)
        .bearer_auth(&key)
        .json(&body)
        .send()
        .await
        .map_err(|e| tf("Network error: {error}", &[("error", &e.to_string())]))?;
    let status = response.status();
    if !status.is_success() {
        let body = net::read_capped(response, net::MAX_ERROR_BODY).await.unwrap_or_default();
        return Err(status_error(p, status.as_u16(), &net::error_detail(&body)));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    let json: Value = serde_json::from_slice(&bytes).map_err(|e| tf("Bad API response: {error}", &[("error", &e.to_string())]))?;
    let text = reply_text(p, &json)?;

    let plain = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(&turn, user, json!({ "role": "assistant", "content": text }), &plain, &text);
    Ok(ChatReply { text })
}

/// The provider's chat models. Only ever asked with the user's key, once they
/// picked this provider in the chat.
pub async fn models(p: &Provider, key: &str) -> Result<Vec<ModelInfo>, String> {
    let endpoint = url(p, p.models_path)?;
    let response = net::client(&endpoint, Duration::from_secs(15))?
        .get(endpoint)
        .bearer_auth(key)
        .send()
        .await
        .map_err(|e| tf("Network error: {error}", &[("error", &e.to_string())]))?;
    let status = response.status();
    if !status.is_success() {
        let body = net::read_capped(response, net::MAX_ERROR_BODY).await.unwrap_or_default();
        return Err(status_error(p, status.as_u16(), &net::error_detail(&body)));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    let json: Value = serde_json::from_slice(&bytes).map_err(|_| t("Unexpected API response."))?;
    Ok(parse_models(p, &json))
}

fn parse_models(p: &Provider, json: &Value) -> Vec<ModelInfo> {
    let items = json.get("data").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut models: Vec<(ModelInfo, i64, bool)> = items
        .iter()
        .filter(|m| {
            // OpenRouter lists image and audio generators too.
            m.pointer("/architecture/output_modalities")
                .and_then(Value::as_array)
                .is_none_or(|mods| mods.iter().any(|x| x.as_str() == Some("text")))
        })
        .filter_map(|m| {
            let raw = m.get("id")?.as_str()?;
            // Gemini sometimes answers "models/gemini-…".
            let id = raw.strip_prefix("models/").unwrap_or(raw).to_string();
            let lower = id.to_lowercase();
            if id.is_empty() || p.not_chat.iter().any(|x| lower.contains(x)) {
                return None;
            }
            let created = m.get("created").and_then(Value::as_i64).unwrap_or(0);
            let free = p.id == "openrouter" && is_free(m, &id);
            let name = m.get("name").and_then(Value::as_str).unwrap_or(&id);
            let label = if free && !name.to_lowercase().contains("(free)") { format!("{name} (free)") } else { name.to_string() };
            Some((ModelInfo { id, label }, created, free))
        })
        .collect();
    match p.id {
        // Newest first, as on the Mac.
        "openai" => models.sort_by_key(|m| std::cmp::Reverse(m.1)),
        // Free models first, then by name.
        "openrouter" => models.sort_by(|a, b| {
            b.2.cmp(&a.2).then_with(|| a.0.label.to_lowercase().cmp(&b.0.label.to_lowercase()))
        }),
        _ => {}
    }
    models.into_iter().map(|(m, _, _)| m).collect()
}

fn is_free(m: &Value, id: &str) -> bool {
    let zero = |ptr: &str| {
        m.pointer(ptr)
            .and_then(Value::as_str)
            .is_some_and(|v| v.parse::<f64>().ok() == Some(0.0))
    };
    id.ends_with(":free") || (zero("/pricing/prompt") && zero("/pricing/completion"))
}

enum FilePart {
    Image(Value),
    Text(String),
}

/// The media type of a picture, by its extension.
fn image_media(path: &str) -> Option<&'static str> {
    match std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase()
        .as_str()
    {
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

/// Images → image_url data URL, text/code → inline text. PDFs and other binary
/// files go by name only (there is no portable document part).
fn file_part(path: &str, images: bool) -> Option<FilePart> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    let len = std::fs::metadata(path).ok()?.len();
    if let Some(media) = image_media(path) {
        if !images || len > MAX_IMAGE {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        let url = format!("data:{media};base64,{}", crate::claude::base64_for(&bytes));
        return Some(FilePart::Image(json!({ "type": "image_url", "image_url": { "url": url } })));
    }
    if ext == "pdf" || len > MAX_INLINE_TEXT {
        return None;
    }
    std::fs::read_to_string(path).ok().map(FilePart::Text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(id: &str) -> &'static Provider {
        provider(id).unwrap()
    }

    #[test]
    fn the_table_points_at_each_providers_own_api_and_key() {
        assert_eq!(url(p("openai"), "chat/completions").unwrap().as_str(), "https://api.openai.com/v1/chat/completions");
        assert_eq!(
            url(p("google"), "chat/completions").unwrap().as_str(),
            "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        );
        assert_eq!(url(p("openrouter"), "models").unwrap().as_str(), "https://openrouter.ai/api/v1/models");
        assert_eq!(url(p("deepseek"), "chat/completions").unwrap().as_str(), "https://api.deepseek.com/v1/chat/completions");
        for prov in PROVIDERS {
            assert!(crate::secrets::KNOWN_KEYS.contains(&prov.key), "{}", prov.key);
            assert!(prov.base_url.starts_with("https://"));
            // A provider's own body fields, where it has any, are a JSON object.
            if let Some(extra) = prov.extra_body {
                assert!(serde_json::from_str::<Value>(extra).unwrap().is_object(), "{}", prov.id);
            }
        }
        assert!(provider("anthropic").is_none());
        assert!(provider("ollama").is_none());
    }

    #[test]
    fn the_request_is_system_then_history_then_the_new_turn() {
        let history = vec![json!({"role":"user","content":"a"}), json!({"role":"assistant","content":"b"})];
        let user = user_message(true, false, None, "c");
        assert_eq!(user, json!({"role":"user","content":"c"}));
        let body = request_body(p("google"), "gemini-x", "sys", &history, &user);
        assert_eq!(body["model"], "gemini-x");
        assert_eq!(body["max_tokens"], MAX_TOKENS);
        let msgs = body["messages"].as_array().unwrap();
        assert_eq!(msgs.len(), 4);
        assert_eq!(msgs[0], json!({"role":"system","content":"sys"}));
        assert_eq!(msgs[3], user);
        assert!(body.get("tools").is_none(), "chat only: no tools");
        // OpenAI's reasoning models refuse the old field name.
        let body = request_body(p("openai"), "gpt-5", "sys", &[], &user);
        assert_eq!(body["max_completion_tokens"], MAX_TOKENS);
        assert!(body.get("max_tokens").is_none());
    }

    #[test]
    fn only_deepseek_is_asked_not_to_think() {
        let user = user_message(true, false, None, "hi");
        // V4 models think by default; the notch chat wants the answer only.
        let body = request_body(p("deepseek"), "deepseek-v4-pro", "sys", &[], &user);
        assert_eq!(body["thinking"]["type"], "disabled");
        assert_eq!(body["max_tokens"], MAX_TOKENS);
        assert!(body.get("max_completion_tokens").is_none());
        assert!(body.get("tools").is_none(), "chat only: no tools");
        // Nobody else is told anything it never asked for.
        for id in ["openai", "google", "openrouter"] {
            let body = request_body(p(id), "m", "sys", &[], &user);
            assert!(body.get("thinking").is_none(), "{id}");
        }
    }

    #[test]
    fn context_rides_with_the_first_turn_as_text_or_an_image() {
        let dir = std::env::temp_dir().join(format!("coucou-oai-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let txt = dir.join("notes.txt");
        std::fs::write(&txt, "hello").unwrap();
        let ctx = ChatContext::File { name: "notes.txt".into(), path: txt.to_string_lossy().into() };
        assert_eq!(
            user_message(true, true, Some(&ctx), "sum up")["content"],
            "File: notes.txt\nFile contents:\nhello\n\nsum up"
        );
        assert_eq!(user_message(true, false, Some(&ctx), "more")["content"], "more");

        let png = dir.join("pic.png");
        std::fs::write(&png, [0x89, b'P', b'N', b'G']).unwrap();
        let ctx = ChatContext::File { name: "pic.png".into(), path: png.to_string_lossy().into() };
        let msg = user_message(true, true, Some(&ctx), "what is it?");
        let parts = msg["content"].as_array().unwrap();
        assert_eq!(parts[0]["type"], "image_url");
        assert!(parts[0]["image_url"]["url"].as_str().unwrap().starts_with("data:image/png;base64,"));
        assert_eq!(parts[1], json!({"type":"text","text":"File: pic.png\n\nwhat is it?"}));

        let pdf = dir.join("doc.pdf");
        std::fs::write(&pdf, "%PDF").unwrap();
        let ctx = ChatContext::File { name: "doc.pdf".into(), path: pdf.to_string_lossy().into() };
        assert_eq!(user_message(true, true, Some(&ctx), "q")["content"], "File: doc.pdf\n\nq");
        let _ = std::fs::remove_dir_all(dir);

        let ctx = ChatContext::Window { app_name: "Code".into(), title: "x".into(), url: None };
        assert_eq!(user_message(true, true, Some(&ctx), "q")["content"], "Context — App: Code, Window: x\n\nq");
    }

    #[test]
    fn deepseeks_two_models_differ_on_pictures() {
        let deepseek = p("deepseek");
        assert!(!reads_images(deepseek, "deepseek-v4-pro"));
        assert!(reads_images(deepseek, "deepseek-flash"));
        // Every other provider takes a picture with any of its models.
        for id in ["openai", "google", "openrouter"] {
            assert!(reads_images(p(id), "whatever"), "{id}");
        }

        let dir = std::env::temp_dir().join(format!("coucou-image-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let png = dir.join("pic.png");
        std::fs::write(&png, [0x89, b'P', b'N', b'G']).unwrap();
        let ctx = ChatContext::File { name: "pic.png".into(), path: png.to_string_lossy().into() };

        // v4-pro says to switch rather than sending a name it cannot see.
        let refusal = text_only_refusal(deepseek, "deepseek-v4-pro", true, Some(&ctx)).unwrap();
        assert!(refusal.contains("deepseek-flash"), "{refusal}");
        assert!(refusal.contains("reads text only"), "{refusal}");
        // flash carries it, and a later turn never carries the file anyway.
        assert!(text_only_refusal(deepseek, "deepseek-flash", true, Some(&ctx)).is_none());
        assert!(text_only_refusal(deepseek, "deepseek-v4-pro", false, Some(&ctx)).is_none());
        // Text files and windows are not pictures: nothing to refuse.
        let txt = dir.join("notes.txt");
        std::fs::write(&txt, "hello").unwrap();
        let notes = ChatContext::File { name: "notes.txt".into(), path: txt.to_string_lossy().into() };
        assert!(text_only_refusal(deepseek, "deepseek-v4-pro", true, Some(&notes)).is_none());
        let window = ChatContext::Window { app_name: "Code".into(), title: "x".into(), url: None };
        assert!(text_only_refusal(deepseek, "deepseek-v4-pro", true, Some(&window)).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_text_only_model_always_names_one_to_switch_to() {
        for prov in PROVIDERS {
            assert_eq!(
                prov.text_only.is_empty(),
                prov.alternative.is_none(),
                "{}: text_only and alternative go together",
                prov.id
            );
        }
    }

    #[test]
    fn the_reply_text_or_the_error_inside_a_200_is_read() {
        let ok = json!({"choices":[{"message":{"role":"assistant","content":"  Hi!  "}}]});
        assert_eq!(reply_text(p("openai"), &ok).unwrap(), "Hi!");
        let failed = json!({"error":{"message":"upstream down"}});
        assert_eq!(reply_text(p("openrouter"), &failed).unwrap_err(), "OpenRouter: upstream down");
        assert_eq!(reply_text(p("google"), &json!({"choices":[]})).unwrap_err(), "No response text.");
    }

    #[test]
    fn status_errors_say_what_to_do() {
        assert!(status_error(p("openai"), 401, "x").contains("rejected the API key"));
        assert!(status_error(p("openrouter"), 402, "x").contains("credits"));
        assert_eq!(status_error(p("google"), 500, "boom"), "Google AI 500: boom");
    }

    #[test]
    fn model_lists_keep_chat_models_only() {
        let openai = json!({"data":[
            {"id":"gpt-4o","created":100},
            {"id":"text-embedding-3-small","created":300},
            {"id":"gpt-5-mini","created":200},
            {"id":"whisper-1","created":400},
            {"id":"dall-e-3","created":500}
        ]});
        let ids: Vec<_> = parse_models(p("openai"), &openai).into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["gpt-5-mini", "gpt-4o"]);

        let google = json!({"data":[
            {"id":"models/gemini-2.0-flash"},
            {"id":"models/text-embedding-004"},
            {"id":"gemini-2.5-pro"},
            {"id":"models/imagen-3.0"}
        ]});
        let ids: Vec<_> = parse_models(p("google"), &google).into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["gemini-2.0-flash", "gemini-2.5-pro"]);

        let openrouter = json!({"data":[
            {"id":"b/paid","name":"B Paid","pricing":{"prompt":"0.000001","completion":"0.000002"}},
            {"id":"a/free:free","name":"A (free)"},
            {"id":"c/zero","name":"C Zero","pricing":{"prompt":"0","completion":"0"}},
            {"id":"d/image","name":"D Image","architecture":{"output_modalities":["image"]}}
        ]});
        let models = parse_models(p("openrouter"), &openrouter);
        let labels: Vec<_> = models.iter().map(|m| m.label.as_str()).collect();
        assert_eq!(labels, vec!["A (free)", "C Zero (free)", "B Paid"]);

        // DeepSeek lists its models with no `created` and no `name`: there is
        // nothing to sort on, and the id is the label.
        let deepseek = json!({"object":"list","data":[
            {"id":"deepseek-flash","object":"model","owned_by":"deepseek"},
            {"id":"deepseek-v4-pro","object":"model","owned_by":"deepseek"}
        ]});
        let shown: Vec<_> = parse_models(p("deepseek"), &deepseek)
            .into_iter()
            .map(|m| (m.id, m.label))
            .collect();
        assert_eq!(
            shown,
            vec![
                ("deepseek-flash".to_string(), "deepseek-flash".to_string()),
                ("deepseek-v4-pro".to_string(), "deepseek-v4-pro".to_string())
            ]
        );
    }

    #[test]
    fn an_unknown_answer_gives_an_empty_list() {
        assert!(parse_models(p("openai"), &json!({"nope":true})).is_empty());
    }
}
