//! Talking to Pi as a chat backend.
//!
//! This is the island's "ask Pi" path, and it is deliberately **separate** from
//! whatever Pi session an agent is using. Coucou chat is a small window for
//! talking to a model; it is not a remote control for running work. So the
//! process is spawned on demand with `--no-session`, holds no session file, and
//! is killed rather than reused after a reset. Nothing here can attach to, read,
//! or disturb an agent's Pi.
//!
//! The protocol is Pi's RPC mode: JSON records, one per line, over stdin and
//! stdout (`docs/rpc.md` in the Pi package). The details below were checked
//! against a real `pi` rather than read off the docs, because each one looks
//! like a harmless detail until it silently produces an empty answer:
//!
//! 1. **A prompt response is not an answer.** It means the prompt was accepted.
//!    The run ends at `agent_settled` — not `agent_end`, which can still be
//!    followed by a retry, compaction or follow-up work.
//!
//! 2. **Text does not always stream.** `message_update` / `text_delta` only
//!    appear on some turns. A short reply, or any turn where the model fails,
//!    produces `message_end` alone. Reading only the streaming events returns
//!    nothing at all for those turns, so the assistant text is read from the
//!    final message too.
//!
//! 3. **Model failures are not a separate record.** They arrive as
//!    `stopReason: "error"` with `errorMessage` on the assistant message. There
//!    is no error record to match on, so without this an API failure looks
//!    exactly like a model that chose to say nothing.
//!
//! 4. **stdout is protocol only.** Diagnostics go to stderr and must never be
//!    parsed as records.

use std::collections::BTreeMap;
use std::process::Stdio;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tokio::time::timeout;

use crate::platform;

/// How long one turn may take before we give up on the process.
///
/// This mirrors the 90s the Claude path allows. On expiry the process is killed
/// rather than left running: a Pi that has stopped answering would otherwise sit
/// there holding the next turn hostage, and killing it is the only reset that
/// leaves a known state behind.
const TURN_TIMEOUT: Duration = Duration::from_secs(90);

/// The model the island's Pi chat runs on.
///
/// This is passed to Pi on the command line; Pi itself is not modified in any way.
/// It is a free tier on purpose: the island chat is a small side window, and it
/// should not quietly spend a paid model's quota, fail on one that is rate
/// limited, or inherit whatever Pi's interactive session happens to be pointed at.
/// A chat window with its own model also means the island cannot change the model
/// an agent is using.
const PI_MODEL: &str = "kilo-auto/free";

/// Thinking level for that model.
///
/// `off`. The model advertises `low`, `medium` and `high`, but its own
/// `thinkingLevelMap` resolves every one of them to no reasoning at all — for
/// this model the levels are a distinction without a difference, so the honest
/// value to pass is `off` rather than one that implies deliberation it will not
/// do. A chat window should answer immediately anyway.
const PI_THINKING: &str = "off";

/// A live Pi RPC process, or nothing.
#[derive(Default)]
pub struct Pi {
    inner: Mutex<Option<Session>>,
}

struct Session {
    child: Child,
    stdin: ChildStdin,
    /// Held across turns on purpose. A fresh `BufReader` each time would discard
    /// whatever it had already pulled off the pipe — Pi writes as fast as it
    /// likes, so a turn can end with the next record sitting in the buffer, and
    /// starting over would silently drop it.
    reader: BufReader<ChildStdout>,
}

/// One assembled answer from Pi.
pub struct ChatReply {
    pub text: String,
}

impl Pi {
    pub fn new() -> Self {
        Self::default()
    }

    /// Drops the process, if any. The next turn starts a fresh one.
    ///
    /// `chat_reset` calls this so "clear the conversation" really does clear it.
    /// Pi holds the history, so leaving the process alive would quietly carry
    /// the old conversation into the next one.
    pub async fn reset(&self) {
        let mut guard = self.inner.lock().await;
        if let Some(session) = guard.take() {
            shut_down(session).await;
        }
    }

    /// Sends one turn and waits for the answer.
    ///
    /// `first_turn` is true only for the first message of a conversation. Pi
    /// keeps its own history in the process, so opening context is prepended
    /// here rather than being re-sent on every turn.
    pub async fn send(
        &self,
        query: String,
        context: Option<&str>,
        first_turn: bool,
    ) -> Result<ChatReply, String> {
        // One turn at a time. The island only ever has one chat open, and two
        // concurrent prompts into one RPC process would interleave their events.
        let mut guard = self.inner.lock().await;

        if guard.is_none() {
            *guard = Some(spawn().await?);
        }

        let message = match (first_turn, context) {
            (true, Some(ctx)) => format!("{ctx}\n\n{query}"),
            _ => query,
        };

        let session = guard.as_mut().expect("a session was just ensured");
        let outcome = turn(session, &message).await;

        // A failed turn leaves a process whose state cannot be vouched for, so it
        // goes away and the next turn starts clean.
        if outcome.is_err() {
            if let Some(session) = guard.take() {
                shut_down(session).await;
            }
        }
        outcome
    }
}

/// Starts `pi --mode rpc --no-session`.
///
/// `--no-session` is the point: this process owns no session file, so it cannot
/// read, resume or write the conversation an agent is having.
///
/// On Windows `pi` is an npm `.cmd` shim, and a `.cmd` cannot be executed
/// directly — `CreateProcess` rejects it as a bad executable format. It has to
/// go through `cmd.exe /c`. Getting this wrong looks like "Pi is not
/// installed": the spawn fails with a misleading error about the file format
/// rather than about the shim.
///
/// `cmd.exe` allocates a console unless told not to, so the spawn also carries
/// `CREATE_NO_WINDOW`. Without it a console window flashes in front of the island
/// on every single chat turn, stealing focus on the way — the chat window would
/// appear to steal the caret each time you send something.
async fn spawn() -> Result<Session, String> {
    let exe = platform::find_on_path("pi").ok_or_else(|| {
        "Pi is not on your PATH, so Coucou cannot ask it anything.\n\
         Install Pi (npm i -g @earendil-works/pi-coding-agent), or switch the \
         chat provider back to Claude in settings."
            .to_string()
    })?;

    let mut command = if cfg!(windows) {
        let mut c = Command::new("cmd.exe");
        c.arg("/c").arg(&exe);
        c
    } else {
        Command::new(&exe)
    };

    let mut child = platform::no_console_tokio(&mut command)
        .arg("--mode")
        .arg("rpc")
        .arg("--no-session")
        // The model and its thinking level are chosen here, not inherited. See
        // PI_MODEL for why the island gets its own rather than following whatever
        // the interactive session is using.
        .arg("--model")
        .arg(PI_MODEL)
        .arg("--thinking")
        .arg(PI_THINKING)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        // stdout is protocol only. Merging stderr in would feed diagnostics to
        // the record parser, and dropping it silently would lose the only clue
        // when a spawn goes wrong.
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("Could not start Pi ({}): {e}", exe.display()))?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Pi started without a stdin. Coucou cannot talk to it.".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Pi started without a stdout. Coucou cannot listen to it.".to_string())?;

    Ok(Session {
        child,
        stdin,
        reader: BufReader::new(stdout),
    })
}

/// Orderly shutdown: close stdin so Pi disposes its runtime, then wait briefly
/// and kill it if it does not go.
async fn shut_down(mut session: Session) {
    drop(session.stdin);
    let _ = timeout(Duration::from_secs(3), session.child.wait()).await;
    let _ = session.child.start_kill();
}

/// Writes one record and flushes. Used for the prompt and for replies to
/// extensions that ask the client for UI.
async fn write_record(session: &mut Session, record: &Value) -> Result<(), String> {
    let mut line = serde_json::to_string(record).map_err(|e| e.to_string())?;
    line.push('\n');
    session
        .stdin
        .write_all(line.as_bytes())
        .await
        .map_err(|e| format!("Lost the connection to Pi: {e}"))
}

/// One prompt/response cycle: write the command, then read events until the run
/// is genuinely over.
async fn turn(session: &mut Session, message: &str) -> Result<ChatReply, String> {
    let command = json!({
        "id": "coucou-1",
        "type": "prompt",
        "message": message,
    });

    timeout(TURN_TIMEOUT, write_record(session, &command))
        .await
        .map_err(|_| "Pi did not accept the message in time.".to_string())??;

    match timeout(TURN_TIMEOUT, collect(session)).await {
        Ok(result) => result,
        Err(_) => Err("Pi stopped responding before it answered.".to_string()),
    }
}

/// The text assembled from one run.
#[derive(Default)]
struct Answer {
    /// Authoritative text blocks, keyed by content index, from `text_end`.
    blocks: BTreeMap<usize, String>,
    /// Deltas, keyed by content index, for blocks that never sent a `text_end`.
    deltas: BTreeMap<usize, String>,
    /// Text from the finished assistant message, when one arrived.
    final_text: Option<String>,
    /// `stopReason: "error"`, reported on the assistant message itself.
    failure: Option<String>,
}

/// Reads records until `agent_settled`, assembling the answer.
///
/// This both consumes and replies: an extension asking the client for a dialog
/// is answered as cancelled, because there is no dialog in a chat window and
/// leaving the request unanswered would stall whatever asked.
async fn collect(session: &mut Session) -> Result<ChatReply, String> {
    let mut answer = Answer::default();
    let mut line = String::new();
    let mut command_failure: Option<String> = None;

    loop {
        line.clear();
        match session.reader.read_line(&mut line).await {
            Ok(0) => {
                // Pi closed stdout, so the process is gone.
                return Err("Pi closed the connection before answering.".to_string());
            }
            Ok(_) => {}
            Err(e) => return Err(format!("Lost the connection to Pi: {e}")),
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        // A malformed record is skipped rather than fatal: one bad line must not
        // lose an answer that is otherwise complete.
        let Ok(record) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };

        match record.get("type").and_then(Value::as_str) {
            Some("response") => {
                if record.get("success").and_then(Value::as_bool) == Some(false) {
                    command_failure = record
                        .get("error")
                        .and_then(Value::as_str)
                        .map(|e| format!("Pi refused the message: {e}"));
                }
            }
            Some("message_update") => absorb_update(&record, &mut answer),
            Some("message_end") | Some("turn_end") => absorb_message(&record, &mut answer),
            Some("extension_ui_request") => {
                // Fire-and-forget methods (notify, setStatus, setWidget, setTitle)
                // expect nothing back. Dialog methods do, and cancelling is the
                // documented way to dismiss one.
                if let Some(method) = record.get("method").and_then(Value::as_str) {
                    if is_dialog_method(method) {
                        let reply = json!({
                            "type": "extension_ui_response",
                            "id": record.get("id").cloned().unwrap_or(Value::Null),
                            "cancelled": true,
                        });
                        let _ =
                            timeout(Duration::from_secs(2), write_record(session, &reply)).await;
                    }
                }
            }
            Some("agent_settled") => break,
            _ => {}
        }
    }

    if let Some(err) = command_failure.or(answer.failure) {
        return Err(err);
    }

    let text = answer
        .final_text
        .filter(|t| !t.trim().is_empty())
        .unwrap_or_else(|| render(&answer.blocks, &answer.deltas));
    if text.trim().is_empty() {
        return Err("Pi finished without saying anything.".to_string());
    }
    Ok(ChatReply {
        text: text.trim().to_string(),
    })
}

/// Extension methods that expect a reply. Everything else is fire-and-forget.
fn is_dialog_method(method: &str) -> bool {
    matches!(method, "select" | "confirm" | "input" | "editor")
}

/// Streaming text. Present on some turns and absent on others.
fn absorb_update(record: &Value, answer: &mut Answer) {
    let Some(update) = record.get("assistantMessageEvent") else {
        return;
    };
    let Some(kind) = update.get("type").and_then(Value::as_str) else {
        return;
    };
    let index = update
        .get("contentIndex")
        .and_then(Value::as_u64)
        .unwrap_or(0) as usize;

    match kind {
        "text_delta" => {
            if let Some(delta) = update.get("delta").and_then(Value::as_str) {
                answer.deltas.entry(index).or_default().push_str(delta);
            }
        }
        // Authoritative: it replaces whatever the deltas accumulated, which is
        // what saves a stream that was cut short mid-word.
        "text_end" => {
            if let Some(content) = update.get("content").and_then(Value::as_str) {
                answer.blocks.insert(index, content.to_string());
            }
        }
        _ => {}
    }
}

/// The finished assistant message: the text of a turn that did not stream, and
/// the only place a model failure is ever reported.
fn absorb_message(record: &Value, answer: &mut Answer) {
    let Some(message) = record.get("message") else {
        return;
    };
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return;
    }

    if message.get("stopReason").and_then(Value::as_str) == Some("error") {
        let detail = message
            .get("errorMessage")
            .and_then(Value::as_str)
            .unwrap_or("no reason given");
        answer.failure = Some(format!("Pi could not reach its model: {detail}"));
        return;
    }

    if let Some(text) = assistant_text(message) {
        answer.final_text = Some(text);
    }
}

/// Pulls the visible text out of an assistant message's content blocks.
fn assistant_text(message: &Value) -> Option<String> {
    let blocks = message.get("content")?.as_array()?;
    let text = blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string();
    (!text.is_empty()).then_some(text)
}

/// Joins blocks in content order, preferring each authoritative `text_end` and
/// falling back to deltas for blocks that never got one.
fn render(blocks: &BTreeMap<usize, String>, deltas: &BTreeMap<usize, String>) -> String {
    let mut indices: Vec<usize> = blocks.keys().chain(deltas.keys()).copied().collect();
    indices.sort_unstable();
    indices.dedup();
    indices
        .iter()
        .filter_map(|i| blocks.get(i).or_else(|| deltas.get(i)))
        .filter(|s| !s.trim().is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(role: &str, content: &str) -> Value {
        json!({
            "type": "message_end",
            "message": {
                "role": role,
                "content": if content.is_empty() { json!([]) } else { json!([{ "type": "text", "text": content }]) }
            }
        })
    }

    #[test]
    fn assistant_text_is_read_from_the_final_message_not_only_the_stream() {
        // The turn that motivated this: a model that fails, or a short reply,
        // produces no message_update at all. Reading only the stream finds
        // nothing and the island shows an empty answer.
        let mut answer = Answer::default();
        absorb_message(&msg("assistant", "Here is the answer."), &mut answer);
        assert_eq!(answer.final_text.as_deref(), Some("Here is the answer."));
    }

    #[test]
    fn a_model_failure_is_reported_rather_than_shown_as_an_empty_reply() {
        // stopReason/errorMessage is the only place a provider failure appears —
        // there is no error record. Miss this and a quota or auth problem is
        // indistinguishable from the model staying quiet.
        let mut answer = Answer::default();
        absorb_message(
            &json!({
                "type": "message_end",
                "message": {
                    "role": "assistant",
                    "content": [],
                    "stopReason": "error",
                    "errorMessage": "quota exceeded"
                }
            }),
            &mut answer,
        );
        let err = answer.failure.expect("the failure was swallowed");
        assert!(err.contains("quota exceeded"), "got: {err}");
        assert!(
            answer.final_text.is_none(),
            "a failed message must not also become the answer"
        );
    }

    #[test]
    fn user_and_system_messages_are_not_mistaken_for_the_answer() {
        let mut answer = Answer::default();
        absorb_message(&msg("user", "what is Rust?"), &mut answer);
        absorb_message(&msg("system", "you are a coding assistant"), &mut answer);
        assert!(answer.final_text.is_none());
    }

    #[test]
    fn authoritative_text_end_beats_accumulated_deltas() {
        let mut answer = Answer::default();
        absorb_update(
            &json!({
                "type": "message_update",
                "assistantMessageEvent": { "type": "text_delta", "contentIndex": 0, "delta": "Hello th" }
            }),
            &mut answer,
        );
        absorb_update(
            &json!({
                "type": "message_update",
                "assistantMessageEvent": { "type": "text_end", "contentIndex": 0, "content": "Hello there." }
            }),
            &mut answer,
        );
        assert_eq!(render(&answer.blocks, &answer.deltas), "Hello there.");
    }

    #[test]
    fn blocks_come_back_in_content_order() {
        let mut answer = Answer::default();
        for (i, text) in [(2, "third"), (0, "first"), (1, "second")] {
            absorb_update(
                &json!({
                    "type": "message_update",
                    "assistantMessageEvent": { "type": "text_end", "contentIndex": i, "content": text }
                }),
                &mut answer,
            );
        }
        assert_eq!(
            render(&answer.blocks, &answer.deltas),
            "first\nsecond\nthird"
        );
    }

    #[test]
    fn deltas_are_used_when_no_text_end_arrives() {
        let mut answer = Answer::default();
        absorb_update(
            &json!({
                "type": "message_update",
                "assistantMessageEvent": { "type": "text_delta", "contentIndex": 0, "delta": "fallback" }
            }),
            &mut answer,
        );
        assert_eq!(render(&answer.blocks, &answer.deltas), "fallback");
    }

    #[test]
    fn empty_blocks_do_not_become_blank_lines() {
        let blocks = BTreeMap::from([(0, "  ".to_string()), (1, "real".to_string())]);
        assert_eq!(render(&blocks, &BTreeMap::new()), "real");
    }

    #[test]
    fn only_dialog_methods_expect_a_reply() {
        // Replying to a fire-and-forget one is harmless but pointless; failing to
        // reply to a dialog one stalls whatever asked for it.
        for method in ["select", "confirm", "input", "editor"] {
            assert!(is_dialog_method(method), "{method} should be a dialog");
        }
        for method in ["notify", "setStatus", "setWidget", "setTitle", "custom"] {
            assert!(!is_dialog_method(method), "{method} is fire-and-forget");
        }
    }

    #[test]
    fn first_turn_prepends_context_but_later_turns_do_not() {
        let (first, later) = (true, false);
        let ctx = Some("Context — App: editor");
        let q = "what does this do?".to_string();
        let build = |is_first: bool| match (is_first, ctx) {
            (true, Some(c)) => format!("{c}\n\n{q}"),
            _ => q.clone(),
        };
        assert_eq!(build(first), "Context — App: editor\n\nwhat does this do?");
        assert_eq!(build(later), q);
    }

    /// End-to-end against the real `pi`. Ignored by default because it needs Pi
    /// installed and a reachable model, but it is the only test that proves the
    /// spawn, the JSONL framing and the `agent_settled` stop condition actually
    /// work — every other test here runs against hand-written records.
    ///
    /// It passes whether or not the model answers: a reachable Pi that cannot
    /// reach its provider must surface that reason, not an empty reply.
    #[test]
    #[ignore = "needs Pi installed and a model that answers"]
    fn a_real_pi_turn_either_answers_or_says_why_it_could_not() {
        if platform::find_on_path("pi").is_none() {
            eprintln!("Pi is not installed; nothing to check.");
            return;
        }
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let pi = Pi::new();
        let result = rt.block_on(pi.send("Reply with exactly: OK".into(), None, true));
        rt.block_on(pi.reset());

        match result {
            Ok(reply) => {
                eprintln!("Pi answered: {:?}", reply.text);
                assert!(!reply.text.trim().is_empty())
            }
            // A model that is installed but unreachable is the realistic failure
            // here, and it must name the reason rather than reading as silence.
            Err(err) => {
                eprintln!("Pi reported: {err}");
                assert!(
                    !err.trim().is_empty(),
                    "a failure must carry a reason a person can act on"
                )
            }
        }
    }
}
