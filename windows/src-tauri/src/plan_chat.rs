// Chat through the user's own Cursor or Kiro plan, by way of their CLIs.
//
// Neither has a public chat API, and calling their private endpoints breaks
// their terms. The CLIs are the supported way: sign in once in a browser, then
// headless runs. Cursor's `agent -p --mode ask` and Kiro's
// `kiro-cli chat --no-interactive --trust-tools=` can only answer, never act.
//
// Each CLI runs in a private, empty folder of its own: the agent has nothing of
// the user's to read, `--resume` is scoped to it, and the hooks these runs fire
// are recognised by it (`is_own_workdir`) so they never show up as sessions.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::process::Command;

use crate::chat::{self, Chat, ChatContext, ChatReply, ModelInfo};
use crate::i18n::{t, tf};
use crate::{platform, secrets};

pub const CURSOR: &str = "cursor";
pub const KIRO: &str = "kiro";
/// In the order the chat falls back through them.
pub const PLANS: [&str; 2] = [CURSOR, KIRO];
pub const DEFAULT_MODEL: &str = "auto";

/// Set on the CLIs Coucou runs itself: coucou-hook stays silent for them.
pub const QUIET_ENV: &str = "COUCOU_QUIET";
const TIMEOUT: Duration = Duration::from_secs(120);
const MAX_INLINE_TEXT: u64 = 200_000;
const CURSOR_KEY: &str = "cursor-api-key";

pub fn is_plan(provider: &str) -> bool {
    PLANS.contains(&provider)
}

fn name(provider: &str) -> &'static str {
    if provider == KIRO { "Kiro" } else { "Cursor" }
}

// ── The CLI sessions ──────────────────────────────────────────────────────────

/// The CLI conversation each plan is in, and how many turns of the chat it
/// has seen. When another provider answered in between, the CLI starts a new
/// conversation with the earlier turns written out in its first message.
#[derive(Default)]
pub struct Sessions {
    inner: Mutex<HashMap<&'static str, Session>>,
}

#[derive(Clone, Default)]
struct Session {
    /// Cursor's session id; Kiro resumes the folder's latest conversation.
    id: Option<String>,
    turns: usize,
}

impl Sessions {
    pub fn reset(&self) {
        self.inner.lock().unwrap().clear();
    }

    /// The session to resume, if it has seen exactly `turns` turns.
    fn current(&self, provider: &'static str, turns: usize) -> Option<Session> {
        self.inner.lock().unwrap().get(provider).filter(|s| s.turns == turns).cloned()
    }

    fn save(&self, provider: &'static str, id: Option<String>, turns: usize) {
        self.inner.lock().unwrap().insert(provider, Session { id, turns });
    }
}

// ── Running the CLIs ──────────────────────────────────────────────────────────

fn cli_names(provider: &str) -> &'static [&'static str] {
    if provider == KIRO { &["kiro-cli"] } else { &["agent", "cursor-agent"] }
}

/// CLI installers put their binary in ~/.local/bin, which a session started
/// from the desktop launcher often does not have on its PATH.
fn cli_path(provider: &str) -> Option<PathBuf> {
    let names = cli_names(provider);
    names.iter().find_map(|n| platform::find_on_path(n)).or_else(|| {
        let bin = platform::home_dir().join(".local").join("bin");
        names.iter().map(|n| bin.join(n)).find(|p| p.is_file())
    })
}

const WORKDIRS: [&str; 2] = ["cursor-chat", "kiro-chat"];

fn workdir(provider: &str) -> Result<PathBuf, String> {
    let dir = crate::settings::local_dir().join(if provider == KIRO { WORKDIRS[1] } else { WORKDIRS[0] });
    platform::ensure_private_dir(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// A hook event from one of Coucou's own CLI runs, for agents that do not
/// pass the environment on to their hooks.
pub fn is_own_workdir(cwd: &str) -> bool {
    !cwd.is_empty() && WORKDIRS.iter().any(|d| Path::new(cwd).starts_with(crate::settings::local_dir().join(d)))
}

fn command(provider: &str, cli: &Path) -> Command {
    let mut cmd = Command::new(cli);
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    cmd.env(QUIET_ENV, "1");
    // Through the environment, never argv: other users can read argv in `ps`.
    // Without a key the CLI uses the `agent login` session, i.e. the plan.
    if provider == CURSOR {
        if let Some(key) = secrets::get(CURSOR_KEY) {
            cmd.env("CURSOR_API_KEY", key);
        }
    }
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

async fn run(provider: &str, mut cmd: Command) -> Result<std::process::Output, String> {
    let who = name(provider);
    let child = cmd
        .spawn()
        .map_err(|e| tf("Could not start the {name} CLI: {error}", &[("name", who), ("error", &e.to_string())]))?;
    match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Ok(out) => out.map_err(|e| e.to_string()),
        Err(_) => Err(tf("{name} took too long to answer.", &[("name", who)])),
    }
}

fn not_found(provider: &str) -> String {
    let login = if provider == KIRO { "kiro-cli login" } else { "agent login" };
    tf("{name} CLI not found. Install it, then sign in with {command}.", &[("name", name(provider)), ("command", login)])
}

// ── One chat turn ─────────────────────────────────────────────────────────────

pub async fn send(
    chat: &Chat,
    provider: &'static str,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let cli = cli_path(provider).ok_or_else(|| not_found(provider))?;
    let turn = chat.begin(provider);
    let session = chat.plans.current(provider, turn.history.len());
    let prompt = build_prompt(session.is_none(), &turn.history, turn.first.then_some(context.as_ref()).flatten(), &query, provider)?;

    let mut cmd = command(provider, &cli);
    cmd.current_dir(workdir(provider)?);
    let resume = session.as_ref().map(|s| s.id.clone());
    if provider == KIRO {
        cmd.args(["chat", "--agent-engine", "v1", "--no-interactive", "--trust-tools=", "--wrap", "never", "--model", model]);
        if resume.is_some() {
            cmd.arg("--resume");
        }
    } else {
        cmd.args(["-p", "--output-format", "json", "--mode", "ask", "--trust", "--model", model]);
        if let Some(Some(id)) = &resume {
            cmd.args(["--resume", id]);
        }
    }
    // `--` so a message starting with "-" is never read as an option.
    cmd.arg("--").arg(prompt);

    let out = run(provider, cmd).await?;
    let (text, id) = if provider == KIRO {
        (parse_kiro_answer(out.status.success(), &out.stdout, &out.stderr)?, None)
    } else {
        parse_cursor_result(&out.stdout, &out.stderr)?
    };
    let user_text = chat::plain_question(turn.first, context.as_ref(), &query);
    chat.commit(
        &turn,
        json!({ "role": "user", "content": user_text }),
        json!({ "role": "assistant", "content": text }),
        &user_text,
        &text,
    );
    chat.plans.save(provider, id, turn.history.len() + 2);
    Ok(ChatReply { text })
}

/// The message for a CLI that keeps the conversation itself: the system
/// prompt, any earlier turns and the context go in its first message only.
fn build_prompt(
    fresh: bool,
    history: &[Value],
    context: Option<&ChatContext>,
    query: &str,
    provider: &str,
) -> Result<String, String> {
    let mut prompt = String::new();
    if fresh {
        prompt.push_str(&chat::system_prompt(false));
        prompt.push_str("\n\n");
        if !history.is_empty() {
            prompt.push_str("Earlier in this conversation:\n");
            for m in history {
                let who = if m["role"] == "assistant" { "Assistant" } else { "User" };
                prompt.push_str(&format!("{who}: {}\n", m["content"].as_str().unwrap_or_default()));
            }
            prompt.push('\n');
        }
    }
    match context {
        Some(ChatContext::File { name: file, path }) => {
            let text = inline_text(path)
                .ok_or_else(|| tf("Only text files can be sent to {name} for now.", &[("name", name(provider))]))?;
            prompt.push_str(&format!("File: {file}\nFile contents:\n{text}\n\n"));
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            prompt.push_str(&chat::window_line(app_name, title, url.as_deref()));
            prompt.push_str("\n\n");
        }
        None => {}
    }
    prompt.push_str(query);
    Ok(prompt)
}

fn inline_text(path: &str) -> Option<String> {
    if std::fs::metadata(path).ok()?.len() > MAX_INLINE_TEXT {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

#[derive(Deserialize)]
struct CursorResult {
    #[serde(default)]
    is_error: bool,
    #[serde(default)]
    result: String,
    session_id: Option<String>,
}

/// (answer, session id) from the Cursor CLI's JSON, or its own error message.
fn parse_cursor_result(stdout: &[u8], stderr: &[u8]) -> Result<(String, Option<String>), String> {
    let stdout = String::from_utf8_lossy(stdout);
    let last = stdout.lines().rev().find(|l| l.trim_start().starts_with('{'));
    if let Some(r) = last.and_then(|l| serde_json::from_str::<CursorResult>(l).ok()) {
        let text = r.result.trim().to_string();
        if r.is_error {
            return Err(if text.is_empty() { tf("{name} returned an error.", &[("name", "Cursor")]) } else { text });
        }
        if text.is_empty() {
            return Err(t("No response text."));
        }
        return Ok((text, r.session_id));
    }
    let stderr = String::from_utf8_lossy(stderr);
    let msg = [stderr.trim(), stdout.trim()].into_iter().find(|s| !s.is_empty());
    Err(msg.map(|m| m.chars().take(300).collect()).unwrap_or_else(|| tf("{name} returned an error.", &[("name", "Cursor")])))
}

/// The answer from the Kiro CLI's stdout, or its `error: …` line.
fn parse_kiro_answer(ok: bool, stdout: &[u8], stderr: &[u8]) -> Result<String, String> {
    if ok {
        let text = strip_ansi(&String::from_utf8_lossy(stdout));
        let text = text.trim_start();
        let text = text.strip_prefix('>').unwrap_or(text).trim();
        return if text.is_empty() { Err(t("No response text.")) } else { Ok(text.to_string()) };
    }
    let stderr = strip_ansi(&String::from_utf8_lossy(stderr));
    let msg = stderr
        .lines()
        .find_map(|l| l.trim().strip_prefix("error:"))
        .or_else(|| stderr.lines().map(str::trim).filter(|l| !l.is_empty()).next_back());
    Err(msg.map(|m| m.trim().chars().take(300).collect()).unwrap_or_else(|| tf("{name} returned an error.", &[("name", "Kiro")])))
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

// ── Models, sign-in status ────────────────────────────────────────────────────

/// The models the plan offers, for the picker in the chat view.
pub async fn models(provider: &str) -> Result<Vec<ModelInfo>, String> {
    let cli = cli_path(provider).ok_or_else(|| not_found(provider))?;
    let mut cmd = command(provider, &cli);
    if provider == KIRO {
        cmd.args(["chat", "--list-models", "--format", "json"]);
    } else {
        cmd.arg("models");
    }
    let out = run(provider, cmd).await?;
    let list = if provider == KIRO {
        parse_kiro_models(&out.stdout)
    } else {
        parse_cursor_models(&strip_ansi(&String::from_utf8_lossy(&out.stdout)))
    };
    if list.is_empty() {
        return Err(tf("{name} returned an error.", &[("name", name(provider))]));
    }
    Ok(list)
}

fn parse_cursor_models(text: &str) -> Vec<ModelInfo> {
    text.lines()
        .filter_map(|l| l.trim().split_once(" - "))
        .filter(|(id, _)| !id.is_empty() && !id.contains(' '))
        .map(|(id, label)| ModelInfo { id: id.to_string(), label: label.trim().to_string() })
        .collect()
}

#[derive(Deserialize)]
struct KiroModels {
    models: Vec<KiroModel>,
}

#[derive(Deserialize)]
struct KiroModel {
    model_id: String,
    model_name: String,
}

fn parse_kiro_models(json: &[u8]) -> Vec<ModelInfo> {
    serde_json::from_slice::<KiroModels>(json)
        .map(|l| l.models.into_iter().map(|m| ModelInfo { id: m.model_id, label: m.model_name }).collect())
        .unwrap_or_default()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanStatus {
    /// Path of the CLI, or None when it is not installed.
    pub cli: Option<String>,
    /// What the CLI says about the account, e.g. "Logged in as …".
    pub status: String,
    pub logged_in: bool,
}

/// Whether the plan's CLI is installed and signed in, for the settings window.
pub async fn status(provider: &str) -> PlanStatus {
    let Some(cli) = cli_path(provider) else {
        return PlanStatus { cli: None, status: String::new(), logged_in: false };
    };
    let mut cmd = command(provider, &cli);
    cmd.arg(if provider == KIRO { "whoami" } else { "status" });
    let (ok, text) = match run(provider, cmd).await {
        Ok(out) => (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string()),
        Err(err) => (false, err),
    };
    let text = strip_ansi(&text);
    let first = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let first = first.trim_start_matches('✓').trim().to_string();
    let logged_in = if provider == KIRO { ok } else { text.to_lowercase().contains("logged in as") };
    PlanStatus { logged_in, status: first, cli: Some(cli.to_string_lossy().to_string()) }
}

/// Opens Cursor's browser sign-in. Returns at once; the settings window polls status.
pub fn login(provider: &str) -> Result<(), String> {
    let cli = cli_path(provider).ok_or_else(|| not_found(provider))?;
    let mut cmd = std::process::Command::new(cli);
    cmd.arg("login").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    platform::no_console(&mut cmd).spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_cursors_answer_and_session() {
        let ok = br#"{"type":"result","subtype":"success","is_error":false,"result":"oi","session_id":"abc"}"#;
        assert_eq!(parse_cursor_result(ok, b""), Ok(("oi".into(), Some("abc".into()))));
        let failed = br#"{"type":"result","is_error":true,"result":"quota exceeded"}"#;
        assert_eq!(parse_cursor_result(failed, b""), Err("quota exceeded".into()));
        // Not JSON at all: the CLI's own message is what the user needs.
        assert_eq!(parse_cursor_result(b"Cannot use this model: x.\n", b""), Err("Cannot use this model: x.".into()));
        assert_eq!(parse_cursor_result(b"", b"Not authenticated\n"), Err("Not authenticated".into()));
    }

    #[test]
    fn reads_kiros_answer_or_error() {
        let ok = b"\x1b[m> \x1b[0m\x1b[1m## Fruits\x1b[0m\n\n- Apple\x1b[0m";
        assert_eq!(parse_kiro_answer(true, ok, b""), Ok("## Fruits\n\n- Apple".into()));
        let err = b"\x1b[mWARNING: \x1b[0m--trust-tools arg\nerror: Model 'x' does not exist.\n";
        assert_eq!(parse_kiro_answer(false, b"", err), Err("Model 'x' does not exist.".into()));
        assert_eq!(parse_kiro_answer(false, b"", b"Not logged in\n"), Err("Not logged in".into()));
    }

    #[test]
    fn lists_both_clis_models() {
        let text = "Available models\n\nauto - Auto (current, default)\ncomposer-2.5 - Composer 2.5\n";
        let ids: Vec<_> = parse_cursor_models(text).into_iter().map(|m| m.id).collect();
        assert_eq!(ids, ["auto", "composer-2.5"]);
        let json = br#"{"models":[{"model_name":"auto","model_id":"auto"},{"model_name":"Sonnet","model_id":"claude-sonnet-5"}]}"#;
        assert_eq!(parse_kiro_models(json)[1], ModelInfo { id: "claude-sonnet-5".into(), label: "Sonnet".into() });
        assert!(parse_kiro_models(b"not json").is_empty());
        assert_eq!(strip_ansi("\u{1b}[32m✓\u{1b}[0m Logged in"), "✓ Logged in");
    }

    #[test]
    fn a_fresh_cli_conversation_carries_the_earlier_turns() {
        let history = vec![
            json!({ "role": "user", "content": "hi" }),
            json!({ "role": "assistant", "content": "hello" }),
        ];
        let prompt = build_prompt(true, &history, None, "and now?", CURSOR).unwrap();
        assert!(prompt.contains("Earlier in this conversation:\nUser: hi\nAssistant: hello\n"));
        assert!(prompt.ends_with("and now?"));
        assert_eq!(build_prompt(false, &history, None, "and now?", CURSOR).unwrap(), "and now?");
    }

    #[test]
    fn a_session_is_resumed_only_while_it_has_seen_every_turn() {
        let s = Sessions::default();
        assert!(s.current(CURSOR, 0).is_none());
        s.save(CURSOR, Some("abc".into()), 2);
        assert_eq!(s.current(CURSOR, 2).and_then(|x| x.id), Some("abc".into()));
        // Another provider answered in between: start over.
        assert!(s.current(CURSOR, 4).is_none());
        assert!(s.current(KIRO, 2).is_none());
        s.reset();
        assert!(s.current(CURSOR, 2).is_none());
    }
}
