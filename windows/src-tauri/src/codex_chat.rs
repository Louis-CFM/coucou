// Subscription chat through a private Codex app-server on stdio. Codex owns
// credentials; Coucou never reads auth.json, logs tokens, or falls back to API billing.
// A fresh, ephemeral thread receives the in-memory conversation on each turn.

use std::io::Read;
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::platform;

mod protocol;
use protocol::{prompt, subscription_account, thread_params, Answer, Client};

pub const PROVIDER: &str = "codex";
const TIMEOUT: Duration = Duration::from_secs(180);
const SETUP_TIMEOUT: Duration = Duration::from_secs(15);
const SIGN_IN: &str =
    "Sign in to Codex with ChatGPT first: run codex login in a terminal, then refresh.";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    installed: bool,
    connected: bool,
    plan: Option<String>,
}

pub fn status() -> Result<Status, String> {
    let Some(exe) = platform::codex_candidates().into_iter().next() else {
        return Ok(Status {
            installed: false,
            connected: false,
            plan: None,
        });
    };
    let mut client = Client::start(exe, SETUP_TIMEOUT)?;
    let account = client.request("account/read", json!({"refreshToken": false}), || false)?;
    let connected = subscription_account(&account);
    Ok(Status {
        installed: true,
        connected,
        plan: connected
            .then(|| account["account"]["planType"].as_str().map(str::to_owned))
            .flatten(),
    })
}

fn authenticated_client(timeout: Duration, cancelled: impl Fn() -> bool) -> Result<Client, String> {
    let exe = platform::codex_candidates()
        .into_iter()
        .next()
        .ok_or_else(|| {
            crate::i18n::t("Install Codex CLI, then sign in with ChatGPT using codex login.")
        })?;
    let mut client = Client::start_with(exe, timeout, &cancelled)?;
    check_account(&mut client, cancelled)?;
    Ok(client)
}

pub fn models() -> Result<Vec<ModelInfo>, String> {
    let mut client = authenticated_client(SETUP_TIMEOUT, || false)?;
    let mut result = Vec::new();
    let mut cursor = Value::Null;
    // Bounded pagination, including servers that accidentally repeat a cursor.
    for _ in 0..10 {
        let page = client.request(
            "model/list",
            json!({"cursor": cursor, "limit": 100}),
            || false,
        )?;
        for model in page["data"].as_array().ok_or("Invalid Codex model list.")? {
            if model["hidden"] == true {
                continue;
            }
            let Some(id) = model["model"].as_str().filter(|s| !s.is_empty()) else {
                continue;
            };
            let label = model["displayName"].as_str().unwrap_or(id);
            result.push(ModelInfo {
                id: id.into(),
                label: label.into(),
            });
        }
        let next = page["nextCursor"].clone();
        if next.is_null() || next == cursor {
            break;
        }
        cursor = next;
    }
    Ok(result)
}

pub async fn send(
    app: &AppHandle,
    query: String,
    context: Option<ChatContext>,
    model: &str,
) -> Result<ChatReply, String> {
    let turn = app.state::<Chat>().begin(PROVIDER);
    let app = app.clone();
    let model = model.to_owned();
    tauri::async_runtime::spawn_blocking(move || -> Result<ChatReply, String> {
        let chat = app.state::<Chat>();
        let cancelled = || !chat.is_current(&turn);
        let question = question(turn.first, context.as_ref(), &query)?;
        let prompt = prompt(&turn.history, &question)?;
        let mut client = authenticated_client(TIMEOUT, cancelled)?;
        // Disable each configured extension explicitly: an empty TOML table
        // would merge with, rather than erase, the user's existing configuration.
        let config = client.request("config/read", json!({"includeLayers": false}), cancelled)?;
        let params = thread_params(&client.cwd, &model, &config, &chat::system_prompt(false));
        let started = client.request("thread/start", params, cancelled)?;
        if started["modelProvider"] != "openai" || started["sandbox"]["type"] != "readOnly" {
            return Err("Codex did not apply the chat provider or read-only sandbox.".into());
        }
        let thread = started["thread"]["id"]
            .as_str()
            .ok_or("Missing Codex thread ID.")?
            .to_owned();
        // Recheck after thread setup; a shared CLI session may have changed.
        check_account(&mut client, cancelled)?;
        let started = client.request(
            "turn/start",
            json!({
                "threadId": thread, "input": [{"type": "text", "text": prompt}],
            }),
            cancelled,
        )?;
        let id = started["turn"]["id"]
            .as_str()
            .ok_or("Missing Codex turn ID.")?
            .to_owned();
        let mut answer = Answer::default();
        loop {
            let message = client.receive(cancelled)?;
            if answer.accept(&message, &thread, &id)? {
                break;
            }
            if answer.changed && !cancelled() {
                let _ = app.emit_to(crate::island::WINDOW_LABEL, "chat-delta", &answer.text);
                answer.changed = false;
            }
        }
        if cancelled() {
            return Err("Chat was reset.".into());
        }
        chat.commit(
            &turn,
            json!({"role": "user", "content": question}),
            json!({"role": "assistant", "content": answer.text}),
            &question,
            &answer.text,
        );
        Ok(ChatReply { text: answer.text })
    })
    .await
    .map_err(|_| "Codex chat worker stopped.".to_string())?
    .map_err(|error| match error.as_str() {
        "This conversation is too long. Start a new chat." => {
            crate::i18n::t("This conversation is too long. Start a new chat.")
        }
        "Codex took too long to answer. Try again." => {
            crate::i18n::t("Codex took too long to answer. Try again.")
        }
        _ => error,
    })
}

fn question(first: bool, context: Option<&ChatContext>, query: &str) -> Result<String, String> {
    let plain = chat::plain_question(first, context, query);
    if let Some(ChatContext::File { path, .. }) = context.filter(|_| first) {
        // No tool gets a path: only the already-checked dropped text is inlined.
        let file = std::fs::File::open(path).map_err(|_| "Cannot read the dropped file.")?;
        let mut bytes = Vec::new();
        file.take(200_001)
            .read_to_end(&mut bytes)
            .map_err(|_| "Cannot read the dropped file.")?;
        if bytes.len() > 200_000 {
            return Err(crate::i18n::t(
                "Codex chat accepts text files up to 200 KB.",
            ));
        }
        let text = String::from_utf8(bytes)
            .map_err(|_| crate::i18n::t("Codex chat currently supports text files only."))?;
        if text.contains('\0') {
            return Err(crate::i18n::t(
                "Codex chat currently supports text files only.",
            ));
        }
        return Ok(format!(
            "{plain}\n\n<attached_text>\n{text}\n</attached_text>"
        ));
    }
    Ok(plain)
}

fn check_account(client: &mut Client, cancelled: impl Fn() -> bool) -> Result<(), String> {
    let result = client.request("account/read", json!({"refreshToken": false}), cancelled)?;
    if !subscription_account(&result) {
        return Err(crate::i18n::t(SIGN_IN));
    }
    Ok(())
}
