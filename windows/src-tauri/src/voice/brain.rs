// « OK Coucou »'s brain: Claude with the user's key and Coucou's tools —
// pills, music, the user's own data, opening an app, preparing an email (the
// mail app opens with it filled in; the user sends it) and Anthropic's web
// search. The conversation lives in memory only and is forgotten 90 s after
// the last turn. Port of ClaudeVoiceBrain.swift.

use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};
use super::search::{self, SearchProvider};
use crate::mutex::MutexExt;

const FAST_MODEL: &str = "claude-haiku-4-5";
const FORGET_AFTER: Duration = Duration::from_secs(90);

pub struct Brain {
    messages: Vec<Value>,
    last: Instant,
    search_provider: SearchProvider,
    search_session: String,
}

impl Default for Brain {
    fn default() -> Self {
        Self { messages: Vec::new(), last: Instant::now(), search_provider: SearchProvider::default(), search_session: search_session() }
    }
}

pub struct Reply {
    pub text: String,
    pub acted: bool,
}

fn tools(provider: SearchProvider) -> Vec<Value> {
    let mut tools = vec![
        json!({
            "name": "pills",
            "description": "Add, remove, set as main or list the pills shown in the island at the top of the screen. At most 4 pills besides the main one: remove one first if needed.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "action": { "type": "string", "enum": ["add", "remove", "set_main", "list"] },
                    "names": { "type": "array", "items": { "type": "string" }, "description": "Pill names as listed (e.g. Stripe, GitHub, Cursor). Empty for list." }
                },
                "required": ["action"]
            }
        }),
        json!({
            "name": "music",
            "description": "Control Spotify: play or pause, next, previous, set the volume, or search a song, an artist or a playlist in Spotify.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "action": { "type": "string", "enum": ["play_pause", "next", "previous", "set_volume", "search"] },
                    "query": { "type": "string", "description": "What to search, for search." },
                    "volume": { "type": "integer", "description": "0-100 for set_volume." }
                },
                "required": ["action"]
            }
        }),
        json!({
            "name": "service_info",
            "description": "Read the user's real data that Coucou already has, as JSON: the active pills, the agent sessions (Claude Code, Codex…) and what they are doing, Claude or Codex plan usage, Spotify now playing, and the services' latest data (Stripe, GitHub, Vercel, Resend, n8n, Notion, Cal.com).",
            "input_schema": { "type": "object", "properties": {} }
        }),
        json!({
            "name": "open_app",
            "description": "Open an app on this computer by name (Firefox, VS Code, Notion, Spotify…).",
            "input_schema": { "type": "object", "properties": { "name": { "type": "string" } }, "required": ["name"] }
        }),
        json!({
            "name": "prepare_email",
            "description": "Open the user's mail app with an email filled in, for them to check and send (it is never sent automatically). The recipient must be an email address.",
            "input_schema": {
                "type": "object",
                "properties": {
                    "recipient": { "type": "string", "description": "An email address." },
                    "subject": { "type": "string" },
                    "body": { "type": "string", "description": "The full email text, written for the user." }
                },
                "required": ["recipient", "subject", "body"]
            }
        }),
    ];
    if let Some(tool) = search::tool(provider) { tools.push(tool); }
    tools
}

fn system_prompt(pills: &str) -> String {
    let t = crate::platform::local_time();
    let os = if cfg!(windows) { "Windows" } else { "Linux" };
    format!(
        "You are Coucou, a voice assistant living at the top of the screen of the user's {os} computer, a bit like Jarvis: \
quick, warm, a little playful. It is {:04}-{:02}-{:02} {:02}:{:02}.\n\
Everything you write is read aloud: answer in the language the user spoke, in one or two short sentences, \
no markdown, no lists, no emojis, no links.\n\
Act with the tools instead of describing: pills, music, service_info for the user's own data, open_app, \
prepare_email, and web_search for anything current (weather, news, scores, prices, facts you are not sure of). \
Never invent the user's data.\n\
Email: gather the recipient's address, the subject and what to say (write the text yourself from what the user \
wants to say, in the language they used), asking for what is missing one short question at a time, then call \
prepare_email. The email is never sent by you: the user checks it in their mail app and sends it.\n\
When you need an answer from the user, end with one short question. Otherwise never end with a question.\n\
Pills: {pills}",
        t.year, t.month, t.day, t.hour, t.minute
    )
}

impl Brain {
    pub fn respond(&mut self, app: &AppHandle, transcript: &str) -> Option<Reply> {
        let (enabled, provider) = search_config(app);
        if !enabled { return None; }
        if self.last.elapsed() > FORGET_AFTER || provider != self.search_provider {
            self.messages.clear();
            self.search_session = search_session();
        }
        self.search_provider = provider;
        self.last = Instant::now();
        self.messages.push(json!({ "role": "user", "content": transcript }));
        self.trim();
        let pills = super::ask_island(app, "pills", json!({ "action": "list" })).unwrap_or_default();
        let mut system = system_prompt(&pills);
        if provider == SearchProvider::Off {
            system.push_str("\nWeb search is disabled. Do not claim web access or invent current information.");
        }
        let tools = tools(provider);
        let chat_model = app
            .try_state::<crate::Shared>()
            .map(|s| s.settings.lock_recover().model.clone())
            .unwrap_or_default();
        let mut acted = false;
        let mut spoken = String::new();
        let mut searches = 0;
        let mut search_failed = false;
        for _ in 0..5 {
            if search_config(app) != (true, provider) { self.messages.clear(); return None; }
            let turn = tauri::async_runtime::block_on(async {
                match crate::claude::voice_turn(FAST_MODEL, &system, &self.messages, &tools).await {
                    Ok(v) => Ok(v),
                    Err(err) if !chat_model.is_empty() => {
                        crate::log::line(format!("voice: {err}; the chat's model instead"));
                        crate::claude::voice_turn(&chat_model, &system, &self.messages, &tools).await
                    }
                    Err(err) => Err(err),
                }
            });
            let turn = match turn {
                Ok(t) => t,
                Err(err) => {
                    crate::log::line(format!("voice: Claude turn failed: {err}"));
                    if self.messages.last().is_some_and(|m| m["content"].is_string()) {
                        self.messages.pop();
                    }
                    return acted.then(|| Reply { text: String::new(), acted });
                }
            };
            let content = turn["content"].as_array().cloned().unwrap_or_default();
            self.messages.push(json!({ "role": "assistant", "content": content.clone() }));
            let text: String = content.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect::<Vec<_>>().join(" ");
            if !text.trim().is_empty() {
                spoken = text;
            }
            let stop = turn["stop_reason"].as_str().unwrap_or("end_turn");
            if stop == "pause_turn" {
                continue;
            }
            let uses: Vec<&Value> = content.iter().filter(|b| b["type"] == "tool_use").collect();
            if stop != "tool_use" || uses.is_empty() {
                break;
            }
            let mut results = Vec::new();
            for u in uses {
                let name = u["name"].as_str().unwrap_or("");
                let (result, did) = if name == "web_search" {
                    searches += 1;
                    if provider != SearchProvider::Parallel || searches > 3 || search_failed || search_config(app) != (true, provider) {
                        ("Web search is unavailable or its per-turn limit was reached. Do not retry.".into(), false)
                    } else {
                        let result = tauri::async_runtime::block_on(async {
                            let request = tokio::time::timeout(Duration::from_secs(20), search::parallel(&u["input"], &self.search_session));
                            tokio::pin!(request);
                            loop {
                                tokio::select! {
                                    result = &mut request => break result.unwrap_or_else(|_| Err("Parallel search timed out.".into())),
                                    _ = tokio::time::sleep(Duration::from_millis(100)) => {
                                        if search_config(app) != (true, provider) {
                                            break Err("Voice search was disabled or its provider changed.".into());
                                        }
                                    }
                                }
                            }
                        });
                        search_failed = result.is_err();
                        (result.unwrap_or_else(|e| format!("Search error: {e}")), false)
                    }
                } else {
                    super::run_tool(app, name, &u["input"])
                };
                acted |= did;
                results.push(json!({ "type": "tool_result", "tool_use_id": u["id"], "content": result }));
            }
            self.messages.push(json!({ "role": "user", "content": results }));
            spoken.clear();
        }
        self.repair();
        Some(Reply { text: spoken_text(&spoken), acted })
    }

    /// Keeps the last exchanges, never cutting between a tool call and its result.
    fn trim(&mut self) {
        if self.messages.len() <= 24 {
            return;
        }
        let mut cut = self.messages.len() - 24;
        while cut < self.messages.len() && !(self.messages[cut]["role"] == "user" && self.messages[cut]["content"].is_string()) {
            cut += 1;
        }
        self.messages.drain(..cut.min(self.messages.len() - 1));
    }

    /// The API refuses a history ending on a tool call with no result after it.
    fn repair(&mut self) {
        let Some(last) = self.messages.last() else { return };
        if last["role"] != "assistant" {
            return;
        }
        let calls = last["content"].as_array().is_some_and(|c| c.iter().any(|b| b["type"] == "tool_use"));
        if calls {
            self.messages.pop();
        }
    }
}

fn search_session() -> String {
    use std::hash::{BuildHasher, Hasher};
    // RandomState seeds each hasher from the OS. No user/device identifier, and
    // no extra dependency for this anonymous conversation correlation value.
    let a = std::collections::hash_map::RandomState::new().build_hasher().finish();
    let b = std::collections::hash_map::RandomState::new().build_hasher().finish();
    format!("{a:016x}{b:016x}")
}

fn search_config(app: &AppHandle) -> (bool, SearchProvider) {
    crate::flow::get(app).map(|f| {
        let store = f.store.lock_recover();
        (store.prefs.voice, store.prefs.voice_search)
    }).unwrap_or((false, SearchProvider::Off))
}

/// What Claude wrote, ready to be said: citations and markdown left out.
pub fn spoken_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut skip = 0;
    for c in text.chars() {
        match c {
            '[' => skip += 1,
            ']' if skip > 0 => skip -= 1,
            '*' | '#' | '`' | '_' if skip == 0 => {}
            _ if skip == 0 => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_and_citations_are_not_read_aloud() {
        assert_eq!(spoken_text("**Done** — Stripe [1] is in the island."), "Done — Stripe is in the island.");
        assert_eq!(spoken_text("  Il fait  20 °C à Bordeaux. "), "Il fait 20 °C à Bordeaux.");
    }

    #[test]
    fn every_tool_has_a_schema() {
        for tool in tools(SearchProvider::Anthropic) {
            assert!(tool["name"].is_string());
            assert!(tool.get("input_schema").is_some() || tool["type"] == "web_search_20250305");
        }
    }

    #[test]
    fn one_search_tool_for_each_provider_and_none_when_off() {
        let parallel = tools(SearchProvider::Parallel);
        let search: Vec<_> = parallel.iter().filter(|t| t["name"] == "web_search").collect();
        assert_eq!(search.len(), 1);
        assert!(search[0]["input_schema"].is_object());
        assert!(!tools(SearchProvider::Off).iter().any(|t| t["name"] == "web_search"));
        assert_eq!(SearchProvider::default(), SearchProvider::Anthropic);
    }
}
