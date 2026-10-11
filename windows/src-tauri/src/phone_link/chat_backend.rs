// The real chat behind the phone link (chat.rs holds the rules): the same provider code as the
// island's chat, with the phone's own conversation. The key is read inside `claude`, `openai_compat`
// or `local_chat` from the credential store; nothing in this file ever holds one.
//
// Failures are sorted into a few kinds here and only the kind goes on: a provider's message may
// contain part of a key, so it is neither forwarded nor logged.

use std::sync::Arc;

use tauri::{AppHandle, Manager};
use tokio::sync::mpsc::UnboundedSender;

use super::chat::{BoxFuture, ChatBackend, ChatConfig, ChatFail, ModelOption};
use crate::chat::Chat;
use crate::settings::Settings;
use crate::{chat, claude, log, openai_compat, secrets, Shared};

/// Most models the user can allow, and the longest model name taken.
pub const MAX_ALLOWED: usize = 50;
const MAX_MODEL_CHARS: usize = 200;

const PROVIDERS: [&str; 7] = ["anthropic", "google", "openai", "openrouter", "ollama", "lmstudio", "custom"];

pub struct AppChat {
    app: AppHandle,
    chat: Arc<Chat>,
}

impl AppChat {
    pub fn new(app: AppHandle) -> Self {
        Self { app, chat: Arc::new(Chat::default()) }
    }

    fn settings(&self) -> Settings {
        self.app.state::<Shared>().settings.lock().unwrap().clone()
    }
}

impl ChatBackend for AppChat {
    fn config(&self) -> ChatConfig {
        let s = self.settings();
        ChatConfig { enabled: s.phone_chat, allowed: options(&s.phone_chat_models) }
    }

    fn send(&self, model_id: &str, text: String, deltas: UnboundedSender<String>) -> BoxFuture<Result<String, ChatFail>> {
        let settings = self.settings();
        let chat = self.chat.clone();
        let id = model_id.to_string();
        Box::pin(async move {
            let Some((provider, model)) = parse_model_id(&id) else { return Err(ChatFail::Internal) };
            if let Some(key) = key_name(provider) {
                if secrets::get(key).is_none() {
                    return Err(ChatFail::NoKey);
                }
            }
            let result = chat::send_for_phone(&settings, &chat, provider, model, text, |so_far| {
                let _ = deltas.send(so_far);
            })
            .await;
            match result {
                Ok(reply) => Ok(reply.text),
                Err(err) => {
                    let kind = classify(is_local(provider), &err);
                    // The kind only: the text may echo a key.
                    log::line(format!("phone link: chat via {provider} failed ({kind:?})"));
                    Err(kind)
                }
            }
        })
    }

    fn reset(&self) {
        self.chat.reset();
    }
}

// ── Pure helpers (tested below) ───────────────────────────────────────────────

fn is_local(provider: &str) -> bool {
    matches!(provider, "ollama" | "lmstudio" | "custom")
}

/// The credential store entry a provider's key lives in; None for the model servers.
fn key_name(provider: &str) -> Option<&'static str> {
    if provider == chat::ANTHROPIC {
        return Some(claude::KEY);
    }
    openai_compat::provider(provider).map(|p| p.key)
}

pub fn provider_name(provider: &str) -> String {
    match provider {
        "anthropic" => "Anthropic".into(),
        "google" => "Google".into(),
        "openai" => "OpenAI".into(),
        "openrouter" => "OpenRouter".into(),
        "ollama" => "Ollama".into(),
        "lmstudio" => "LM Studio".into(),
        _ => "Custom server".into(),
    }
}

/// "provider/model" with a provider this build knows and a plain model name; the model may contain
/// slashes ("openrouter/auto" is the model of the "openrouter" provider written "openrouter/openrouter/auto").
pub fn parse_model_id(id: &str) -> Option<(&str, &str)> {
    let (provider, model) = id.split_once('/')?;
    let model = model.trim();
    if !PROVIDERS.contains(&provider) || model.is_empty() || model.chars().count() > MAX_MODEL_CHARS || model.chars().any(char::is_control) {
        return None;
    }
    Some((provider, model))
}

/// The user's list, made safe: valid ids only, no duplicates, at most MAX_ALLOWED.
pub fn clean_models(ids: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for id in ids {
        if parse_model_id(id).is_some() && !out.contains(id) && out.len() < MAX_ALLOWED {
            out.push(id.clone());
        }
    }
    out
}

pub fn options(ids: &[String]) -> Vec<ModelOption> {
    clean_models(ids)
        .into_iter()
        .filter_map(|id| {
            let (provider, model) = parse_model_id(&id)?;
            let label = format!("{} · {}", provider_name(provider), model);
            Some(ModelOption { provider: provider.to_string(), label, id })
        })
        .collect()
}

/// Which kind of failure an error message from `chat::send_for_phone` stands for. The messages are
/// written for people (and translated), so this looks only at what does not change with the language:
/// an HTTP status in the text. A model server that answers with no status at all is one that did not answer.
pub fn classify(local: bool, err: &str) -> ChatFail {
    let has = |code: &str| err.split(|c: char| !c.is_ascii_digit()).any(|w| w == code);
    if has("401") || has("403") {
        return ChatFail::Auth;
    }
    let has_status = err.split(|c: char| !c.is_ascii_digit()).any(|w| w.len() == 3 && w.starts_with(['4', '5']));
    if local && !has_status {
        return ChatFail::Unreachable;
    }
    if err.starts_with("Network error") {
        return ChatFail::Unreachable;
    }
    ChatFail::Provider
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn model_ids_need_a_known_provider_and_a_plain_model() {
        assert_eq!(parse_model_id("openai/gpt-4o"), Some(("openai", "gpt-4o")));
        assert_eq!(parse_model_id("openrouter/openrouter/auto"), Some(("openrouter", "openrouter/auto")));
        assert_eq!(parse_model_id("ollama/llama3.2:latest"), Some(("ollama", "llama3.2:latest")));
        for bad in ["", "openai", "openai/", "openai/ ", "nope/gpt", "OpenAI/gpt", "openai/a\nb", &format!("openai/{}", "x".repeat(201))] {
            assert_eq!(parse_model_id(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_allowed_list_is_cleaned_and_capped() {
        assert_eq!(clean_models(&ids(&["openai/gpt-4o", "bad", "openai/gpt-4o", "google/gemini"])), ids(&["openai/gpt-4o", "google/gemini"]));
        let many: Vec<String> = (0..80).map(|i| format!("openai/m{i}")).collect();
        assert_eq!(clean_models(&many).len(), MAX_ALLOWED);
        assert!(clean_models(&[]).is_empty());
    }

    #[test]
    fn what_the_phone_is_told_about_a_model_is_its_id_provider_and_label_only() {
        let o = options(&ids(&["anthropic/claude-x", "lmstudio/qwen"]));
        assert_eq!(o[0], ModelOption { id: "anthropic/claude-x".into(), provider: "anthropic".into(), label: "Anthropic · claude-x".into() });
        assert_eq!(o[1].label, "LM Studio · qwen");
    }

    #[test]
    fn failures_are_sorted_by_status_and_never_by_wording() {
        assert_eq!(classify(false, "Claude API 401 Unauthorized: invalid x-api-key"), ChatFail::Auth);
        assert_eq!(classify(false, "OpenAI rejected the API key (403). Check it in Settings."), ChatFail::Auth);
        assert_eq!(classify(false, "OpenAI rate limit reached (429): slow down"), ChatFail::Provider);
        assert_eq!(classify(false, "Claude API 500 Internal Server Error: boom"), ChatFail::Provider);
        assert_eq!(classify(false, "Network error: connection refused"), ChatFail::Unreachable);
        assert_eq!(classify(true, "Cannot reach http://127.0.0.1:11434. Is the server running?"), ChatFail::Unreachable);
        assert_eq!(classify(true, "Ollama 500: model crashed"), ChatFail::Provider);
        // 4010 or 14012 are not 401
        assert_eq!(classify(false, "something 14012 happened"), ChatFail::Provider);
    }

    #[test]
    fn keys_are_found_by_provider() {
        assert_eq!(key_name("anthropic"), Some("anthropic-api-key"));
        assert_eq!(key_name("openai"), Some("openai-api-key"));
        assert_eq!(key_name("ollama"), None);
        assert!(is_local("custom") && !is_local("openai"));
    }
}
