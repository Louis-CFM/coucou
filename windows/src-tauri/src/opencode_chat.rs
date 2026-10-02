// opencode CLI chat backend — routes the island chat through the user's own
// opencode (`opencode run`) instead of the Anthropic API, so whatever model
// the user configured there (GPT, Claude, …) answers from the notch.
//
// Everything happens here rather than in the island: the prompt, the session
// id and any file bytes never cross the IPC boundary, and the query is passed
// as argv (never through a shell), so paths and punctuation stay inert.
//
// Multi-turn works by keeping opencode's session id after the first turn and
// passing `--session` on later ones, in the same working directory.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;

use crate::claude::{ChatContext, ChatReply};

/// `opencode run` can think for a while; the Claude API path uses 90 s, but a
/// local agent with tools deserves more rope before the island gives up.
const RUN_TIMEOUT: Duration = Duration::from_secs(300);

/// Preamble sent once per session so answers fit a notch readout.
const PERSONA: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
Answer in the user's language. Be helpful and complete, but concise enough for a small popup. \
Use plain text with line breaks, no markdown formatting.";

#[derive(Default)]
pub struct OpencodeChat {
    session: Mutex<Option<ChatSession>>,
    /// Flipped by `cancel`. The blocking HTTP call cannot be interrupted, but the
    /// turn awaiting it can: `send` races the request against this and gives up as
    /// soon as it is set, so Escape stops waiting rather than posting a request to
    /// the server and hoping it does something.
    cancelled: Arc<AtomicBool>,
}

struct ChatSession {
    id: String,
    dir: String,
}

impl OpencodeChat {
    pub fn reset(&self) {
        *self.session.lock().unwrap() = None;
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatStatus {
    pub bin_configured: String,
    pub bin_resolved: Option<String>,
    pub claude_key_present: bool,
}

/// Where the binary comes from: explicit setting first, then well-known spots.
pub fn resolve_bin(configured: &str) -> Option<PathBuf> {
    let trimmed = configured.trim();
    if !trimmed.is_empty() {
        let p = PathBuf::from(trimmed);
        if p.is_file() {
            return Some(p);
        }
        return None;
    }
    if let Some(p) = crate::platform::find_on_path("opencode") {
        return Some(p);
    }
    if let Some(home) = std::env::var_os("USERPROFILE").map(PathBuf::from) {
        for rel in [
            ".bun/bin/opencode.exe",
            "scoop/shims/opencode.exe",
            ".opencode/bin/opencode.exe",
        ] {
            let p = home.join(rel);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

/// The real `opencode` program to start a server with, rather than a launcher
/// that wraps it.
///
/// On a scoop install, `opencode` on PATH is a shim: a small executable that
/// starts the genuine binary as a second process and stays alive beside it. For
/// `opencode run` that indirection does not matter, because the run is awaited to
/// completion. For a server it matters a lot: the process Coucou holds is not the
/// one holding the port, so stopping it reliably is guesswork. Not every install
/// uses a shim, so this looks for the actual program where installs put it and
/// only falls back to PATH when there is none to find.
pub fn resolve_server_bin(configured: &str) -> Option<PathBuf> {
    let trimmed = configured.trim();
    if !trimmed.is_empty() {
        // An explicit path in Settings is the user's choice, shim or not.
        let p = PathBuf::from(trimmed);
        return p.is_file().then_some(p);
    }
    if let Some(home) = std::env::var_os("USERPROFILE").map(PathBuf::from) {
        // scoop keeps the real program in a versioned folder, with `current`
        // pointing at the live one, and keeps only wrappers in `shims`.
        let current = home.join("scoop/apps/opencode/current/opencode.exe");
        if current.is_file() {
            return Some(current);
        }
        for rel in [".bun/bin/opencode.exe", ".opencode/bin/opencode.exe"] {
            let p = home.join(rel);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    // Nothing but PATH — take it rather than fail, shim included.
    crate::platform::find_on_path("opencode")
}

/// One chat turn. Returns the assistant's text, or a message the island shows
/// in the note view.
pub async fn send(
    chat: &OpencodeChat,
    bin_configured: &str,
    model_override: &str,
    query: String,
    context: Option<ChatContext>,
    session_override: Option<String>,
) -> Result<ChatReply, String> {
    let bin = resolve_bin(bin_configured).ok_or_else(|| {
        "opencode not found. Install it (opencode.ai) or set its path in Settings → Chat.".to_string()
    })?;

    // A leading "/" is one of the user's own commands from the opencode `/`
    // menu, not chat prose. It runs verbatim: no persona preamble, and no
    // remembered session, because the command owns the whole turn the same way
    // it would in the TUI.
    let command = query
        .strip_prefix('/')
        .map(|rest| match rest.split_once(char::is_whitespace) {
            Some((name, args)) => (name.trim().to_string(), args.trim().to_string()),
            None => (rest.trim().to_string(), String::new()),
        })
        .filter(|(name, _)| !name.is_empty());

    // An explicitly picked session wins over the remembered one. Its working
    // directory comes from the live session list so `--dir` matches the session
    // rather than the home folder the new-chat path uses.
    let picked = session_override
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|id| {
            let dir = crate::opencode_server::sessions()
                .into_iter()
                .find(|s| s.id == id)
                .map(|s| s.directory)
                .filter(|d| !d.is_empty())
                .unwrap_or_else(home_dir);
            (id.to_string(), dir)
        });

    // opencode's own TUI built-ins are handled entirely inside the terminal UI:
    // they never reach the server as commands and `opencode run --command`
    // rejects them. The ones that map to a real server route are dispatched
    // straight to that route here, so they perform the genuine action.
    if let Some((name, _)) = &command {
        if let Some(canonical) = crate::opencode_server::builtin_for(name) {
            let target = picked
                .as_ref()
                .map(|(id, _)| id.clone())
                .or_else(|| {
                    chat.session
                        .lock()
                        .unwrap()
                        .as_ref()
                        .map(|s| s.id.clone())
                })
                .unwrap_or_default();
            let text = crate::opencode_server::act(canonical, &target)?;
            return Ok(ChatReply { text });
        }
    }

    let first;
    let (session_id, dir, files, message) = {
        let guard = chat.session.lock().unwrap();
        if let Some(cmd) = &command {
            first = true;
            let _ = cmd;
            (None, home_dir(), Vec::new(), query.clone())
        } else if let Some((id, dir)) = &picked {
            first = false;
            (Some(id.clone()), dir.clone(), Vec::new(), query.clone())
        } else {
            match &*guard {
                Some(s) => {
                    first = false;
                    (Some(s.id.clone()), s.dir.clone(), Vec::new(), query.clone())
                }
                None => {
                    first = true;
                    let (dir, files, ctx_text) = first_turn_context(&context);
                    let mut message = String::from(PERSONA);
                    if !ctx_text.is_empty() {
                        message.push_str("\n\nContext: ");
                        message.push_str(&ctx_text);
                    }
                    message.push_str("\n\nUser: ");
                    message.push_str(&query);
                    (None, dir, files, message)
                }
            }
        }
    };

    // Persistent-server transport. A `/command` still goes through `opencode run`
    // because `--command` owns the whole turn, and an attachment still needs
    // `--file`, which the server route would otherwise have to reimplement as an
    // upload. Everything else is a plain turn and goes over HTTP.
    let via_server = crate::settings::load().chat_via_server;
    if via_server && command.is_none() && files.is_empty() {
        // A fresh turn is not a cancelled one.
        chat.cancelled.store(false, Ordering::Relaxed);
        let task = tokio::task::spawn_blocking({
            let sid = session_id.clone();
            let model = model_override.to_string();
            let msg = message.clone();
            move || send_via_server(sid.as_deref(), &model, &msg)
        });
        let attempt = tokio::select! {
            res = task => res.map_err(|e| format!("opencode task failed: {e}"))?,
            _ = wait_for_cancel(chat.cancelled.clone()) => {
                // The request itself is still in flight and cannot be pulled back,
                // but nothing is waiting on it any more. The front end shows this.
                return Err("Cancelled.".to_string());
            }
        };
        match attempt {
            Ok((id, text)) => {
                if picked.is_none() {
                    *chat.session.lock().unwrap() = Some(ChatSession { id, dir });
                }
                let _ = first;
                return Ok(ChatReply { text });
            }
            // A transport hiccup must not cost the user their message: log it
            // and let the `opencode run` path below try instead.
            Err(err) => {
                crate::log::line(format!("server turn failed ({err}), using opencode run"));
            }
        }
    }

    let model = model_override.trim();
    let mut args: Vec<String> = vec![
        "run".into(),
        "--format".into(),
        "json".into(),
        "--title".into(),
        "Coucou chat".into(),
        "--dir".into(),
        dir.clone(),
    ];
    if !model.is_empty() {
        args.push("--model".into());
        args.push(model.to_string());
    }
    // Commands run in a throwaway session: they must not land in the
    // conversation the island is holding open.
    if command.is_none() {
        if let Some(id) = &session_id {
            args.push("--session".into());
            args.push(id.clone());
        }
    }
    if let Some((name, _)) = &command {
        args.push("--command".into());
        args.push(name.clone());
    }
    // NOTE: the message must come before `--file`: yargs array options greedily
    // swallow every positional after them, so `--file f "message"` eats the
    // message as a second file ("File not found: <your question>").
    args.push(message);
    for f in &files {
        args.push("--file".into());
        args.push(f.clone());
    }

    let bin_str = bin.to_string_lossy().to_string();
    let (ok, stdout, stderr) =
        tokio::task::spawn_blocking(move || run_blocking(&bin_str, &args))
            .await
            .map_err(|e| format!("opencode task failed: {e}"))??;

    let parsed = parse_events(&stdout);
    // Only a plain chat turn updates the remembered session. A command ran in a
    // throwaway session and a picked session is already the active one, so
    // neither should replace what the island is holding on to.
    if command.is_none() && picked.is_none() {
        if let Some(id) = parsed.session_id {
            *chat.session.lock().unwrap() = Some(ChatSession { id, dir });
        }
    }

    if let Some(err) = parsed.error {
        return Err(err);
    }
    if !ok {
        let tail: String = stderr.lines().rev().take(3).collect::<Vec<_>>().join(" | ");
        let detail = if tail.trim().is_empty() {
            "unknown error"
        } else {
            tail.trim()
        };
        return Err(format!("opencode failed: {detail}"));
    }
    if parsed.text.trim().is_empty() {
        return Err("opencode returned no text.".into());
    }
    let _ = first;
    Ok(ChatReply {
        text: parsed.text.trim().to_string(),
    })
}

/// One chat turn over the opencode server that is already running.
///
/// The alternative to this is `opencode run`, which boots a whole throwaway
/// Resolves as soon as `flag` is set, so a turn can be raced against a cancel.
///
/// Polls rather than waiting on a notify: the flag is a plain atomic shared with
/// the command that sets it, and the interval is far below the time it takes a
/// person to notice.
async fn wait_for_cancel(flag: Arc<AtomicBool>) {
    while !flag.load(Ordering::Relaxed) {
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

/// Asks the running turn to stop being waited on.
///
/// This sets a flag rather than posting to the server: the request is a blocking
/// HTTP call that cannot be recalled, and asking the server to abort it depends on
/// an endpoint that is not part of anything in this repository. Racing the call
/// locally is the part that is certain to work, and the reply is discarded either
/// way.
pub async fn cancel(chat: &OpencodeChat, _session_id: Option<String>) -> Result<(), String> {
    chat.cancelled.store(true, Ordering::Relaxed);
    Ok(())
}

/// server per message and tears it down again. Here the same turn is two HTTP
/// calls against the long-lived one, which is why replies start sooner.
///
/// Returns the session the turn landed in along with the assistant's text, so
/// the caller can remember it exactly like the `opencode run` path does.
fn send_via_server(
    session_id: Option<&str>,
    model_override: &str,
    message: &str,
) -> Result<(String, String), String> {
    let base = crate::opencode_server::discover(true)
        .ok_or_else(|| "no opencode server is running".to_string())?;
    let client = reqwest::blocking::Client::builder()
        .timeout(RUN_TIMEOUT)
        .build()
        .map_err(|e| e.to_string())?;

    // A brand new conversation has nothing to post into yet.
    let id = match session_id.filter(|s| !s.is_empty()) {
        Some(id) => id.to_string(),
        None => {
            let resp = client
                .post(format!("{base}/session"))
                .json(&serde_json::json!({ "title": "Coucou chat" }))
                .send()
                .map_err(|e| format!("could not open a session: {e}"))?;
            let value: Value = resp.json().map_err(|e| e.to_string())?;
            value
                .get("id")
                .and_then(|id| id.as_str())
                .map(str::to_string)
                .ok_or_else(|| "the server did not return a session id".to_string())?
        }
    };

    let mut body = serde_json::json!({ "parts": [{ "type": "text", "text": message }] });
    // The setting spells the override "provider/model"; the server wants the two
    // halves separately.
    if let Some((provider, model)) = model_override.trim().split_once('/') {
        if !provider.is_empty() && !model.is_empty() {
            body["model"] =
                serde_json::json!({ "providerID": provider, "modelID": model });
        }
    }

    let resp = client
        .post(format!("{base}/session/{id}/message"))
        .json(&body)
        .send()
        .map_err(|e| format!("could not reach the opencode server: {e}"))?;
    let status = resp.status();
    let value: Value = resp.json().map_err(|e| e.to_string())?;
    if !status.is_success() {
        let detail = value
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("unknown error");
        return Err(format!("opencode server said {status}: {detail}"));
    }

    // The reply is a list of parts; only the text ones are the answer, the rest
    // are the step markers around it.
    let text: String = value
        .get("parts")
        .and_then(|parts| parts.as_array())
        .map(|parts| {
            parts
                .iter()
                .filter(|part| part.get("type").and_then(|t| t.as_str()) == Some("text"))
                .filter_map(|part| part.get("text").and_then(|t| t.as_str()))
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default();
    if text.trim().is_empty() {
        return Err("opencode returned no text.".into());
    }
    Ok((id, text.trim().to_string()))
}

/// Working dir + file attachments + context line for a fresh conversation.
pub fn home_dir() -> String {
    std::env::var_os("USERPROFILE")
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| ".".into())
}

fn first_turn_context(context: &Option<ChatContext>) -> (String, Vec<String>, String) {
    let home = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    match context {
        Some(ChatContext::File { name, path }) => {
            let dir = std::path::Path::new(path)
                .parent()
                .map(|p| p.to_string_lossy().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| home.to_string_lossy().to_string());
            (dir, vec![path.clone()], format!("File: {name} (attached)"))
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            let mut text = format!("App: {app_name}, Window: {title}");
            if let Some(url) = url {
                text.push_str(&format!(", URL: {url}"));
            }
            (home.to_string_lossy().to_string(), Vec::new(), text)
        }
        None => (home.to_string_lossy().to_string(), Vec::new(), String::new()),
    }
}

/// Runs the binary synchronously (call from `spawn_blocking`): drains both
/// pipes on helper threads so large `--format json` output can never wedge
/// the child on a full pipe buffer, then enforces the deadline.
fn run_blocking(bin: &str, args: &[String]) -> Result<(bool, String, String), String> {
    use std::io::Read;
    use std::os::windows::process::CommandExt;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let mut child = std::process::Command::new(bin)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("could not start opencode: {e}"))?;

    let out_handle = std::thread::spawn({
        let mut out = child.stdout.take();
        move || {
            let mut buf = Vec::new();
            if let Some(o) = out.as_mut() {
                let _ = o.read_to_end(&mut buf);
            }
            String::from_utf8_lossy(&buf).to_string()
        }
    });
    let err_handle = std::thread::spawn({
        let mut err = child.stderr.take();
        move || {
            let mut buf = Vec::new();
            if let Some(e) = err.as_mut() {
                let _ = e.read_to_end(&mut buf);
            }
            String::from_utf8_lossy(&buf).to_string()
        }
    });

    let deadline = Instant::now() + RUN_TIMEOUT;
    let status = loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(status) => break status,
            None => {
                if Instant::now() > deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("opencode took too long (5 min) — try a shorter question.".into());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    };

    let stdout = out_handle.join().unwrap_or_default();
    let stderr = err_handle.join().unwrap_or_default();
    Ok((status.success(), stdout, stderr))
}

struct Parsed {
    session_id: Option<String>,
    text: String,
    error: Option<String>,
}

/// Pulls the assistant text + session id out of `opencode run --format json`
/// (newline-delimited events, verified against opencode 1.x):
///   {"type":"text","sessionID":"ses_…","part":{"type":"text","text":"… Ness"}}
///   {"type":"tool_use",…}                          → ignored (tools, not chat)
///   {"type":"step_start" | "step_finish",…}        → ignored
///   {"type":"error","error":{"data":{"message":…}}} → surfaced to the island
/// Everything is best-effort: unknown lines and shapes are skipped, never fatal.
fn parse_events(stdout: &str) -> Parsed {
    let mut session_id: Option<String> = None;
    let mut text = String::new();
    let mut error: Option<String> = None;

    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() || !line.starts_with('{') {
            continue;
        }
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if session_id.is_none() {
            session_id = event
                .get("sessionID")
                .and_then(Value::as_str)
                .map(str::to_string);
        }
        match event.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(t) = event
                    .get("part")
                    .and_then(|p| p.get("text"))
                    .and_then(Value::as_str)
                {
                    text.push_str(t);
                }
            }
            Some("error") => {
                let msg = event
                    .get("error")
                    .and_then(|e| {
                        e.get("data")
                            .and_then(|d| d.get("message"))
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .or_else(|| {
                                e.get("message").and_then(Value::as_str).map(str::to_string)
                            })
                    })
                    .or_else(|| {
                        event
                            .get("message")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    })
                    .unwrap_or_else(|| "opencode reported an error.".to_string());
                error = Some(msg);
            }
            _ => {}
        }
    }

    Parsed {
        session_id,
        text,
        error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_assistant_text_and_session_id() {
        let stdout = concat!(
            "{\"type\":\"step_start\",\"timestamp\":1,\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"step-start\"}}\n",
            "{\"type\":\"text\",\"timestamp\":2,\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"text\",\"text\":\"Hello! \"}}\n",
            "{\"type\":\"tool_use\",\"timestamp\":3,\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"tool\",\"tool\":\"read\"}}\n",
            "{\"type\":\"text\",\"timestamp\":4,\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"text\",\"text\":\"How can I help?\"}}\n",
            "{\"type\":\"step_finish\",\"timestamp\":5,\"sessionID\":\"ses_abc\",\"part\":{\"type\":\"step-finish\"}}\n",
        );
        let p = parse_events(stdout);
        assert_eq!(p.session_id.as_deref(), Some("ses_abc"));
        assert_eq!(p.text, "Hello! How can I help?");
        assert!(p.error.is_none());
    }

    #[test]
    fn skips_garbage_lines() {
        let stdout = "not json\n\n{\"type\":\"text\",\"sessionID\":\"s\",\"part\":{\"type\":\"text\",\"text\":\"hi\"}}\n";
        let p = parse_events(stdout);
        assert_eq!(p.text, "hi");
        assert_eq!(p.session_id.as_deref(), Some("s"));
    }

    #[test]
    fn surfaces_errors() {
        let stdout = "{\"type\":\"error\",\"sessionID\":\"ses_x\",\"error\":{\"name\":\"UnknownError\",\"data\":{\"message\":\"boom\"}}}\n";
        let p = parse_events(stdout);
        assert_eq!(p.error.as_deref(), Some("boom"));
    }

    #[test]
    fn resolve_bin_rejects_missing_configured_path() {
        assert!(resolve_bin("C:\\definitely\\not\\here\\opencode.exe").is_none());
    }

    /// A real turn over the persistent server, which is the whole point of the
    /// `chat_via_server` setting. Ignored by default because it costs a model
    /// call and needs a server to be reachable; run it with `--ignored`.
    #[test]
    #[ignore = "talks to a live model"]
    fn server_turn_answers_and_reports_its_session() {
        let (id, text) = send_via_server(None, "", "Reply with exactly: OK").expect("server turn");
        assert!(id.starts_with("ses_"), "expected a session id, got {id}");
        assert!(text.contains("OK"), "expected OK in the reply, got {text:?}");
    }
}
