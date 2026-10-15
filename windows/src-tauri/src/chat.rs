// The chat, whoever answers it: the conversation, the system prompt, and which
// provider a turn goes to. Each provider's own wire format lives in its module:
// claude.rs (Anthropic), claude_code.rs (the user's Claude Code CLI),
// openai_compat.rs (OpenAI, Google AI, OpenRouter) and local_chat.rs (Ollama,
// LM Studio, any OpenAI-compatible server).
//
// API keys never leave the credential store and file bytes never cross the IPC
// boundary: the island sends the question and gets the answer's text back.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::AppHandle;

use crate::settings::Settings;
use crate::{claude, claude_code, local_chat, openai_compat, secrets};

pub const ANTHROPIC: &str = "anthropic";

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatContext {
    File { name: String, path: String },
    Window { app_name: String, title: String, url: Option<String> },
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ChatReply {
    pub text: String,
    /// Something to know about how the answer was made (the image was left
    /// out, a picture was uploaded to make a 3D model...), shown above it.
    pub notice: Option<String>,
    /// How the model felt about its answer, for Mochi to act out (take_mood).
    pub mood: Option<String>,
    /// Images, video, speech or 3D a media model made (media.rs).
    pub media: Vec<crate::media::MediaFile>,
}

impl ChatReply {
    pub fn text(text: String) -> Self {
        Self { text, ..Default::default() }
    }
}

/// The error a model's refusal of an image is reported as, so the island can
/// ask whether to send without it instead of failing.
pub const IMAGES_UNSUPPORTED: &str = "IMAGES_UNSUPPORTED";

/// A 4xx to a message that carried an image: the model reads text only. Many
/// do (most of Groq's, many of OpenRouter's free ones) and say so this way.
pub fn refused_image(status: u16, sent_image: bool) -> bool {
    sent_image && matches!(status, 400 | 415 | 422)
}

/// True when an OpenAI-shaped user message carries an image part.
pub fn has_image(user: &Value) -> bool {
    user["content"].as_array().is_some_and(|parts| parts.iter().any(|p| p["type"] == "image_url"))
}

/// A model a provider offers, for the picker in the chat view.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub id: String,
    pub label: String,
}

// ── Conversation ──────────────────────────────────────────────────────────────

/// The conversation is kept twice: in the wire format of the provider that
/// answered last (Claude's carries web search blocks no other provider would
/// understand), and as plain text turns. Switching provider mid-conversation
/// rebuilds the history from the plain turns, so nothing in one provider's
/// format is ever sent to another.
#[derive(Default)]
pub struct Chat {
    inner: Mutex<Conversation>,
    /// The main Mochi's name from Settings, for the system prompt.
    persona: Mutex<String>,
}

#[derive(Default)]
struct Conversation {
    /// Bumped by every reset, so an answer that lands after "New chat" is dropped.
    epoch: u64,
    /// The provider `native` belongs to.
    owner: Option<String>,
    native: Vec<Value>,
    /// `{"role", "content": text}` turns, the same whoever answered.
    plain: Vec<Value>,
}

/// What a provider needs to build one turn.
pub struct Turn {
    epoch: u64,
    provider: String,
    /// No earlier turn: the file or window context rides along with this one.
    pub first: bool,
    /// The earlier turns, in this provider's format.
    pub history: Vec<Value>,
}

impl Chat {
    /// Mochi's instructions, with the name the user gave him.
    pub fn system_prompt(&self, web_search: bool) -> String {
        let name = self.persona.lock().unwrap().clone();
        system_prompt_for(crate::identity::first_name(), web_search, &name)
    }

    pub fn reset(&self) {
        let mut c = self.inner.lock().unwrap();
        let epoch = c.epoch + 1;
        *c = Conversation { epoch, ..Default::default() };
        claude_code::stop();
        crate::media::forget_last_image();
    }

    /// Starts a turn with `provider`, converting the history if another
    /// provider answered the previous turns.
    pub fn begin(&self, provider: &str) -> Turn {
        let mut c = self.inner.lock().unwrap();
        if c.owner.as_deref() != Some(provider) {
            c.native = c.plain.clone();
            c.owner = Some(provider.to_string());
        }
        Turn {
            epoch: c.epoch,
            provider: provider.to_string(),
            first: c.plain.is_empty(),
            history: c.native.clone(),
        }
    }

    /// Records a finished turn: the user message and the answer in the
    /// provider's format, and their plain text. Only a successful turn is
    /// recorded, so the history always matches what the model saw.
    pub fn commit(&self, turn: &Turn, user: Value, assistant: Value, user_text: &str, answer: &str) {
        let mut c = self.inner.lock().unwrap();
        if c.epoch != turn.epoch || c.owner.as_deref() != Some(turn.provider.as_str()) {
            return;
        }
        c.native.push(user);
        c.native.push(assistant);
        c.plain.push(json!({ "role": "user", "content": user_text }));
        c.plain.push(json!({ "role": "assistant", "content": answer }));
    }
}

// ── System prompt ─────────────────────────────────────────────────────────────

/// The moods Mochi can act out (see the end of the system prompt).
const MOODS: [&str; 13] = [
    "happy", "sad", "shy", "angry", "thankful", "welcome", "scared", "celebration", "surprised", "proud",
    "hype", "confused", "sleepy",
];

/// When to pick each mood, for the prompt. Mochi reacts to how the user
/// treats it, not only to the topic: rudeness and insults make it angry.
const MOOD_GUIDE: &str = "happy (a friendly, pleased answer: the default for ordinary replies), \
sad (bad news, a loss, or you couldn't help), \
shy (the user compliments or flirts with you), \
angry (the user insults you, swears at you, uses slurs or is rude or hostile to you, or something unfair or infuriating happened), \
thankful (the user thanks you or does something kind for you), \
welcome (a greeting, hello or goodbye), \
scared (something alarming, dangerous or creepy), \
celebration (something was finished, won or achieved), \
surprised (something unexpected or astonishing), \
proud (you solved something hard or gave a great answer), \
hype (big excitement, a huge win, or the user wants to get pumped up), \
confused (the message is unclear, nonsense or you had to guess), \
sleepy (late at night, or the user says they're tired or bored)";

/// Mochi's instructions. Greets the user by their first name when the account
/// has one worth using (identity.rs), goes by the name given in Settings, and
/// only claims web search where the provider runs it (Claude).
fn system_prompt_for(first_name: Option<&str>, web_search: bool, mochi: &str) -> String {
    let mochi: String = mochi.trim().chars().take(32).collect();
    let mochi = if mochi.is_empty() { "Mochi".to_string() } else { mochi };
    let opening = match first_name {
        Some(name) => format!("You are {mochi}, {name}'s personal AI assistant living at the top of their screen."),
        None => format!("You are {mochi}, a personal AI assistant living at the top of the user's screen."),
    };
    let abilities = if web_search {
        "You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions."
    } else {
        "You can help with absolutely anything — research, coding, recommendations, tasks, questions. You have no web access: say so when something needs current information."
    };
    format!(
        "{opening} {abilities} \
Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
Use light Markdown when it helps: short paragraphs, bullet lists, **bold** on the few key words to notice, `inline code` and fenced code blocks. Small tables are fine; avoid big headings: the chat window is small. \
End every reply with one last line holding only a JSON object with how you feel about it, for your avatar to act out, \
exactly like {{\"mood\":\"happy\"}}. Pick the one that fits best: {MOOD_GUIDE}. Write nothing after that line and never mention it."
    )
}

/// Splits the trailing `{"mood": "..."}` off a reply. Tolerates a code fence
/// around it and stray whitespace; an unknown or missing mood leaves the text
/// as it is.
pub fn take_mood(text: &str) -> (String, Option<String>) {
    let Some(start) = text.rfind('{') else { return (text.to_string(), None) };
    let tail = text[start..].trim().trim_end_matches('`').trim();
    let Ok(value) = serde_json::from_str::<Value>(tail) else { return (text.to_string(), None) };
    let Some(mood) = value.get("mood").and_then(Value::as_str).map(str::to_lowercase) else {
        return (text.to_string(), None);
    };
    if !MOODS.contains(&mood.as_str()) {
        return (text.to_string(), None);
    }
    let body = text[..start].trim_end();
    let body = body.strip_suffix("```json").or_else(|| body.strip_suffix("```")).unwrap_or(body).trim_end();
    (body.to_string(), Some(mood))
}

pub fn is_image(path: &str) -> bool {
    let ext = std::path::Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    matches!(ext.as_str(), "png" | "jpg" | "jpeg" | "gif" | "webp")
}

/// A text or code file's contents and its Markdown language, if it is small
/// enough to show and really text: the island's code card for a dropped file.
pub fn read_text(path: &str) -> Option<(String, String)> {
    if std::fs::metadata(path).ok()?.len() > 200_000 {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    if text.contains('\0') {
        return None;
    }
    let ext = std::path::Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let lang = match ext.as_str() {
        "rs" => "rust",
        "py" => "python",
        "js" | "mjs" | "cjs" => "javascript",
        "ts" | "mts" | "cts" => "typescript",
        "tsx" => "tsx",
        "jsx" => "jsx",
        "ps1" | "psm1" => "powershell",
        "bat" | "cmd" => "batch",
        "sh" | "bash" | "zsh" => "bash",
        "cs" => "csharp",
        "cpp" | "cc" | "cxx" | "hpp" | "hh" => "cpp",
        "h" => "c",
        "kt" | "kts" => "kotlin",
        "rb" => "ruby",
        "yml" => "yaml",
        "md" => "markdown",
        "txt" | "log" => "",
        other => other,
    };
    Some((text, lang.to_string()))
}

/// The window context line, as ClaudeService.chat() writes it.
pub fn window_line(app_name: &str, title: &str, url: Option<&str>) -> String {
    let mut text = format!("Context — App: {app_name}, Window: {title}");
    if let Some(url) = url {
        text.push_str(&format!(", URL: {url}"));
    }
    text
}

/// The plain-text record of what the user asked, context included.
pub fn plain_question(first: bool, context: Option<&ChatContext>, query: &str) -> String {
    match context.filter(|_| first) {
        Some(ChatContext::File { name, .. }) => format!("File: {name}\n\n{query}"),
        Some(ChatContext::Window { app_name, title, url }) => {
            format!("{}\n\n{query}", window_line(app_name, title, url.as_deref()))
        }
        None => query.to_string(),
    }
}

// ── Which provider ────────────────────────────────────────────────────────────

/// The model chosen for `provider`, or its default.
pub fn model_for(settings: &Settings, provider: &str) -> String {
    if provider == ANTHROPIC {
        let m = settings.model.trim();
        return if m.is_empty() { claude::DEFAULT_MODEL.to_string() } else { m.to_string() };
    }
    settings
        .chat_models
        .get(provider)
        .map(|m| m.trim().to_string())
        .filter(|m| !m.is_empty())
        .or_else(|| openai_compat::provider(provider).map(|p| p.default_model.to_string()))
        .or_else(|| (provider == claude_code::PROVIDER).then(|| claude_code::DEFAULT_MODEL.to_string()))
        .unwrap_or_default()
}

/// A file rides along only if it is one of Coucou's own copies of a dropped
/// file (files.rs puts them in the inbox). The page names the path, so without
/// this any file the user can read could be sent to a chat provider.
fn checked_context(context: ChatContext) -> Result<ChatContext, String> {
    match context {
        ChatContext::File { name, path } => {
            let inbox = crate::files::inbox_dir();
            if !is_inside(&inbox, std::path::Path::new(&path)) {
                return Err(crate::i18n::t("Only a file dropped on the island can be sent with a question."));
            }
            Ok(ChatContext::File { name, path })
        }
        other => Ok(other),
    }
}

/// True when `path` is a regular file directly inside `dir`, both resolved
/// (no `..`, no symlink pointing out of it).
pub(crate) fn is_inside(dir: &std::path::Path, path: &std::path::Path) -> bool {
    let (Ok(dir), Ok(file)) = (dir.canonicalize(), path.canonicalize()) else { return false };
    file.parent() == Some(dir.as_path())
        && std::fs::symlink_metadata(&file).map(|m| m.is_file()).unwrap_or(false)
}

/// One chat turn with the provider chosen in the settings. `text_only` sends a
/// dropped picture by name only (the user chose to, for a model that reads no
/// images). The reply's last line, Mochi's mood, is split off here.
pub async fn send(
    app: &AppHandle,
    chat: &Chat,
    settings: &Settings,
    query: String,
    context: Option<ChatContext>,
    text_only: bool,
) -> Result<ChatReply, String> {
    let mut context = context.map(checked_context).transpose()?;
    let provider = settings.chat_provider.as_str();
    if provider == crate::media::PROVIDER {
        return crate::media::chat_turn(app, settings, &query, context).await;
    }
    *chat.persona.lock().unwrap() = settings.mochi_name.clone();
    let mut query = query;
    let mut notice = None;
    if let Some(ChatContext::File { name, path }) = context.as_ref().filter(|_| text_only) {
        if is_image(path) {
            query = format!("[An image ({name}) was attached, but the user chose to send text only.]\n\n{query}");
            notice = Some("Sent without the image.".to_string());
            context = None;
        }
    }
    let model = model_for(settings, provider);
    let reply = if provider == ANTHROPIC || provider.is_empty() {
        // No key, or no credit left on it: Claude Code answers, if it is here.
        match claude::send(chat, &model, query.clone(), context.clone()).await {
            Err(err)
                if (!secrets::present(claude::KEY) || claude_code::out_of_credit(&err))
                    && claude_code::find().is_some() =>
            {
                let model = model_for(settings, claude_code::PROVIDER);
                let reply = claude_code::send(app, chat, &model, query, context).await?;
                let note = crate::i18n::t("Answered by Claude Code: the Claude API key is missing or out of credit.");
                Ok(ChatReply { notice: Some(note), ..reply })
            }
            other => other,
        }
    } else if provider == claude_code::PROVIDER {
        claude_code::send(app, chat, &model, query, context).await
    } else if let Some(p) = openai_compat::provider(provider) {
        openai_compat::send(chat, p, &model, query, context).await
    } else if let Some(server) = local_chat::server(settings, provider) {
        local_chat::send(app, chat, &server, &model, query, context).await
    } else {
        Err(format!("Unknown chat provider: {provider}"))
    }?;
    let (text, mood) = take_mood(&reply.text);
    Ok(ChatReply { text, mood, notice: notice.or(reply.notice), ..reply })
}

/// One turn of the phone's conversation (phone_link/chat_backend.rs): the same providers as
/// [`send`], with no file or window context and no `AppHandle`. `on_delta` gets the streamed
/// text so far, which only the model servers produce; the cloud providers answer all at once.
/// Mochi's mood line (the system prompt asks for one) never reaches the phone.
pub async fn send_for_phone(
    settings: &Settings,
    chat: &Chat,
    provider: &str,
    model: &str,
    query: String,
    mut on_delta: impl FnMut(String),
) -> Result<ChatReply, String> {
    let reply = if provider == ANTHROPIC {
        claude::send(chat, model, query, None).await
    } else if let Some(p) = openai_compat::provider(provider) {
        openai_compat::send(chat, p, model, query, None).await
    } else if let Some(server) = local_chat::server(settings, provider) {
        local_chat::send_with(chat, &server, model, query, None, |so_far| on_delta(hide_mood_tail(&so_far))).await
    } else {
        Err(format!("Unknown chat provider: {provider}"))
    }?;
    let (text, _) = take_mood(&reply.text);
    Ok(ChatReply { text, ..reply })
}

/// Streamed text without the mood line coming in at its end (as views/chat.ts hides it).
fn hide_mood_tail(text: &str) -> String {
    let Some(start) = text.rfind('{').filter(|&i| text[i + 1..].trim_start().starts_with("\"mood")) else {
        return text.to_string();
    };
    let body = text[..start].trim_end();
    body.strip_suffix("```json").or_else(|| body.strip_suffix("```")).unwrap_or(body).trim_end().to_string()
}

/// The models `provider` offers. Asked only when the user opens the picker on
/// that provider, and only once it has a key (or, for a local server, an
/// address): nothing is sent anywhere before that.
pub async fn models(settings: &Settings, provider: &str) -> Result<Vec<ModelInfo>, String> {
    let no_key = || crate::i18n::t("No API key — add it in Settings.");
    if provider == ANTHROPIC {
        let key = secrets::get(claude::KEY).ok_or_else(no_key)?;
        return claude::models(&key).await;
    }
    if provider == claude_code::PROVIDER {
        return claude_code::models();
    }
    if let Some(p) = openai_compat::provider(provider) {
        let key = secrets::get(p.key).ok_or_else(no_key)?;
        return openai_compat::models(p, &key).await;
    }
    if let Some(server) = local_chat::server(settings, provider) {
        return local_chat::models(&server).await;
    }
    Err(format!("Unknown chat provider: {provider}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn_texts(history: &[Value]) -> Vec<(String, Value)> {
        history
            .iter()
            .map(|m| (m["role"].as_str().unwrap().to_string(), m["content"].clone()))
            .collect()
    }

    #[test]
    fn a_turn_is_recorded_only_once_it_succeeds() {
        let chat = Chat::default();
        let t = chat.begin("anthropic");
        assert!(t.first);
        assert!(t.history.is_empty());
        // A failed turn records nothing: the next one is still the first.
        let t = chat.begin("anthropic");
        assert!(t.first);
        chat.commit(&t, json!({"role":"user","content":[{"type":"text","text":"hi"}]}), json!({"role":"assistant","content":[{"type":"text","text":"hello"}]}), "hi", "hello");
        let t = chat.begin("anthropic");
        assert!(!t.first);
        assert_eq!(t.history.len(), 2);
        assert!(t.history[0]["content"].is_array());
    }

    #[test]
    fn switching_provider_never_sends_claude_blocks_to_another_one() {
        let chat = Chat::default();
        let t = chat.begin("anthropic");
        let blocks = json!([
            {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"x"}},
            {"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[]},
            {"type":"text","text":"Found it."}
        ]);
        chat.commit(&t, json!({"role":"user","content":[{"type":"text","text":"look"}]}), json!({"role":"assistant","content":blocks}), "look", "Found it.");

        let t = chat.begin("openai");
        assert!(!t.first);
        assert_eq!(
            turn_texts(&t.history),
            vec![("user".into(), json!("look")), ("assistant".into(), json!("Found it."))]
        );
        let raw = serde_json::to_string(&t.history).unwrap();
        assert!(!raw.contains("web_search"), "{raw}");

        // And back: Claude gets the plain turns too, including OpenAI's answer.
        chat.commit(&t, json!({"role":"user","content":"more"}), json!({"role":"assistant","content":"Sure."}), "more", "Sure.");
        let t = chat.begin("anthropic");
        assert_eq!(t.history.len(), 4);
        assert_eq!(t.history[3], json!({"role":"assistant","content":"Sure."}));
        assert!(!serde_json::to_string(&t.history).unwrap().contains("web_search"));
    }

    #[test]
    fn an_answer_that_lands_after_a_reset_or_a_switch_is_dropped() {
        let chat = Chat::default();
        let t = chat.begin("openai");
        chat.reset();
        chat.commit(&t, json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"}), "q", "a");
        assert!(chat.begin("openai").first);

        let t = chat.begin("openai");
        let _other = chat.begin("google");
        chat.commit(&t, json!({"role":"user","content":"q"}), json!({"role":"assistant","content":"a"}), "q", "a");
        assert!(chat.begin("google").first);
    }

    #[test]
    fn the_prompt_greets_by_first_name_and_claims_web_search_only_for_claude() {
        let p = system_prompt_for(Some("Louis"), true, "");
        assert!(p.starts_with("You are Mochi, Louis's personal AI assistant living at the top of their screen."));
        assert!(p.contains("web search access"));
        assert!(p.contains("light Markdown"));
        let p = system_prompt_for(None, false, "  ");
        assert!(p.starts_with("You are Mochi, a personal AI assistant living at the top of the user's screen."));
        assert!(!p.contains("web search"));
        assert!(p.contains("no web access"));
    }

    #[test]
    fn context_goes_with_the_first_question_only() {
        let file = ChatContext::File { name: "a.txt".into(), path: "/x/a.txt".into() };
        assert_eq!(plain_question(true, Some(&file), "why?"), "File: a.txt\n\nwhy?");
        assert_eq!(plain_question(false, Some(&file), "why?"), "why?");
        let win = ChatContext::Window { app_name: "Code".into(), title: "main.rs".into(), url: None };
        assert_eq!(plain_question(true, Some(&win), "q"), "Context — App: Code, Window: main.rs\n\nq");
        assert_eq!(window_line("Edge", "Docs", Some("https://x.dev")), "Context — App: Edge, Window: Docs, URL: https://x.dev");
    }

    #[test]
    fn the_model_comes_from_the_settings_or_the_provider_default() {
        let mut s = Settings::default();
        assert_eq!(model_for(&s, "anthropic"), claude::DEFAULT_MODEL);
        assert_eq!(model_for(&s, "openai"), openai_compat::provider("openai").unwrap().default_model);
        assert_eq!(model_for(&s, "ollama"), "");
        assert_eq!(model_for(&s, "claude-code"), "claude-haiku-5-5");
        s.chat_models.insert("openai".into(), " gpt-x ".into());
        s.chat_models.insert("ollama".into(), "llama3.2".into());
        s.model = "claude-haiku-4-5".into();
        assert_eq!(model_for(&s, "openai"), "gpt-x");
        assert_eq!(model_for(&s, "ollama"), "llama3.2");
        assert_eq!(model_for(&s, "anthropic"), "claude-haiku-4-5");
    }

    #[test]
    fn only_files_in_the_inbox_ride_along() {
        let base = std::env::temp_dir().join(format!("coucou-chat-ctx-{}", std::process::id()));
        let inbox = base.join("inbox");
        std::fs::create_dir_all(inbox.join("sub")).unwrap();
        std::fs::write(inbox.join("a.txt"), b"a").unwrap();
        std::fs::write(base.join("secret.txt"), b"s").unwrap();
        std::fs::write(inbox.join("sub").join("b.txt"), b"b").unwrap();
        assert!(is_inside(&inbox, &inbox.join("a.txt")));
        assert!(!is_inside(&inbox, &base.join("secret.txt")));
        assert!(!is_inside(&inbox, &inbox.join("..").join("secret.txt")));
        assert!(!is_inside(&inbox, &inbox.join("sub").join("b.txt")));
        assert!(!is_inside(&inbox, &inbox.join("missing.txt")));
        assert!(!is_inside(&inbox, &inbox));
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(base.join("secret.txt"), inbox.join("link.txt")).unwrap();
            assert!(!is_inside(&inbox, &inbox.join("link.txt")));
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn mochi_goes_by_the_name_given_in_settings_and_asks_for_a_mood() {
        let p = system_prompt_for(Some("Louis"), false, "Pebble");
        assert!(p.starts_with("You are Pebble, Louis's personal AI assistant"));
        assert!(p.contains("{\"mood\":\"happy\"}"), "{p}");
        assert!(p.contains("celebration"));
        // An absurdly long name is cut, never sent whole.
        let p = system_prompt_for(None, false, &"x".repeat(100));
        assert!(p.starts_with(&format!("You are {}, a", "x".repeat(32))));
    }

    #[test]
    fn a_trailing_mood_is_split_off_the_answer() {
        assert_eq!(take_mood("Done!\n{\"mood\":\"happy\"}"), ("Done!".into(), Some("happy".into())));
        assert_eq!(
            take_mood("Hi\n\n```json\n{ \"mood\": \"Thankful\" }\n```\n"),
            ("Hi".into(), Some("thankful".into()))
        );
        // Unknown mood, or JSON that is the answer itself: left alone.
        assert_eq!(take_mood("x {\"mood\":\"bored\"}").1, None);
        assert_eq!(take_mood("Use {\"a\": 1} here.").1, None);
        assert_eq!(take_mood("No mood at all").0, "No mood at all");
    }

    #[test]
    fn an_image_refused_with_a_4xx_means_a_text_only_model() {
        assert!(refused_image(400, true) && refused_image(415, true) && refused_image(422, true));
        assert!(!refused_image(400, false));
        assert!(!refused_image(401, true) && !refused_image(500, true));
        assert!(has_image(&json!({"role":"user","content":[{"type":"image_url","image_url":{"url":"data:x"}},{"type":"text","text":"q"}]})));
        assert!(!has_image(&json!({"role":"user","content":"q"})));
    }

    #[test]
    fn a_code_file_is_read_with_its_language() {
        let dir = std::env::temp_dir().join(format!("coucou-read-text-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("main.rs"), "fn main() {}").unwrap();
        std::fs::write(dir.join("blob.bin"), b"a\0b").unwrap();
        assert_eq!(read_text(&dir.join("main.rs").to_string_lossy()), Some(("fn main() {}".into(), "rust".into())));
        assert_eq!(read_text(&dir.join("blob.bin").to_string_lossy()), None);
        assert_eq!(read_text(&dir.join("missing.txt").to_string_lossy()), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
