// Chat from the phone (docs/ANDROID_LINK.md, "Chat").
//
// The phone sends text, this computer asks the provider with ITS key, and the answer
// comes back as small `chatDelta` lines. Nothing here knows a key, a provider address
// or a provider's error text: the backend (a trait, so tests use a fake) answers with a
// string or one of a handful of failure kinds, and each kind has a fixed message written
// here. A provider's own message may echo part of a key, so it never reaches the phone.
//
// What it enforces, whatever the phone sends:
//   * the connection must have asked for the "chat" capability and been offered it;
//   * the switch on the computer is read again for every message (turning it off cancels
//     the running answer and forgets the conversation);
//   * the model must be one the user allowed; the text is at most MAX_TEXT_CHARS;
//   * one running answer at a time, at most MAX_SENDS sends per RATE_WINDOW_MS;
//   * an answer is cancelled when its phone leaves, so nothing keeps running unseen.

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

use super::hub::Out;
use super::server::MAX_LINE;

pub const MAX_TEXT_CHARS: usize = 4000;
pub const MAX_SENDS: usize = 12;
pub const RATE_WINDOW_MS: u64 = 10 * 60 * 1000;
/// Text per `chatDelta` line. Even when every character needs escaping a line stays far under 64 KiB.
pub const DELTA_PIECE: usize = 8 * 1024;
/// The full answer a `chatDone` may carry when the streamed text had to be corrected.
pub const DONE_TEXT_MAX: usize = 30_000;
const MAX_ID: usize = 64;

pub type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// A model the user allowed for the phone. `id` is "provider/model".
#[derive(Debug, Clone, PartialEq)]
pub struct ModelOption {
    pub id: String,
    pub provider: String,
    pub label: String,
}

/// What the user chose on the computer, read again for every message.
#[derive(Debug, Clone, Default)]
pub struct ChatConfig {
    pub enabled: bool,
    pub allowed: Vec<ModelOption>,
}

/// Why a turn failed, as far as the phone may know.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatFail {
    NoKey,
    Unreachable,
    Auth,
    Provider,
    Internal,
}

/// The computer's chat. The real one calls the same provider code as the island's chat.
pub trait ChatBackend: Send + Sync {
    fn config(&self) -> ChatConfig;
    /// One turn of the phone's conversation. `deltas` receives the answer **so far**
    /// (the whole visible text each time), whenever the provider streams it. Returns the full answer.
    fn send(&self, model_id: &str, text: String, deltas: mpsc::UnboundedSender<String>) -> BoxFuture<Result<String, ChatFail>>;
    /// Forget the phone's conversation.
    fn reset(&self);
}

/// The fixed code and message for a failure; never anything a provider wrote.
pub fn reason(code: &str) -> &'static str {
    match code {
        "off" => "Chat from the phone is turned off on the computer.",
        "not_allowed" => "That model is not allowed for the phone.",
        "busy" => "Another answer is still being written.",
        "rate" => "Too many messages. Try again in a few minutes.",
        "too_long" => "The message is too long.",
        "empty" => "Nothing to send.",
        "no_key" => "The computer has no key for that provider.",
        "unreachable" => "The computer could not reach the provider.",
        "auth" => "The provider refused the computer's key.",
        "provider" => "The provider returned an error.",
        "canceled" => "Canceled.",
        _ => "Something went wrong on the computer.",
    }
}

fn fail_code(f: ChatFail) -> &'static str {
    match f {
        ChatFail::NoKey => "no_key",
        ChatFail::Unreachable => "unreachable",
        ChatFail::Auth => "auth",
        ChatFail::Provider => "provider",
        ChatFail::Internal => "internal",
    }
}

fn error_line(id: &str, code: &str) -> Out {
    Out::Line(json!({ "type": "chatError", "id": id, "reason": code, "message": reason(code) }).to_string().into())
}

// ── Streaming a growing text as appended pieces ───────────────────────────────

/// Turns "the answer so far" into appended pieces. A text that stops being an extension of what
/// was already sent (a model's hidden reasoning being filtered, say) is held back, and the final
/// answer corrects it in `chatDone`.
#[derive(Default)]
pub struct DeltaSplitter {
    sent: String,
}

impl DeltaSplitter {
    pub fn feed(&mut self, so_far: &str) -> Vec<String> {
        match so_far.strip_prefix(self.sent.as_str()) {
            Some(rest) if !rest.is_empty() => {
                let pieces = split_chars(rest, DELTA_PIECE);
                self.sent.push_str(rest);
                pieces
            }
            _ => Vec::new(),
        }
    }

    /// The last pieces, and the full answer when what was sent is not a prefix of it.
    pub fn finish(&mut self, answer: &str) -> (Vec<String>, Option<String>) {
        if answer.starts_with(self.sent.as_str()) {
            (self.feed(answer), None)
        } else {
            (Vec::new(), Some(cut(answer, DONE_TEXT_MAX).to_string()))
        }
    }
}

/// At most `max` bytes per piece, never inside a character.
fn split_chars(text: &str, max: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        let piece = cut(rest, max);
        out.push(piece.to_string());
        rest = &rest[piece.len()..];
    }
    out
}

fn cut(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// A line that fits the phone's 64 KiB limit, shortening `text` if it would not.
fn fit(mut v: Value, field: &str) -> Out {
    loop {
        let line = v.to_string();
        if line.len() < MAX_LINE - 1024 {
            return Out::Line(line.into());
        }
        let shorter = cut(v[field].as_str().unwrap_or(""), v[field].as_str().map_or(0, str::len) / 2).to_string();
        v[field] = Value::String(shorter);
    }
}

// ── The link's chat ───────────────────────────────────────────────────────────

struct Run {
    token: u64,
    id: String,
    conn: u64,
    abort: AbortHandle,
}

#[derive(Default)]
struct Gate {
    running: Option<Run>,
    sends: VecDeque<u64>,
    next_token: u64,
}

pub struct ChatLink {
    backend: Arc<dyn ChatBackend>,
    gate: Mutex<Gate>,
}

/// Frees the "one at a time" slot when the answer ends, however it ends (finished, failed, aborted).
struct Slot {
    link: Arc<ChatLink>,
    token: u64,
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut g = self.link.gate.lock().unwrap();
        if g.running.as_ref().is_some_and(|r| r.token == self.token) {
            g.running = None;
        }
    }
}

impl ChatLink {
    pub fn new(backend: Arc<dyn ChatBackend>) -> Arc<ChatLink> {
        Arc::new(ChatLink { backend, gate: Mutex::new(Gate::default()) })
    }

    /// Offered to a phone only while the user's switch is on.
    pub fn enabled(&self) -> bool {
        self.backend.config().enabled
    }

    /// The switch went off (or the link stopped): nothing keeps running and the conversation is forgotten.
    pub fn shutdown(&self) {
        self.cancel_where(|_| true);
        self.backend.reset();
    }

    /// A phone left: its answer, if any, stops.
    pub fn cancel_conn(&self, conn: u64) {
        self.cancel_where(|r| r.conn == conn);
    }

    fn cancel_where(&self, which: impl Fn(&Run) -> bool) -> Option<Run> {
        let mut g = self.gate.lock().unwrap();
        if g.running.as_ref().is_some_and(which) {
            let run = g.running.take()?;
            run.abort.abort();
            return Some(run);
        }
        None
    }

    fn models_line(&self) -> Out {
        let cfg = self.backend.config();
        let models: Vec<Value> = if cfg.enabled {
            cfg.allowed.iter().map(|m| json!({ "id": m.id, "provider": m.provider, "label": m.label })).collect()
        } else {
            Vec::new()
        };
        Out::Line(json!({ "type": "chatModels", "models": models }).to_string().into())
    }

    /// One chat message from a phone that negotiated the capability. Never blocks; answers are written
    /// by a task that stops when the connection's channel closes.
    pub fn handle(self: &Arc<Self>, conn: u64, tx: &mpsc::Sender<Out>, msg: &Value, now: u64) {
        let say = |o: Out| {
            let _ = tx.try_send(o);
        };
        match msg["type"].as_str() {
            Some("chatModels") => say(self.models_line()),
            Some("chatReset") => {
                if let Some(r) = self.cancel_where(|r| r.conn == conn) {
                    say(error_line(&r.id, "canceled"));
                }
                self.backend.reset();
            }
            Some("chatCancel") => {
                let id = msg["id"].as_str().unwrap_or("");
                if let Some(r) = self.cancel_where(|r| r.conn == conn && r.id == id) {
                    say(error_line(&r.id, "canceled"));
                }
            }
            Some("chatSend") => self.send(conn, tx, msg, now),
            _ => {}
        }
    }

    fn send(self: &Arc<Self>, conn: u64, tx: &mpsc::Sender<Out>, msg: &Value, now: u64) {
        // Without a usable id there is nothing to answer to.
        let Some(id) = msg["id"].as_str().filter(|i| !i.is_empty() && i.len() <= MAX_ID && i.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')) else {
            return;
        };
        let refuse = |code: &str| {
            let _ = tx.try_send(error_line(id, code));
        };
        let cfg = self.backend.config();
        if !cfg.enabled {
            return refuse("off");
        }
        let text = msg["text"].as_str().unwrap_or("");
        if text.trim().is_empty() {
            return refuse("empty");
        }
        if text.chars().count() > MAX_TEXT_CHARS {
            return refuse("too_long");
        }
        let model = msg["model"].as_str().unwrap_or("");
        if !cfg.allowed.iter().any(|m| m.id == model) {
            return refuse("not_allowed");
        }

        let mut g = self.gate.lock().unwrap();
        if g.running.is_some() {
            drop(g);
            return refuse("busy");
        }
        while g.sends.front().is_some_and(|&t| now.saturating_sub(t) >= RATE_WINDOW_MS) {
            g.sends.pop_front();
        }
        if g.sends.len() >= MAX_SENDS {
            drop(g);
            return refuse("rate");
        }
        g.sends.push_back(now);
        g.next_token += 1;
        let token = g.next_token;

        let (link, tx, id_owned, model, text) = (self.clone(), tx.clone(), id.to_string(), model.to_string(), text.to_string());
        let task_id = id_owned.clone();
        let join = tokio::spawn(async move {
            let _slot = Slot { link: link.clone(), token };
            answer(&link, &tx, &task_id, &model, text).await;
        });
        g.running = Some(Run { token, id: id_owned, conn, abort: join.abort_handle() });
    }
}

/// Runs one turn and writes its lines. Ends quietly if the phone's channel is gone.
async fn answer(link: &ChatLink, tx: &mpsc::Sender<Out>, id: &str, model: &str, text: String) {
    let (dtx, mut drx) = mpsc::unbounded_channel::<String>();
    let forward = {
        let (tx, id) = (tx.clone(), id.to_string());
        tokio::spawn(async move {
            let mut splitter = DeltaSplitter::default();
            while let Some(so_far) = drx.recv().await {
                for piece in splitter.feed(&so_far) {
                    let line = json!({ "type": "chatDelta", "id": id, "text": piece }).to_string();
                    if tx.send(Out::Line(line.into())).await.is_err() {
                        return splitter;
                    }
                }
            }
            splitter
        })
    };
    let result = link.backend.send(model, text, dtx).await;
    // The sender went with the future: the forwarder drains what is queued and ends.
    let Ok(mut splitter) = forward.await else { return };
    match result {
        Ok(full) => {
            let (pieces, correction) = splitter.finish(&full);
            for piece in pieces {
                let line = json!({ "type": "chatDelta", "id": id, "text": piece }).to_string();
                if tx.send(Out::Line(line.into())).await.is_err() {
                    return;
                }
            }
            let mut done = json!({ "type": "chatDone", "id": id });
            if let Some(full) = correction {
                done["text"] = Value::String(full);
            }
            let _ = tx.send(fit(done, "text")).await;
        }
        Err(f) => {
            let _ = tx.send(error_line(id, fail_code(f))).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_growing_text_is_sent_as_appended_pieces() {
        let mut s = DeltaSplitter::default();
        assert_eq!(s.feed("Hel"), vec!["Hel"]);
        assert_eq!(s.feed("Hello"), vec!["lo"]);
        assert!(s.feed("Hello").is_empty());
        assert_eq!(s.finish("Hello world"), (vec![" world".to_string()], None));
    }

    #[test]
    fn a_text_that_is_rewritten_is_corrected_by_the_final_answer() {
        let mut s = DeltaSplitter::default();
        assert_eq!(s.feed("<think>hmm"), vec!["<think>hmm"]);
        assert!(s.feed("Answer").is_empty(), "not an extension: held back");
        let (pieces, correction) = s.finish("Answer");
        assert!(pieces.is_empty());
        assert_eq!(correction.as_deref(), Some("Answer"));
    }

    #[test]
    fn pieces_never_split_a_character_and_stay_small() {
        let text = "é".repeat(DELTA_PIECE); // 2 bytes each
        let mut s = DeltaSplitter::default();
        let pieces = s.feed(&text);
        assert!(pieces.len() >= 2);
        assert!(pieces.iter().all(|p| p.len() <= DELTA_PIECE));
        assert_eq!(pieces.concat(), text);
    }

    #[test]
    fn a_huge_correction_is_cut_and_every_line_fits_the_limit() {
        let mut s = DeltaSplitter::default();
        s.feed("x");
        let (_, c) = s.finish(&"é".repeat(100_000));
        assert!(c.unwrap().len() <= DONE_TEXT_MAX);
        // control characters double or sextuple in JSON: the line is shortened until it fits
        let Out::Line(l) = fit(json!({ "type": "chatDone", "id": "a", "text": "\u{1}".repeat(30_000) }), "text") else { panic!() };
        assert!(l.len() < MAX_LINE);
    }

    #[test]
    fn every_reason_has_a_fixed_message_and_none_looks_like_a_key() {
        for code in ["off", "not_allowed", "busy", "rate", "too_long", "empty", "no_key", "unreachable", "auth", "provider", "canceled", "internal", "whatever"] {
            let m = reason(code);
            assert!(!m.is_empty() && !m.contains("sk-") && m.len() < 80, "{code}");
        }
    }
}
