//! Bounded stdio client for the user's own Codex app-server. No credentials
//! are read here, and every child is reaped, including on timeout or failure.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

const MAX_LINE: usize = 1024 * 1024;
const MAX_TOTAL: usize = 32 * 1024 * 1024;
const MAX_ANSWER: usize = 4 * 1024 * 1024;
pub const SIGN_IN: &str =
    "Sign in to Codex with your ChatGPT account first: run codex login, then try again.";

pub struct TurnOptions<'a> {
    pub model: &'a str,
    pub system: &'a str,
    pub history: &'a [Value],
    pub query: &'a str,
    pub tools: &'a [Value],
    pub session_id: Option<&'a str>,
    pub full_access: bool,
}

pub struct Reply {
    pub text: String,
    pub acted: bool,
    pub session_id: String,
}

pub struct Client {
    child: Child,
    input: Option<ChildStdin>,
    output: Receiver<Result<Value, String>>,
    deadline: Instant,
    next_id: u64,
    pending: VecDeque<Value>,
    cancel: Option<Arc<AtomicBool>>,
    active_turn: Option<(String, String)>,
}

impl Client {
    pub fn start(exe: &Path, cwd: &Path, timeout: Duration, voice: bool) -> Result<Self, String> {
        let mut cmd = Command::new(exe);
        cmd.args([
            "app-server",
            "--listen",
            "stdio://",
            "-c",
            "model_provider=\"openai\"",
        ])
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
        }
        if let Some(dir) = exe.parent() {
            let mut dirs = vec![dir.to_path_buf()];
            if let Some(path) = std::env::var_os("PATH") {
                dirs.extend(std::env::split_paths(&path));
            }
            if let Ok(path) = std::env::join_paths(dirs) {
                cmd.env("PATH", path);
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x08000000);
        }
        let mut child = cmd.spawn().map_err(|err| {
            format!("Cannot start Codex. Install Codex CLI and sign in with codex login: {err}")
        })?;
        let input = child.stdin.take();
        let stdout = child.stdout.take().ok_or("Codex did not open stdout.")?;
        let (tx, output) = mpsc::sync_channel(32);
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut total = 0;
            loop {
                let result = read_message(&mut reader, &mut total);
                let failed = result.is_err();
                if tx.send(result).is_err() || failed {
                    break;
                }
            }
        });
        let mut client = Self {
            child,
            input,
            output,
            deadline: Instant::now() + timeout,
            next_id: 0,
            pending: VecDeque::new(),
            cancel: None,
            active_turn: None,
        };
        client.request("initialize", json!({
            "clientInfo": { "name": "coucou_mochi", "title": "Coucou — Mochi", "version": "0.5.0" },
            "capabilities": { "experimentalApi": voice }
        }))?;
        client.write(json!({ "method": "initialized" }))?;
        Ok(client)
    }

    fn write(&mut self, message: Value) -> Result<(), String> {
        let input = self.input.as_mut().ok_or("Codex closed its input.")?;
        serde_json::to_writer(&mut *input, &message).map_err(|_| "Cannot write to Codex.")?;
        input
            .write_all(b"\n")
            .and_then(|_| input.flush())
            .map_err(|_| "Cannot write to Codex.".into())
    }

    fn read(&mut self) -> Result<Value, String> {
        if self
            .cancel
            .as_ref()
            .is_some_and(|c| c.load(Ordering::Relaxed))
        {
            return Err("The CLI request was cancelled.".into());
        }
        if let Some(message) = self.pending.pop_front() {
            return Ok(message);
        }
        self.read_raw()
    }

    fn read_raw(&self) -> Result<Value, String> {
        loop {
            if self
                .cancel
                .as_ref()
                .is_some_and(|c| c.load(Ordering::Relaxed))
            {
                return Err("The CLI request was cancelled.".into());
            }
            let left = self.deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err("Codex did not finish in time. Try again.".into());
            }
            match self.output.recv_timeout(left.min(Duration::from_secs(1))) {
                Ok(message) => return message,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => return Err("Codex closed the connection before finishing.".into()),
            }
        }
    }

    pub fn cancel_with(&mut self, cancel: Arc<AtomicBool>) {
        self.cancel = Some(cancel);
    }

    pub fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.next_id += 1;
        let id = self.next_id;
        self.write(json!({ "id": id, "method": method, "params": params }))?;
        loop {
            let message = self.read_raw()?;
            if message["id"] == id && message.get("method").is_none() {
                if let Some(error) = message.get("error") {
                    return Err(rpc_error(error));
                }
                return message
                    .get("result")
                    .cloned()
                    .ok_or_else(|| "Invalid Codex response.".into());
            }
            let method = message["method"].as_str().unwrap_or("");
            if method.starts_with("item/") || method.starts_with("turn/") {
                self.pending.push_back(message);
            } else {
                self.reject_request(&message)?;
            }
        }
    }

    fn reject_request(&mut self, message: &Value) -> Result<(), String> {
        if message.get("id").is_some() && message.get("method").is_some() {
            // Chat never grants shell, file, network, or account permissions.
            self.write(json!({ "id": message["id"], "error": { "code": -32601, "message": "This request is unavailable in Mochi chat." } }))?;
        }
        Ok(())
    }

    pub fn require_account(&mut self) -> Result<(), String> {
        let result = self.request("account/read", json!({ "refreshToken": false }))?;
        if result["account"]["type"] != "chatgpt" {
            return Err(SIGN_IN.into());
        }
        Ok(())
    }

    pub fn models(&mut self) -> Result<Vec<(String, String)>, String> {
        self.require_account()?;
        let mut models = Vec::new();
        let mut cursor = Value::Null;
        for _ in 0..20 {
            let result = self.request("model/list", json!({ "limit": 100, "cursor": cursor }))?;
            for model in result["data"]
                .as_array()
                .ok_or("Invalid Codex model list.")?
            {
                if let Some(id) = model["model"].as_str() {
                    models.push((
                        id.to_string(),
                        model["displayName"].as_str().unwrap_or(id).to_string(),
                    ));
                }
            }
            let next = result["nextCursor"].clone();
            if next.is_null() {
                return Ok(models);
            }
            if next == cursor {
                return Err("Codex repeated its model-list cursor.".into());
            }
            cursor = next;
        }
        Err("Codex returned too many model-list pages.".into())
    }

    pub fn answer(
        &mut self,
        options: TurnOptions<'_>,
        mut on_tool: impl FnMut(&str, &Value) -> (String, bool),
        mut on_request: impl FnMut(&str, &Value) -> Option<Value>,
        mut on_session: impl FnMut(&str),
        mut on_delta: impl FnMut(String),
    ) -> Result<Reply, String> {
        self.require_account()?;
        let TurnOptions {
            model,
            system,
            history,
            query,
            tools,
            session_id,
            full_access,
        } = options;
        let configuration = self.request("config/read", json!({ "includeLayers": false }))?;
        let native = configuration["config"]["developer_instructions"]
            .as_str()
            .unwrap_or("");
        let instructions = if native.is_empty() {
            system.to_string()
        } else {
            format!("{native}\n\n{system}")
        };
        // Keep the CLI's native tools, MCP servers, skills and permissions.
        // Only an explicit setting in Mochi enables unattended full access.
        let mut params = json!({
            "model": if model.is_empty() { Value::Null } else { json!(model) },
            "modelProvider": "openai", "developerInstructions": instructions
        });
        let method = if let Some(id) = session_id {
            params["threadId"] = json!(id);
            "thread/resume"
        } else {
            if !tools.is_empty() {
                params["dynamicTools"] = json!(tools);
            }
            "thread/start"
        };
        if full_access {
            params["sandbox"] = json!("danger-full-access");
            params["approvalPolicy"] = json!("never");
        }
        let thread = self.request(method, params)?;
        let thread_id = thread["thread"]["id"]
            .as_str()
            .ok_or("Codex did not create a conversation.")?
            .to_string();
        on_session(&thread_id);
        if session_id.is_none() && !history.is_empty() {
            self.request(
                "thread/inject_items",
                json!({ "threadId": thread_id, "items": history_items(history) }),
            )?;
        }
        let turn = self.request(
            "turn/start",
            json!({
                "threadId": thread_id, "input": [{ "type": "text", "text": query }]
            }),
        )?;
        let turn_id = turn["turn"]["id"]
            .as_str()
            .ok_or("Codex did not start a reply.")?
            .to_string();
        self.active_turn = Some((thread_id.clone(), turn_id.clone()));
        let mut answer = Answer::default();
        let mut acted = false;
        let mut tool_calls = 0;
        loop {
            let message = self.read()?;
            let params = &message["params"];
            if message["method"] == "item/tool/call"
                && message.get("id").is_some()
                && params["threadId"] == thread_id
                && params["turnId"] == turn_id
            {
                tool_calls += 1;
                let name = params["tool"].as_str().unwrap_or("");
                let allowed = tool_calls <= 100 && tools.iter().any(|t| t["name"] == name);
                let (text, did) = if allowed {
                    on_tool(name, &params["arguments"])
                } else {
                    ("This tool is unavailable.".into(), false)
                };
                acted |= did;
                self.write(json!({ "id": message["id"], "result": {
                    "contentItems": [{ "type": "inputText", "text": text }], "success": allowed
                } }))?;
                continue;
            }
            if message.get("id").is_some() && message.get("method").is_some() {
                let method = message["method"].as_str().unwrap_or("");
                if let Some(result) = on_request(method, params) {
                    self.write(json!({ "id": message["id"], "result": result }))?;
                } else {
                    self.reject_request(&message)?;
                }
                continue;
            }
            if params["threadId"] != thread_id {
                continue;
            }
            if params.get("turnId").is_some() && params["turnId"] != turn_id {
                continue;
            }
            let before = answer.text();
            if message["method"] == "item/completed"
                && matches!(
                    params["item"]["type"].as_str(),
                    Some("commandExecution" | "fileChange" | "mcpToolCall" | "dynamicToolCall")
                )
            {
                acted = true;
            }
            if let Some(result) = answer.event(&message)? {
                self.active_turn = None;
                return Ok(Reply {
                    text: result,
                    acted,
                    session_id: thread_id,
                });
            }
            let text = answer.text();
            if text != before {
                on_delta(text);
            }
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        if let Some((thread, turn)) = self.active_turn.take() {
            let _ = self.write(json!({ "id": self.next_id + 1, "method": "turn/interrupt", "params": { "threadId": thread, "turnId": turn } }));
        }
        self.input.take();
        for _ in 0..50 {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        #[cfg(unix)]
        {
            let _ = Command::new("/bin/kill")
                .args(["-TERM", "--", &format!("-{}", self.child.id())])
                .status();
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            let _ = Command::new("taskkill")
                .args(["/T", "/F", "/PID", &self.child.id().to_string()])
                .creation_flags(0x08000000)
                .status();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn read_message(reader: &mut impl BufRead, total: &mut usize) -> Result<Value, String> {
    let mut line = Vec::new();
    let n = reader
        .take(MAX_LINE as u64 + 1)
        .read_until(b'\n', &mut line)
        .map_err(|_| "Cannot read from Codex.")?;
    *total += n;
    if n == 0 {
        return Err("Codex closed the connection before finishing.".into());
    }
    if n > MAX_LINE || *total > MAX_TOTAL {
        return Err("Codex response exceeded the size limit.".into());
    }
    serde_json::from_slice(&line).map_err(|_| "Codex returned an invalid protocol message.".into())
}

fn rpc_error(error: &Value) -> String {
    error["message"]
        .as_str()
        .unwrap_or("Codex could not complete this request.")
        .chars()
        .take(2000)
        .collect()
}

fn history_items(history: &[Value]) -> Vec<Value> {
    history.iter().filter_map(|m| {
        let role = m["role"].as_str()?;
        if !matches!(role, "user" | "assistant") { return None; }
        let text = m["content"].as_str()?;
        Some(json!({ "type": "message", "role": role,
            "content": [{ "type": if role == "assistant" { "output_text" } else { "input_text" }, "text": text }]
        }))
    }).collect()
}

#[derive(Default)]
struct Answer {
    items: Vec<(String, String)>,
}

impl Answer {
    fn text(&self) -> String {
        self.items
            .iter()
            .map(|(_, text)| text.as_str())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    fn event(&mut self, message: &Value) -> Result<Option<String>, String> {
        let p = &message["params"];
        let (id, text, append) = match message["method"].as_str() {
            Some("item/agentMessage/delta") => (p["itemId"].as_str(), p["delta"].as_str(), true),
            Some("item/completed") if p["item"]["type"] == "agentMessage" => {
                (p["item"]["id"].as_str(), p["item"]["text"].as_str(), false)
            }
            Some("turn/completed") => {
                if p["turn"]["status"] != "completed" {
                    return Err(rpc_error(&p["turn"]["error"]));
                }
                let text = self.text();
                if text.trim().is_empty() {
                    return Err("Codex returned an empty reply.".into());
                }
                return Ok(Some(text));
            }
            _ => return Ok(None),
        };
        if let (Some(id), Some(text)) = (id, text) {
            if let Some((_, current)) = self.items.iter_mut().find(|(key, _)| key == id) {
                if append {
                    current.push_str(text);
                } else {
                    *current = text.to_string();
                }
            } else {
                self.items.push((id.to_string(), text.to_string()));
            }
        }
        if self.items.iter().map(|(_, text)| text.len()).sum::<usize>() > MAX_ANSWER {
            return Err("Codex reply exceeded the size limit.".into());
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completed_items_replace_deltas_without_duplicating_text() {
        let mut answer = Answer::default();
        answer
            .event(
                &json!({"method":"item/agentMessage/delta","params":{"itemId":"a","delta":"Olá"}}),
            )
            .unwrap();
        answer.event(&json!({"method":"item/completed","params":{"item":{"id":"a","type":"agentMessage","text":"Olá!"}}})).unwrap();
        assert_eq!(answer.text(), "Olá!");
        assert_eq!(
            answer
                .event(&json!({"method":"turn/completed","params":{"turn":{"status":"completed"}}}))
                .unwrap(),
            Some("Olá!".into())
        );
    }

    #[test]
    fn a_failed_or_interrupted_turn_never_commits_partial_text() {
        for status in ["failed", "interrupted"] {
            let mut answer = Answer {
                items: vec![("a".into(), "partial".into())],
            };
            assert!(answer.event(&json!({"method":"turn/completed","params":{"turn":{"status":status,"error":{"message":"Try later"}}}})).is_err());
        }
        assert!(Answer::default()
            .event(&json!({"method":"turn/completed","params":{"turn":{"status":"completed"}}}))
            .is_err());
    }

    #[test]
    fn history_keeps_roles_and_skips_native_tool_blocks() {
        let items = history_items(&[
            json!({"role":"user","content":"Lembra-te: azul"}),
            json!({"role":"assistant","content":"Combinado"}),
            json!({"role":"assistant","content":[{"type":"tool_use"}]}),
        ]);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["content"][0]["type"], "input_text");
        assert_eq!(items[1]["content"][0]["type"], "output_text");
    }

    #[test]
    fn the_reader_bounds_lines_total_bytes_and_invalid_json() {
        for data in [vec![b'x'; MAX_LINE + 1], b"not json\n".to_vec(), vec![]] {
            assert!(read_message(&mut data.as_slice(), &mut 0).is_err());
        }
        let mut total = MAX_TOTAL;
        assert!(read_message(&mut b"{}\n".as_slice(), &mut total).is_err());
    }

    #[cfg(unix)]
    fn mock() -> (std::path::PathBuf, std::path::PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "coucou-rpc-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("mock-codex");
        std::fs::write(&exe, r#"#!/usr/bin/python3
import json,sys,pathlib,time
def send(message):
    print(json.dumps(message),flush=True)
for line in sys.stdin:
    m=json.loads(line); method=m.get('method'); p=m.get('params',{}); result={}
    if method=='initialized': continue
    if method=='account/read': result={'account':{'type':'apiKey' if pathlib.Path('api-key').exists() else 'chatgpt'}}
    if method=='thread/start':
        pathlib.Path('request.json').write_text(json.dumps(p))
        result={'thread':{'id':'owned-thread'}}
    if method=='turn/start':
        send({'method':'item/agentMessage/delta','params':{'threadId':'owned-thread','turnId':'turn-1','itemId':'a','delta':'partial'}})
        result={'turn':{'id':'turn-1'}}
    if method is not None:
        send({'id':m['id'],'result':result})
    if method=='turn/start':
        send({'id':99,'method':'item/commandExecution/requestApproval','params':{'threadId':'owned-thread','turnId':'turn-1','command':'echo hello'}})
    if m.get('id')==99 and 'method' not in m:
        text='accepted' if m.get('result',{}).get('decision')=='accept' else 'denied'
        send({'method':'item/completed','params':{'threadId':'owned-thread','turnId':'turn-1','item':{'type':'agentMessage','id':'a','text':text}}})
        send({'method':'turn/completed','params':{'threadId':'owned-thread','turn':{'id':'turn-1','status':'completed'}}})
"#).unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o700)).unwrap();
        (dir, exe)
    }

    #[test]
    #[cfg(unix)]
    fn native_permissions_are_inherited_and_early_events_are_not_lost() {
        for full_access in [false, true] {
            let (cwd, exe) = mock();
            let mut client = Client::start(&exe, &cwd, Duration::from_secs(5), true).unwrap();
            let mut asked = false;
            let mut deltas = Vec::new();
            let reply = client
                .answer(
                    TurnOptions {
                        model: "account-model",
                        system: "Mochi",
                        history: &[],
                        query: "hello",
                        tools: &[],
                        session_id: None,
                        full_access,
                    },
                    |_, _| (String::new(), false),
                    |method, params| {
                        assert_eq!(method, "item/commandExecution/requestApproval");
                        assert_eq!(params["command"], "echo hello");
                        asked = true;
                        Some(json!({"decision":"accept"}))
                    },
                    |_| {},
                    |text| deltas.push(text),
                )
                .unwrap();
            assert!(asked);
            assert!(deltas.iter().any(|text| text == "partial"));
            assert_eq!(reply.text, "accepted");
            assert_eq!(reply.session_id, "owned-thread");
            let request: Value =
                serde_json::from_slice(&std::fs::read(cwd.join("request.json")).unwrap()).unwrap();
            assert_eq!(
                request["sandbox"],
                if full_access {
                    json!("danger-full-access")
                } else {
                    Value::Null
                }
            );
            assert!(
                request.get("config").is_none(),
                "native MCP and shell configuration is inherited"
            );
            drop(client);
            std::fs::remove_dir_all(cwd).unwrap();
        }
    }

    #[test]
    #[cfg(unix)]
    fn an_api_key_account_is_never_used_as_a_chatgpt_account() {
        let (cwd, exe) = mock();
        std::fs::write(cwd.join("api-key"), "").unwrap();
        let mut client = Client::start(&exe, &cwd, Duration::from_secs(5), false).unwrap();
        assert_eq!(client.require_account().unwrap_err(), SIGN_IN);
        drop(client);
        std::fs::remove_dir_all(cwd).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn cancellation_stops_waiting_for_a_cli_reply() {
        let (cwd, exe) = mock();
        let mut client = Client::start(&exe, &cwd, Duration::from_secs(5), false).unwrap();
        client.cancel_with(Arc::new(AtomicBool::new(true)));
        assert_eq!(
            client.require_account().unwrap_err(),
            "The CLI request was cancelled."
        );
        drop(client);
        std::fs::remove_dir_all(cwd).unwrap();
    }
}
