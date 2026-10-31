//! Text-only tasks use the explicitly selected provider, independently of chat history.

use std::time::Duration;
use serde::{Deserialize, Serialize};
use crate::{i18n::t, settings::Settings};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Engine {
    #[default]
    Claude,
    Ollama,
    #[serde(rename = "lmstudio")]
    LmStudio,
    Custom,
    Off,
}

impl Engine {
    pub fn provider(self) -> &'static str {
        match self {
            Self::Claude => "anthropic", Self::Ollama => "ollama",
            Self::LmStudio => "lmstudio", Self::Custom => "custom", Self::Off => "off",
        }
    }
}

pub async fn complete(settings: &Settings, engine: Engine, system: &str, user: &str,
    max_tokens: u32, timeout: Duration) -> Result<String, String> {
    let provider = engine.provider();
    let model = crate::chat::model_for(settings, provider);
    match engine {
        Engine::Off => Err(t("No summary")),
        Engine::Claude => crate::claude::complete(&model, system, user, max_tokens, timeout).await,
        _ => {
            let server = crate::local_chat::server(settings, provider).expect("local text engine");
            crate::local_chat::complete(&server, &model, system, user, max_tokens, timeout).await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn each_engine_preserves_its_wire_value_and_provider() {
        for (wire, provider) in [("claude", "anthropic"), ("ollama", "ollama"),
            ("lmstudio", "lmstudio"), ("custom", "custom"), ("off", "off")] {
            let engine: Engine = serde_json::from_value(json!(wire)).unwrap();
            assert_eq!(engine.provider(), provider);
            assert_eq!(serde_json::to_value(engine).unwrap(), wire);
        }
        assert_eq!(Engine::default(), Engine::Claude);
    }

    #[test]
    fn local_providers_use_their_configured_server_and_never_fall_back_to_claude() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        for engine in [Engine::Ollama, Engine::LmStudio, Engine::Custom] {
            let body = b"data: {\"choices\":[{\"delta\":{\"content\":\"Meeting summary\"}}]}\n\ndata: [DONE]\n\n";
            let url = crate::net::tests::serve_once("200 OK", "Content-Type: text/event-stream\r\n", body.to_vec());
            let mut settings = Settings::default();
            match engine {
                Engine::Ollama => settings.ollama_url = url,
                Engine::LmStudio => settings.lmstudio_url = url,
                Engine::Custom => settings.custom_url = url,
                _ => unreachable!(),
            }
            settings.chat_models.insert(engine.provider().into(), "fixture-model".into());
            let reply = runtime.block_on(complete(&settings, engine, "Summarize", "Synthetic call", 32, Duration::from_secs(3))).unwrap();
            assert_eq!(reply, "Meeting summary");
            let missing = runtime.block_on(complete(&Settings::default(), engine, "Summarize", "Synthetic call", 32, Duration::from_secs(3)));
            assert!(missing.unwrap_err().contains("Connect"));
        }
    }
}
