//! Shared, transactional chat history. Provider changes never replay another
//! provider's conversation, and a reset invalidates a request already in flight.
use std::sync::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    #[default]
    Claude,
    Openai,
}

#[derive(Default)]
struct Conversation {
    identity: Option<(Provider, String)>,
    generation: u64,
    messages: Vec<Value>,
}

#[derive(Default)]
pub struct Chat {
    pub turn: tokio::sync::Mutex<()>,
    conversation: Mutex<Conversation>,
}

impl Chat {
    pub fn reset(&self) {
        let mut state = self.conversation.lock().unwrap();
        state.generation += 1;
        state.messages.clear();
    }

    pub fn begin(&self, provider: Provider, model: &str) -> (u64, Vec<Value>) {
        let mut state = self.conversation.lock().unwrap();
        let identity = (provider, model.to_owned());
        if state.identity.as_ref() != Some(&identity) {
            state.generation += 1;
            state.messages.clear();
            state.identity = Some(identity);
        }
        (state.generation, state.messages.clone())
    }

    pub fn commit(&self, generation: u64, messages: Vec<Value>) -> Result<(), String> {
        let mut state = self.conversation.lock().unwrap();
        if state.generation != generation {
            return Err("Conversation changed. Please send your message again.".into());
        }
        state.messages = messages;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn provider_and_model_changes_do_not_replay_history() {
        let chat = Chat::default();
        let (generation, _) = chat.begin(Provider::Claude, "claude");
        chat.commit(generation, vec![json!({"private": "old conversation"})]).unwrap();
        assert_eq!(chat.begin(Provider::Claude, "claude").1.len(), 1);
        let (next, messages) = chat.begin(Provider::Openai, "gpt");
        assert!(messages.is_empty());
        assert!(chat.commit(generation, vec![json!("late response")]).is_err());
        chat.commit(next, vec![json!("openai")]).unwrap();
        assert!(chat.begin(Provider::Openai, "another-model").1.is_empty());
    }

    #[test]
    fn reset_invalidates_inflight_requests() {
        let chat = Chat::default();
        let (generation, _) = chat.begin(Provider::Openai, "gpt");
        chat.reset();
        assert!(chat.commit(generation, vec![json!("late response")]).is_err());
        assert!(chat.begin(Provider::Openai, "gpt").1.is_empty());
    }
}
