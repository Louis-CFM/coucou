// « OK Coucou »'s brain: Claude with the user's key and Coucou's tools —
// pills, music, the user's own data, opening an app, preparing an email (the
// mail app opens with it filled in; the user sends it) and Anthropic's web
// search. The conversation lives in memory only and is forgotten 90 s after
// the last turn. Port of ClaudeVoiceBrain.swift.
//
// Without a Claude key, Gemini answers with the Google AI key instead: the same
// tools as function declarations, and the web through a second Gemini call that
// searches Google (the two kinds of tools don't mix in one request).

use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

const FAST_MODEL: &str = "claude-haiku-4-5";
const GEMINI_MODEL: &str = "gemini-2.5-flash";
const GOOGLE_KEY: &str = "google-api-key";
const FORGET_AFTER: Duration = Duration::from_secs(90);

pub struct Brain {
    messages: Vec<Value>,
    /// Gemini's side of the conversation, in its own shape.
    contents: Vec<Value>,
    last: Instant,
}

impl Default for Brain {
    fn default() -> Self {
        Self { messages: Vec::new(), contents: Vec::new(), last: Instant::now() }
    }
}

/// Who answers « OK Coucou »: Claude with its key, else Gemini with the Google AI key.
pub fn available() -> Option<&'static str> {
    if crate::secrets::present(crate::claude::KEY) {
        Some("claude")
    } else if crate::secrets::present(GOOGLE_KEY) {
        Some("gemini")
    } else {
        None
    }
}

/// Claude's tools as Gemini function declarations, with the web as one of them.
fn gemini_tools() -> Value {
    let mut decls: Vec<Value> = tools()
        .into_iter()
        .filter_map(|t| {
            let schema = t.get("input_schema")?;
            let mut decl = json!({ "name": t["name"], "description": t["description"] });
            // Gemini refuses an object with no properties: such a tool takes none.
            if schema["properties"].as_object().is_some_and(|p| !p.is_empty()) {
                decl["parameters"] = schema.clone();
            }
            Some(decl)
        })
        .collect();
    decls.push(json!({
        "name": "web_search",
        "description": "Search the web with Google for anything current: weather, news, scores, prices, facts you are not sure of.",
        "parameters": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }
    }));
    json!([{ "functionDeclarations": decls }])
}

pub struct Reply {
    pub text: String,
    pub acted: bool,
}

fn tools() -> Vec<Value> {
    vec![
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
        json!({ "type": "web_search_20250305", "name": "web_search", "max_uses": 3 }),
    ]
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
        if self.last.elapsed() > FORGET_AFTER {
            self.messages.clear();
            self.contents.clear();
        }
        self.last = Instant::now();
        if available() == Some("gemini") {
            return self.respond_gemini(app, transcript);
        }
        self.messages.push(json!({ "role": "user", "content": transcript }));
        self.trim();
        let pills = super::ask_island(app, "pills", json!({ "action": "list" })).unwrap_or_default();
        let system = system_prompt(&pills);
        let tools = tools();
        let chat_model = app
            .try_state::<crate::Shared>()
            .map(|s| s.settings.lock().unwrap().model.clone())
            .unwrap_or_default();
        let mut acted = false;
        let mut spoken = String::new();
        for _ in 0..5 {
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
                let (result, did) = super::run_tool(app, u["name"].as_str().unwrap_or(""), &u["input"]);
                acted |= did;
                results.push(json!({ "type": "tool_result", "tool_use_id": u["id"], "content": result }));
            }
            self.messages.push(json!({ "role": "user", "content": results }));
            spoken.clear();
        }
        self.repair();
        Some(Reply { text: spoken_text(&spoken), acted })
    }

    /// The same turn with Gemini: function calls run as Claude's tools do.
    fn respond_gemini(&mut self, app: &AppHandle, transcript: &str) -> Option<Reply> {
        let key = crate::secrets::get(GOOGLE_KEY)?;
        let google = crate::openai_compat::provider("google")?;
        self.contents.push(json!({ "role": "user", "parts": [{ "text": transcript }] }));
        if self.contents.len() > 24 {
            let mut cut = self.contents.len() - 24;
            while cut < self.contents.len() - 1 && self.contents[cut]["parts"][0]["text"].is_null() {
                cut += 1;
            }
            self.contents.drain(..cut);
        }
        let pills = super::ask_island(app, "pills", json!({ "action": "list" })).unwrap_or_default();
        let system = system_prompt(&pills);
        let Ok(endpoint) = reqwest::Url::parse(&format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
        )) else {
            return None;
        };
        let mut acted = false;
        let mut spoken = String::new();
        for _ in 0..5 {
            let body = json!({
                "systemInstruction": { "parts": [{ "text": system }] },
                "contents": self.contents,
                "tools": gemini_tools(),
                "generationConfig": { "maxOutputTokens": 1024 },
            });
            let turn = tauri::async_runtime::block_on(crate::openai_compat::post_json(
                google,
                &endpoint,
                crate::openai_compat::Auth::GoogApiKey(&key),
                &body,
            ));
            let turn = match turn {
                Ok(t) => t,
                Err(err) => {
                    crate::log::line(format!("voice: Gemini turn failed: {err}"));
                    if self.contents.last().is_some_and(|c| c["role"] == "user" && c["parts"][0]["text"].is_string()) {
                        self.contents.pop();
                    }
                    return acted.then(|| Reply { text: String::new(), acted });
                }
            };
            let parts = turn.pointer("/candidates/0/content/parts").and_then(Value::as_array).cloned().unwrap_or_default();
            // Gemini's own parts go back as they came (its thought signatures with them).
            self.contents.push(json!({ "role": "model", "parts": parts }));
            let text = parts
                .iter()
                .filter(|p| p["thought"] != true)
                .filter_map(|p| p["text"].as_str())
                .collect::<Vec<_>>()
                .join(" ");
            if !text.trim().is_empty() {
                spoken = text;
            }
            let calls: Vec<&Value> = parts.iter().filter_map(|p| p.get("functionCall")).collect();
            if calls.is_empty() {
                break;
            }
            let mut responses = Vec::new();
            for call in calls {
                let name = call["name"].as_str().unwrap_or("");
                let args = call.get("args").cloned().unwrap_or_else(|| json!({}));
                let result = if name == "web_search" {
                    let query = json!({ "role": "user", "content": args["query"].as_str().unwrap_or("") });
                    tauri::async_runtime::block_on(crate::gemini::reply(google, GEMINI_MODEL, &key, &[], &query))
                        .unwrap_or_else(|err| err)
                } else {
                    let (result, did) = super::run_tool(app, name, &args);
                    acted |= did;
                    result
                };
                responses.push(json!({ "functionResponse": { "name": name, "response": { "content": result } } }));
            }
            self.contents.push(json!({ "role": "user", "parts": responses }));
            spoken.clear();
        }
        // Never a history ending on a call with no answer after it.
        if self.contents.last().is_some_and(|c| {
            c["role"] == "model" && c["parts"].as_array().is_some_and(|p| p.iter().any(|p| p.get("functionCall").is_some()))
        }) {
            self.contents.pop();
        }
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
    fn gemini_gets_every_tool_and_the_web() {
        let decls = gemini_tools()[0]["functionDeclarations"].as_array().unwrap().clone();
        let names: Vec<&str> = decls.iter().filter_map(|d| d["name"].as_str()).collect();
        assert_eq!(names, ["pills", "music", "service_info", "open_app", "prepare_email", "web_search"]);
        // No object without properties: Gemini refuses those.
        for d in &decls {
            if let Some(p) = d.get("parameters") {
                assert!(!p["properties"].as_object().unwrap().is_empty(), "{d}");
            }
        }
    }

    #[test]
    fn every_tool_has_a_schema() {
        for tool in tools() {
            assert!(tool["name"].is_string());
            assert!(tool.get("input_schema").is_some() || tool["type"] == "web_search_20250305");
        }
    }
}
