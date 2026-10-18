//! Shared UI bridge for the CLI agents' native permission and question requests.
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::chat::{Chat, ChatContext, ChatReply};
use crate::settings::Settings;

static NEXT: AtomicU64 = AtomicU64::new(1);
fn pending() -> &'static Mutex<HashMap<String, mpsc::Sender<Value>>> {
    static PENDING: OnceLock<Mutex<HashMap<String, mpsc::Sender<Value>>>> = OnceLock::new();
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

#[tauri::command]
pub fn cli_agent_answer(id: String, answer: Value) {
    if let Some(tx) = pending().lock().unwrap().remove(&id) {
        let _ = tx.send(answer);
    }
}

pub fn workspace(settings: &crate::settings::Settings) -> Result<PathBuf, String> {
    let path = if settings.cli_workspace.trim().is_empty() {
        crate::platform::home_dir()
    } else {
        PathBuf::from(settings.cli_workspace.trim())
    };
    if !path.is_absolute() || !path.is_dir() {
        return Err("Choose an existing absolute working folder in Settings → Chat.".into());
    }
    path.canonicalize()
        .map_err(|_| "Cannot open the CLI working folder.".into())
}

pub fn system_prompt(voice: bool) -> String {
    let style = if voice {
        "Your answer is read aloud. Respond in the user's language in one or two short sentences, without Markdown. When speaking Portuguese, use European Portuguese from Portugal, including its vocabulary and phrasing. Use your tools to carry out requested work before answering."
    } else {
        "Respond in the user's language. Use light Markdown suited to a small chat window. Use your CLI tools to carry out requested work before answering."
    };
    let home = crate::platform::home_dir();
    format!("You are Mochi, the user's personal assistant in Coucou. {style} \
Keep your native CLI capabilities, instructions, skills and permission policies. \
Use available tools to verify current information; say when a tool is unavailable. \
Follow AGENTS.md in every project. Persistent changes to this Fedora host or global account configuration \
must be represented in Git in {}/sysworkspace: first read {}/.codex/context/sysworkspace.md and that repository's AGENTS.md, \
preserve other sessions' changes, retain hooks and YubiKey signing, and finish with a focused commit. \
Project code, dependencies, environments and generated data stay in their own project, outside sysworkspace. \
Never copy credentials into source control.", home.display(), home.display())
}

pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    settings: &Settings,
    provider: &str,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let (app, chat, settings, provider, model) = (
        app.clone(),
        chat.clone(),
        settings.clone(),
        provider.to_string(),
        model.to_string(),
    );
    tauri::async_runtime::spawn_blocking(move || {
        let mut last = std::time::Instant::now() - Duration::from_secs(1);
        run(
            &app,
            &chat,
            &settings,
            &provider,
            &model,
            &query,
            context.as_ref(),
            false,
            &[],
            None,
            |text| {
                if last.elapsed() >= Duration::from_millis(65) {
                    let _ = app.emit_to(crate::island::WINDOW_LABEL, "chat-delta", text);
                    last = std::time::Instant::now();
                }
            },
        )
        .map(|(text, _)| ChatReply { text })
    })
    .await
    .map_err(|_| "The CLI agent stopped unexpectedly.".to_string())?
}

pub fn run(
    app: &AppHandle,
    chat: &Chat,
    settings: &Settings,
    provider: &str,
    model: &str,
    query: &str,
    context: Option<&ChatContext>,
    voice: bool,
    tools: &[Value],
    cancel: Option<std::sync::Arc<AtomicBool>>,
    on_delta: impl FnMut(String),
) -> Result<(String, bool), String> {
    let turn = chat.begin_with_cancel(provider, cancel.unwrap_or_default());
    if turn.cancel.load(Ordering::Relaxed) { return Err("Voice session stopped.".into()); }
    let user_text = crate::local_chat::user_text(turn.first, context, query);
    let cwd = workspace(settings)?;
    let cwd_text = cwd.to_string_lossy().to_string();
    let session = turn
        .session
        .as_ref()
        .filter(|s| s.cwd == cwd_text && s.full_access == settings.cli_full_access)
        .map(|s| s.id.as_str());
    let system = system_prompt(voice);
    let (text, acted) = match provider {
        "codex" => {
            let tools: Vec<Value> = tools.iter().filter(|t| t.get("input_schema").is_some()).map(|t| json!({
                "type": "function", "name": t["name"], "description": t["description"], "inputSchema": t["input_schema"]
            })).collect();
            let exe = crate::platform::codex_candidates()
                .into_iter()
                .next()
                .ok_or("Codex CLI was not found. Run codex login after installing it.")?;
            let mut client =
                crate::codex_chat::rpc::Client::start(&exe, &cwd, Duration::from_secs(1800), true)?;
            client.cancel_with(turn.cancel.clone());
            let reply = client.answer(
                crate::codex_chat::rpc::TurnOptions {
                    model,
                    system: &system,
                    history: &turn.history,
                    query: &user_text,
                    tools: &tools,
                    session_id: session,
                    full_access: settings.cli_full_access,
                },
                |name, args| crate::voice::run_tool(app, name, args),
                |method, params| codex_request(app, method, params, &turn.cancel),
                |id| chat.remember_session(&turn, id, &cwd_text, settings.cli_full_access),
                on_delta,
            )?;
            chat.remember_session(
                &turn,
                &reply.session_id,
                &cwd_text,
                settings.cli_full_access,
            );
            (reply.text, reply.acted)
        }
        "antigravity" => {
            let reply = crate::gravity_chat::rpc::answer(
                &crate::gravity_chat::executable()?,
                &cwd,
                model,
                &system,
                &turn.history,
                &user_text,
                session,
                settings.cli_full_access,
                Some(turn.cancel.clone()),
                |id| chat.remember_session(&turn, id, &cwd_text, settings.cli_full_access),
                on_delta,
            )?;
            (reply.text, reply.acted)
        }
        _ => return Err("Unknown CLI agent.".into()),
    };
    if !chat.is_current(&turn) {
        return Err("This conversation was reset.".into());
    }
    chat.commit(
        &turn,
        json!({"role":"user","content":user_text}),
        json!({"role":"assistant","content":text}),
        &user_text,
        &text,
    );
    Ok((text, acted))
}

pub fn ask(
    app: &AppHandle,
    provider: &str,
    method: &str,
    params: &Value,
    cancel: &AtomicBool,
) -> Option<Value> {
    let questions = params["questions"].as_array();
    let kind = if questions.is_some() {
        "question"
    } else {
        "permission"
    };
    let id = format!("cli-{}", NEXT.fetch_add(1, Ordering::Relaxed));
    let detail = params
        .get("command")
        .and_then(Value::as_str)
        .or_else(|| params.get("reason").and_then(Value::as_str))
        .map(str::to_string)
        .unwrap_or_else(|| serde_json::to_string_pretty(params).unwrap_or_default());
    let (tx, rx) = mpsc::channel();
    pending().lock().unwrap().insert(id.clone(), tx);
    let sent = app
        .emit_to(
            crate::island::WINDOW_LABEL,
            "agent-request",
            json!({
                "id": id, "provider": provider, "kind": kind, "title": method,
                "detail": detail, "questions": questions
            }),
        )
        .is_ok();
    let deadline = std::time::Instant::now() + Duration::from_secs(600);
    let answer = if sent {
        loop {
            if cancel.load(Ordering::Relaxed) || std::time::Instant::now() >= deadline {
                break None;
            }
            match rx.recv_timeout(Duration::from_secs(1)) {
                Ok(answer) => break Some(answer),
                Err(mpsc::RecvTimeoutError::Disconnected) => break None,
                Err(_) => {}
            }
        }
    } else {
        None
    };
    pending().lock().unwrap().remove(&id);
    let _ = app.emit_to(
        crate::island::WINDOW_LABEL,
        "agent-request-ended",
        json!({ "id": id }),
    );
    answer
}

pub fn codex_request(
    app: &AppHandle,
    method: &str,
    params: &Value,
    cancel: &AtomicBool,
) -> Option<Value> {
    match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            let allowed =
                ask(app, "Codex", method, params, cancel).is_some_and(|a| a["allow"] == true);
            Some(json!({ "decision": if allowed { "accept" } else { "decline" } }))
        }
        "item/permissions/requestApproval" => {
            let allowed =
                ask(app, "Codex", method, params, cancel).is_some_and(|a| a["allow"] == true);
            Some(
                json!({ "permissions": if allowed { params["permissions"].clone() } else { json!({}) }, "scope": "turn" }),
            )
        }
        "item/tool/requestUserInput" => {
            let answer = ask(app, "Codex", method, params, cancel).unwrap_or_else(|| json!({}));
            let mut answers = json!({});
            for question in params["questions"].as_array().into_iter().flatten() {
                if let Some(id) = question["id"].as_str() {
                    answers[id] = json!({ "answers": answer["answers"][id].as_array().cloned().unwrap_or_default() });
                }
            }
            Some(json!({ "answers": answers }))
        }
        "execCommandApproval" | "applyPatchApproval" => {
            let allowed =
                ask(app, "Codex", method, params, cancel).is_some_and(|a| a["allow"] == true);
            Some(json!({ "decision": if allowed { "approved" } else { "denied" } }))
        }
        "mcpServer/elicitation/request" => {
            let mut form = params.clone();
            let properties = params["requestedSchema"]["properties"].as_object();
            if let Some(properties) = properties {
                form["questions"] = json!(properties.iter().map(|(id, schema)| json!({
                    "id": id,
                    "question": format!("{}\n{}", params["message"].as_str().unwrap_or(""), schema["title"].as_str().unwrap_or(id)),
                    "isSecret": schema["format"] == "password",
                    "options": schema["enum"].as_array().map(|options| options.iter().map(|v| json!({ "label": v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()) })).collect::<Vec<_>>())
                })).collect::<Vec<_>>());
            }
            let answer = ask(app, "Codex", method, &form, cancel).unwrap_or_else(|| json!({}));
            let mut content = json!({});
            let mut allowed = answer["allow"] == true;
            if let Some(properties) = properties {
                for (id, schema) in properties {
                    let raw = answer["answers"][id][0].as_str().unwrap_or("");
                    let required = params["requestedSchema"]["required"]
                        .as_array()
                        .is_some_and(|items| items.iter().any(|v| v == id));
                    if raw.is_empty() && !required {
                        continue;
                    }
                    content[id] = match schema["type"].as_str() {
                        Some("boolean" | "number" | "integer" | "array" | "object") => {
                            match serde_json::from_str(raw) {
                                Ok(value) => value,
                                Err(_) => {
                                    allowed = false;
                                    Value::Null
                                }
                            }
                        }
                        _ => json!(raw),
                    };
                }
            }
            Some(
                json!({ "action": if allowed { "accept" } else { "decline" }, "content": if allowed && properties.is_some() { content } else { Value::Null }, "_meta": null }),
            )
        }
        _ => None,
    }
}
