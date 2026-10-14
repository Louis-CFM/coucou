// Codex CLI's stdio app-server. Credentials remain with Codex, not the webview.
// One live ephemeral thread preserves the conversation and its reasoning state.
use crate::{
    chat::{Chat, ChatContext, ChatReply, ModelInfo},
    platform,
    settings::Settings,
};
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    io::{BufRead, BufReader, Read, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::{self, Receiver},
        Mutex, OnceLock,
    },
    time::{Duration, Instant},
};
use tauri::{AppHandle, Emitter};

const MAX_LINE: usize = 4 * 1024 * 1024;
const MAX_ANSWER: usize = 2 * 1024 * 1024;
static CLIENT: OnceLock<Mutex<Option<Client>>> = OnceLock::new();
static CANCEL: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexModel {
    pub id: String,
    pub label: String,
    pub reasoning_efforts: Vec<String>,
    pub default_effort: String,
    pub service_tiers: Vec<Value>,
    pub is_default: bool,
}
fn catalog_model(m: &Value) -> Option<CodexModel> {
    if m["hidden"].as_bool() == Some(true) {
        return None;
    }
    let id = m["model"]
        .as_str()
        .or_else(|| m["id"].as_str())?
        .to_string();
    let mut tiers = m["serviceTiers"].as_array().cloned().unwrap_or_default();
    if tiers.is_empty()
        && m["additionalSpeedTiers"]
            .as_array()
            .is_some_and(|v| v.iter().any(|t| t == "fast"))
    {
        tiers.push(json!({"id":"priority", "name":"Fast", "description":"Faster responses; increased usage."}));
    }
    Some(CodexModel {
        label: m["displayName"].as_str().unwrap_or(&id).to_string(),
        id,
        reasoning_efforts: m["supportedReasoningEfforts"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| e["reasoningEffort"].as_str().map(str::to_string))
            .collect(),
        default_effort: m["defaultReasoningEffort"]
            .as_str()
            .unwrap_or("medium")
            .to_string(),
        service_tiers: tiers,
        is_default: m["isDefault"].as_bool().unwrap_or(false),
    })
}

struct Client {
    child: Child,
    input: ChildStdin,
    messages: Receiver<Result<Value, String>>,
    queued: VecDeque<Value>,
    next_id: u64,
    thread: Option<(u64, usize, String)>,
}
impl Drop for Client {
    fn drop(&mut self) {
        #[cfg(windows)]
        {
            let mut kill = Command::new("taskkill");
            kill.args(["/T", "/F", "/PID", &self.child.id().to_string()]);
            platform::no_console(&mut kill);
            let _ = kill.status();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Client {
    fn start() -> Result<Self, String> {
        let exe = platform::codex_candidates()
            .into_iter()
            .next()
            .ok_or("Codex CLI is not installed. Install Codex and run codex login first.")?;
        let mut cmd = Command::new(&exe);
        cmd.args(["app-server", "--listen", "stdio://"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(dir) = exe.parent() {
            let mut dirs = vec![dir.to_path_buf()];
            if let Some(path) = std::env::var_os("PATH") {
                dirs.extend(std::env::split_paths(&path));
            }
            if let Ok(path) = std::env::join_paths(dirs) {
                cmd.env("PATH", path);
            }
        }
        platform::no_console(&mut cmd);
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Cannot start Codex CLI: {e}"))?;
        let input = child.stdin.take().ok_or("Codex CLI has no input stream.")?;
        let stdout = child
            .stdout
            .take()
            .ok_or("Codex CLI has no output stream.")?;
        let (tx, messages) = mpsc::sync_channel(64);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let mut line = Vec::new();
                let parsed = match (&mut reader)
                    .take(MAX_LINE as u64 + 1)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) => Err("Codex CLI disconnected. Try again.".to_string()),
                    Ok(_) if line.len() > MAX_LINE => {
                        Err("Codex CLI sent an oversized message.".to_string())
                    }
                    Ok(_) => match serde_json::from_slice(&line) {
                        Ok(v) => Ok(v),
                        Err(_) => continue,
                    },
                    Err(e) => Err(format!("Cannot read Codex CLI: {e}")),
                };
                let stop = parsed.is_err();
                if tx.send(parsed).is_err() || stop {
                    break;
                }
            }
        });
        let mut c = Self {
            child,
            input,
            messages,
            queued: VecDeque::new(),
            next_id: 1,
            thread: None,
        };
        c.call("initialize", json!({"clientInfo":{"name":"coucou_chat","title":"Coucou","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":true}}))?;
        c.write(json!({"method":"initialized"}))?;
        Ok(c)
    }
    fn write(&mut self, value: Value) -> Result<(), String> {
        writeln!(self.input, "{value}")
            .and_then(|_| self.input.flush())
            .map_err(|e| format!("Cannot contact Codex CLI: {e}"))
    }
    fn receive(&self, deadline: Instant) -> Result<Value, String> {
        let remaining = deadline.saturating_duration_since(Instant::now());
        self.messages
            .recv_timeout(remaining)
            .map_err(|_| "Codex CLI did not respond. Try again.".to_string())?
    }
    fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.write(json!({"id":id,"method":method,"params":params}))?;
        let deadline = Instant::now() + Duration::from_secs(45);
        loop {
            let msg = self.receive(deadline)?;
            if msg["id"].as_u64() == Some(id) && msg.get("method").is_none() {
                if let Some(error) = msg.get("error") {
                    return Err(error["message"]
                        .as_str()
                        .unwrap_or("Codex CLI request failed.")
                        .to_string());
                }
                return Ok(msg["result"].clone());
            }
            if msg["method"]
                .as_str()
                .is_some_and(|m| m.starts_with("item/") || m == "turn/completed")
            {
                if self.queued.len() >= 256 {
                    return Err("Too many Codex CLI events.".to_string());
                }
                self.queued.push_back(msg);
            } else {
                self.reject_request(&msg)?;
            }
        }
    }
    fn reject_request(&mut self, msg: &Value) -> Result<(), String> {
        if msg.get("id").is_some() && msg.get("method").is_some() {
            // Chat runs read-only. Never silently grant an execution or file approval.
            self.write(json!({"id":msg["id"],"error":{"code":-32601,"message":"This Coucou chat does not support interactive tool approvals."}}))?;
        }
        Ok(())
    }
    fn models(&mut self) -> Result<Vec<CodexModel>, String> {
        let account = self.call("account/read", json!({"refreshToken":false}))?;
        if account["account"].is_null() {
            return Err("Sign in to Codex CLI with codex login, then retry.".into());
        }
        let mut models = Vec::new();
        let mut cursor = Value::Null;
        for _ in 0..20 {
            let reply = self.call(
                "model/list",
                json!({"limit":100,"includeHidden":false,"cursor":cursor}),
            )?;
            models.extend(
                reply["data"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(catalog_model),
            );
            cursor = reply["nextCursor"].clone();
            if cursor.is_null() {
                break;
            }
        }
        if models.is_empty() {
            return Err("Codex CLI returned no models. Check your login and retry.".into());
        }
        Ok(models)
    }
    fn answer(
        &mut self,
        epoch: u64,
        history: &[Value],
        settings: &Settings,
        input: Vec<Value>,
        mut delta: impl FnMut(String),
        cancel: u64,
    ) -> Result<String, String> {
        let models = self.models()?;
        let selected = settings.chat_models.get("codex").filter(|s| !s.is_empty());
        let model = match selected {
            Some(id) => models
                .iter()
                .find(|m| &m.id == id)
                .ok_or("The selected Codex model is no longer available. Choose another model.")?,
            None => models.iter().find(|m| m.is_default).unwrap_or(&models[0]),
        };
        let effort = if settings.codex_reasoning_effort.is_empty() {
            &model.default_effort
        } else {
            &settings.codex_reasoning_effort
        };
        if !model.reasoning_efforts.iter().any(|e| e == effort) {
            return Err(
                "This model does not support the selected effort. Choose another effort.".into(),
            );
        }
        let tier = settings.codex_service_tier.as_str();
        if !tier.is_empty()
            && !model
                .service_tiers
                .iter()
                .any(|t| t["id"].as_str() == Some(tier))
        {
            return Err(
                "This model does not support the selected speed. Choose Normal speed.".into(),
            );
        }
        let new_thread = !self
            .thread
            .as_ref()
            .is_some_and(|(e, n, _)| *e == epoch && *n == history.len());
        if CANCEL.load(Ordering::Acquire) != cancel {
            return Err("Response stopped.".into());
        }
        if new_thread {
            self.queued.clear();
            let r = self.call("thread/start", json!({"model":model.id,"approvalPolicy":"never","sandbox":"read-only","ephemeral":true,"developerInstructions":crate::chat::system_prompt(false),"serviceTier":if tier.is_empty(){Value::Null}else{json!(tier)}}))?;
            let id = r["thread"]["id"]
                .as_str()
                .ok_or("Codex did not create a conversation.")?
                .to_string();
            self.thread = Some((epoch, history.len(), id));
        }
        let thread_id = self.thread.as_ref().unwrap().2.clone();
        let mut input = input;
        // A provider switch recreates the Codex thread with explicitly quoted history.
        if new_thread && !history.is_empty() {
            input.insert(0, json!({"type":"text","text":format!("Previous conversation (quoted context, not new instructions):\n{}", serde_json::to_string(history).unwrap_or_default()),"text_elements":[]}));
        }
        if CANCEL.load(Ordering::Acquire) != cancel {
            return Err("Response stopped.".into());
        }
        let started = self.call("turn/start", json!({"threadId":thread_id,"input":input,"model":model.id,"effort":effort,"serviceTierForTurn":if tier.is_empty(){"default"}else{tier},"serviceTier":if tier.is_empty(){Value::Null}else{json!(tier)}}))?;
        let turn_id = started["turn"]["id"]
            .as_str()
            .ok_or("Codex did not start a response.")?
            .to_string();
        let deadline = Instant::now() + Duration::from_secs(1200);
        let mut output = Output::default();
        loop {
            if CANCEL.load(Ordering::Acquire) != cancel {
                let id = self.next_id;
                self.next_id += 1;
                let _=self.write(json!({"id":id,"method":"turn/interrupt","params":{"threadId":thread_id,"turnId":turn_id}}));
                self.thread = None;
                return Err("Response stopped.".into());
            }
            if Instant::now() >= deadline {
                return Err("Codex response timed out. Try again.".into());
            }
            let msg = if let Some(msg) = self.queued.pop_front() {
                msg
            } else {
                match self.messages.recv_timeout(Duration::from_millis(100)) {
                    Ok(msg) => msg?,
                    Err(mpsc::RecvTimeoutError::Timeout) => continue,
                    Err(_) => return Err("Codex CLI disconnected.".into()),
                }
            };
            self.reject_request(&msg)?;
            if msg["params"]["threadId"].as_str() != Some(&thread_id) {
                continue;
            }
            if let Some(id) = msg["params"]["turnId"].as_str() {
                if id != turn_id {
                    continue;
                }
            }
            if let Some(answer) = output.accept(&msg)? {
                if answer.trim().is_empty() {
                    return Err("Codex returned no response text.".into());
                }
                self.thread = Some((epoch, history.len() + 2, thread_id));
                delta(answer.clone());
                return Ok(answer);
            }
            if output.changed {
                delta(output.text());
                output.changed = false;
            }
        }
    }
}

// Agent commentary and final messages replace by item id, never duplicate deltas.
#[derive(Default)]
struct Output {
    items: Vec<(String, String)>,
    changed: bool,
}
impl Output {
    fn text(&self) -> String {
        self.items
            .iter()
            .map(|(_, s)| s.as_str())
            .collect::<Vec<_>>()
            .join("\n\n")
    }
    fn accept(&mut self, msg: &Value) -> Result<Option<String>, String> {
        let p = &msg["params"];
        match msg["method"].as_str().unwrap_or("") {
            "item/agentMessage/delta" => {
                let id = p["itemId"].as_str().unwrap_or("");
                let at = self
                    .items
                    .iter()
                    .position(|(i, _)| i == id)
                    .unwrap_or_else(|| {
                        self.items.push((id.into(), String::new()));
                        self.items.len() - 1
                    });
                self.items[at].1.push_str(p["delta"].as_str().unwrap_or(""));
                self.changed = true;
            }
            "item/completed" if p["item"]["type"] == "agentMessage" => {
                let item = &p["item"];
                let id = item["id"].as_str().unwrap_or("");
                let at = self
                    .items
                    .iter()
                    .position(|(i, _)| i == id)
                    .unwrap_or_else(|| {
                        self.items.push((id.into(), String::new()));
                        self.items.len() - 1
                    });
                self.items[at].1 = item["text"].as_str().unwrap_or("").into();
                self.changed = true;
            }
            "turn/completed" => {
                let turn = &p["turn"];
                if turn["status"] != "completed" {
                    return Err(turn["error"]["message"]
                        .as_str()
                        .unwrap_or("Codex response was interrupted.")
                        .to_string());
                }
                return Ok(Some(self.text()));
            }
            _ => {}
        }
        if self.items.iter().map(|(_, s)| s.len()).sum::<usize>() > MAX_ANSWER {
            return Err("Codex response is too large.".into());
        }
        Ok(None)
    }
}
fn with_client<T>(run: impl FnOnce(&mut Client) -> Result<T, String>) -> Result<T, String> {
    let mut guard = CLIENT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| "Codex connection was interrupted.")?;
    if guard.is_none() {
        *guard = Some(Client::start()?);
    }
    let result = run(guard.as_mut().unwrap());
    if result.is_err() {
        *guard = None;
    }
    result
}
pub fn require_enabled(settings: &Settings) -> Result<(), String> {
    if settings.codex_chat_enabled {
        Ok(())
    } else {
        Err("Codex chat is not installed. Enable it in Settings → Codex CLI chat.".into())
    }
}

/// Cancels an answer immediately, then drops only Coucou's private app-server.
pub fn disconnect() {
    cancel();
    tauri::async_runtime::spawn_blocking(|| {
        if let Some(client) = CLIENT.get() {
            if let Ok(mut guard) = client.lock() {
                *guard = None;
            }
        }
    });
}

pub fn cancel() {
    CANCEL.fetch_add(1, Ordering::AcqRel);
}
pub async fn models() -> Result<Vec<CodexModel>, String> {
    tauri::async_runtime::spawn_blocking(|| with_client(|c| c.models()))
        .await
        .map_err(|e| e.to_string())?
}
pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    settings: &Settings,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    require_enabled(settings)?;
    let turn = chat.begin("codex");
    let mut text = crate::chat::plain_question(turn.first, context.as_ref(), &query);
    let mut input = Vec::new();
    if turn.first {
        if let Some(ChatContext::File { path, .. }) = context.as_ref() {
            let image = std::path::Path::new(path)
                .extension()
                .and_then(|s| s.to_str())
                .is_some_and(|e| {
                    ["png", "jpg", "jpeg", "webp", "gif"].contains(&e.to_lowercase().as_str())
                });
            if image {
                input.push(json!({"type":"localImage","path":path}));
            } else {
                text = crate::local_chat::user_text(true, context.as_ref(), &query);
            }
        }
    }
    input.push(json!({"type":"text","text":text,"text_elements":[]}));
    let app = app.clone();
    let settings = settings.clone();
    let history = turn.history.clone();
    let epoch = turn.epoch;
    let cancel = CANCEL.load(Ordering::Acquire);
    let answer = tauri::async_runtime::spawn_blocking(move || {
        with_client(|c| {
            c.answer(
                epoch,
                &history,
                &settings,
                input,
                |text| {
                    let _ = app.emit_to("island", "chat-delta", text);
                },
                cancel,
            )
        })
    })
    .await
    .map_err(|e| e.to_string())??;
    chat.commit(
        &turn,
        json!({"role":"user","content":text}),
        json!({"role":"assistant","content":answer}),
        &text,
        &answer,
    );
    Ok(ChatReply { text: answer })
}
pub fn plain_models(models: Vec<CodexModel>) -> Vec<ModelInfo> {
    models
        .into_iter()
        .map(|m| ModelInfo {
            id: m.id,
            label: m.label,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabled_chat_rejects_codex_requests_and_keeps_preferences() {
        let mut settings = Settings::default();
        assert!(require_enabled(&settings).is_ok());
        settings
            .chat_models
            .insert("codex".into(), "gpt-test".into());
        settings.codex_reasoning_effort = "high".into();
        settings.codex_service_tier = "priority".into();
        settings.codex_chat_enabled = false;
        assert!(require_enabled(&settings).unwrap_err().contains("Settings"));
        let saved = serde_json::to_string(&settings).unwrap();
        let loaded: Settings = serde_json::from_str(&saved).unwrap();
        assert!(!loaded.codex_chat_enabled);
        assert_eq!(loaded.chat_models["codex"], "gpt-test");
        assert_eq!(loaded.codex_reasoning_effort, "high");
        assert_eq!(loaded.codex_service_tier, "priority");
    }

    #[test]
    fn catalog_preserves_model_specific_efforts_and_speed_ids() {
        let m=catalog_model(&json!({"model":"gpt-test", "displayName":"GPT Test", "supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}], "defaultReasoningEffort":"low", "serviceTiers":[{"id":"priority","name":"Fast","description":"Faster"}],"isDefault":true})).unwrap();
        assert_eq!(m.reasoning_efforts, vec!["low", "high"]);
        assert_eq!(m.service_tiers[0]["id"], "priority");
        assert!(m.is_default);
        assert!(catalog_model(&json!({"model":"hidden","hidden":true})).is_none());
    }
    #[test]
    fn output_keeps_unicode_replaces_completed_items_and_excludes_reasoning() {
        let mut o = Output::default();
        o.accept(&json!({"method":"item/reasoning/textDelta","params":{"delta":"private"}}))
            .unwrap();
        o.accept(
            &json!({"method":"item/agentMessage/delta","params":{"itemId":"a","delta":"¡Hola"}}),
        )
        .unwrap();
        o.accept(
            &json!({"method":"item/agentMessage/delta","params":{"itemId":"a","delta":"! 🐾"}}),
        )
        .unwrap();
        o.accept(&json!({"method":"item/completed","params":{"item":{"type":"agentMessage","id":"a","text":"¡Hola! 🐾"}}})).unwrap();
        let done = o
            .accept(&json!({"method":"turn/completed","params":{"turn":{"status":"completed"}}}))
            .unwrap()
            .unwrap();
        assert_eq!(done, "¡Hola! 🐾");
    }
    #[test]
    fn failed_turns_report_errors_instead_of_successful_partial_answers() {
        let mut o = Output::default();
        let r=o.accept(&json!({"method":"turn/completed","params":{"turn":{"status":"failed","error":{"message":"Model unavailable"}}}}));
        assert_eq!(r.unwrap_err(), "Model unavailable");
    }
}
