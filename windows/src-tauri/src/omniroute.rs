// OmniRoute (https://omniroute.online), the model router the user runs on
// their computer: one address in front of every provider and account they
// connected to it. Coucou talks to it two ways, both off until the user turns
// them on in Settings → Chat:
//
// - as a chat provider, through the OpenAI-compatible client of the model
//   servers (local_chat.rs): its models and combos show in the island's picker;
// - for Coucou's own AI features — dictation clean-up, Notetaker summaries and
//   « OK Coucou » — which otherwise ask Anthropic: their requests go to its
//   Anthropic-compatible /v1/messages, with the model picked for them.
//
// Its API key lives in the credential store, bound to the address it was
// entered for (as the custom server's is), and only ever goes there: this
// computer, or https. Coucou never installs OmniRoute; Settings says where to
// get it, and once it is installed Coucou starts it with its own launcher.
//
// The rest of the app only calls into this module, one line at each place.

use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::Duration;

use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager, State};

use crate::i18n::{t, tf};
use crate::local_chat::Server;
use crate::settings::Settings;
use crate::{net, secrets, Shared};

/// Its id among the chat providers.
pub const PROVIDER: &str = "omniroute";
/// Credential store entry of its API key.
pub const KEY: &str = "omniroute-api-key";
/// Where `omniroute` serves by default.
pub const DEFAULT_URL: &str = "http://127.0.0.1:20128";
const NAME: &str = "OmniRoute";
const ANTHROPIC_VERSION: &str = "2023-06-01";
/// A server started by Coucou has this long to answer: a cold start with a
/// large database took over a minute here.
const START_TIMEOUT: Duration = Duration::from_secs(180);

/// Settings → Chat → OmniRoute. Stored with the other preferences; the key is not.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Config {
    /// OmniRoute shows in the chat's picker, and Coucou starts it at launch.
    pub enabled: bool,
    /// Its address; empty for the usual one on this computer.
    pub url: String,
    /// Dictation clean-up, Notetaker summaries and « OK Coucou » go through it.
    pub features: bool,
    /// The model those features ask for; empty until picked.
    pub features_model: String,
    /// The chat's provider before OmniRoute took it: given back when it is
    /// turned off. Empty when the chat never went to it.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub chat_before: String,
}

static APP: OnceLock<AppHandle> = OnceLock::new();

/// At launch: remembered for the feature hooks, which have no `AppHandle`, and
/// OmniRoute started if it is on, on this computer and not running yet.
pub fn setup(app: &AppHandle) {
    let _ = APP.set(app.clone());
    let Some(config) = config() else { return };
    if !config.enabled {
        return;
    }
    tauri::async_runtime::spawn(async move {
        let Ok(url) = base(&config) else { return };
        if net::is_loopback_url(&url) && !running(&url).await && launcher().is_some() {
            if let Err(err) = start_at(&url).await {
                crate::log::line(format!("omniroute: not started at launch: {err}"));
            }
        }
    });
}

fn config() -> Option<Config> {
    let shared = APP.get()?.try_state::<Shared>()?;
    let config = shared.settings.lock().unwrap().omniroute.clone();
    Some(config)
}

/// Its address, cleaned up as the model servers' are.
fn base(config: &Config) -> Result<Url, String> {
    let raw = if config.url.trim().is_empty() { DEFAULT_URL } else { config.url.as_str() };
    net::normalise_server_url(raw)
}

// ── The key ───────────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize)]
struct BoundKey {
    url: String,
    key: String,
}

fn may_carry_key(url: &Url) -> bool {
    url.scheme() == "https" || net::is_loopback_url(url)
}

fn bound_url(url: &Url) -> String {
    url.as_str().trim_end_matches('/').to_string()
}

/// The key, if it was entered for exactly this address.
fn key_for(url: &Url) -> Option<String> {
    key_from(&secrets::get(KEY)?, url)
}

fn key_from(stored: &str, url: &Url) -> Option<String> {
    let bound: BoundKey = serde_json::from_str(stored).ok()?;
    (may_carry_key(url) && bound.url == bound_url(url) && !bound.key.is_empty()).then_some(bound.key)
}

/// Stores `key` for the address typed next to it; an empty key removes it.
fn set_key(typed_url: &str, key: &str) -> Result<(), String> {
    let key = key.trim();
    if key.is_empty() {
        return secrets::clear(KEY);
    }
    let raw = if typed_url.trim().is_empty() { DEFAULT_URL } else { typed_url };
    let url = net::normalise_server_url(raw)?;
    if !may_carry_key(&url) {
        return Err(t("A key is only sent over https, or to a server on this computer."));
    }
    let value = serde_json::to_string(&BoundKey { url: bound_url(&url), key: key.to_string() }).map_err(|e| e.to_string())?;
    secrets::set(KEY, &value)
}

// ── As a chat provider ────────────────────────────────────────────────────────

/// The chat's view of it (local_chat.rs). Turned off, it has no address, and
/// the chat says to connect it first.
pub fn server(settings: &Settings) -> Server {
    let config = &settings.omniroute;
    let url = base(config).ok().filter(|_| config.enabled);
    Server {
        id: PROVIDER,
        name: NAME,
        url: url.as_ref().map(bound_url).unwrap_or_default(),
        key: url.as_ref().and_then(key_for),
    }
}

// ── For Coucou's own features ─────────────────────────────────────────────────

fn routing() -> Option<Config> {
    config().filter(|c| c.enabled && c.features)
}

/// Whether the features that need Claude can run through OmniRoute instead.
pub fn serves_features() -> bool {
    routing().is_some()
}

/// claude::complete through OmniRoute, when the features go there.
pub async fn complete(system: &str, user: &str, max_tokens: u32, timeout: Duration) -> Option<Result<String, String>> {
    let config = routing()?;
    let body = json!({
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{ "role": "user", "content": user }],
    });
    Some(messages(&config, body, timeout).await.and_then(|response| {
        let blocks = response.get("content").and_then(Value::as_array).cloned().unwrap_or_default();
        crate::claude::response_text(&blocks).ok_or_else(|| t("No response text."))
    }))
}

/// claude::voice_turn through OmniRoute, when the features go there.
pub async fn voice_turn(system: &str, turns: &[Value], tools: &[Value]) -> Option<Result<Value, String>> {
    let config = routing()?;
    let body = json!({
        "max_tokens": 1024,
        "system": system,
        "messages": turns,
        "tools": tools,
    });
    Some(messages(&config, body, Duration::from_secs(45)).await)
}

/// One request to its Messages endpoint with the features' model.
async fn messages(config: &Config, mut body: Value, timeout: Duration) -> Result<Value, String> {
    let model = config.features_model.trim();
    if model.is_empty() {
        return Err(t("Pick the model for Coucou's features in Settings → Chat → OmniRoute."));
    }
    body["model"] = json!(model);
    let base = base(config)?;
    post_messages(&base, key_for(&base).as_deref(), &body, timeout).await
}

async fn post_messages(base: &Url, key: Option<&str>, body: &Value, timeout: Duration) -> Result<Value, String> {
    let mut request = net::client(base, timeout)?
        .post(net::join(base, "v1/messages"))
        .header("anthropic-version", ANTHROPIC_VERSION)
        .json(body);
    if let Some(key) = key {
        request = request.bearer_auth(key).header("x-api-key", key);
    }
    let response = request.send().await.map_err(|_| unreachable(base))?;
    let status = response.status();
    if matches!(status.as_u16(), 401 | 403) {
        return Err(refused());
    }
    if !status.is_success() {
        let body = net::read_capped(response, net::MAX_ERROR_BODY).await.unwrap_or_default();
        return Err(format!("OmniRoute {status}: {}", net::error_detail(&body)));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await?;
    serde_json::from_slice(&bytes).map_err(|e| tf("Bad API response: {error}", &[("error", &e.to_string())]))
}

fn unreachable(base: &Url) -> String {
    tf("Cannot reach {url}. Is the server running?", &[("url", &bound_url(base))])
}

fn refused() -> String {
    t("OmniRoute wants a valid API key: check it in Settings → Chat → OmniRoute.")
}

// ── Status ────────────────────────────────────────────────────────────────────

/// What Settings shows about it, from scratch each time it asks.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// The address as it is used.
    pub url: String,
    /// On this computer: Coucou can find and start it.
    pub local: bool,
    /// Its launcher (and Node.js) were found on this computer.
    pub installed: bool,
    pub running: bool,
    /// "none" (no key needed), "ok", "missing" (it asks for one) or "refused".
    pub key: &'static str,
    /// Its models and combos, once it lets Coucou in.
    pub models: Vec<String>,
    /// What went wrong, in words, when something did.
    pub error: Option<String>,
}

async fn status_of(config: &Config) -> Status {
    let mut status = Status {
        url: String::new(),
        local: false,
        installed: false,
        running: false,
        key: "none",
        models: Vec::new(),
        error: None,
    };
    let url = match base(config) {
        Ok(url) => url,
        Err(err) => {
            status.error = Some(err);
            return status;
        }
    };
    status.url = bound_url(&url);
    status.local = net::is_loopback_url(&url);
    status.installed = status.local && launcher().is_some();
    status.running = running(&url).await;
    if !status.running {
        return status;
    }
    let key = key_for(&url);
    match list_models(&url, key.as_deref()).await {
        Ok(models) => {
            status.key = if key.is_some() { "ok" } else { "none" };
            status.models = models;
        }
        Err(Listing::Refused) => status.key = if key.is_some() { "refused" } else { "missing" },
        Err(Listing::Failed(err)) => status.error = Some(err),
    }
    status
}

/// Answers at all: its health route, or any HTTP answer from the API (an older
/// build, or OmniRoute behind a proxy that hides the route).
async fn running(base: &Url) -> bool {
    let Ok(client) = net::client(base, Duration::from_secs(3)) else { return false };
    if let Ok(response) = client.get(net::join(base, "api/health")).send().await {
        if response.status().is_success() {
            return true;
        }
    }
    client.get(net::join(base, "v1/models")).send().await.is_ok()
}

enum Listing {
    Refused,
    Failed(String),
}

async fn list_models(base: &Url, key: Option<&str>) -> Result<Vec<String>, Listing> {
    let mut request = net::client(base, Duration::from_secs(10)).map_err(Listing::Failed)?.get(net::join(base, "v1/models"));
    if let Some(key) = key {
        request = request.bearer_auth(key);
    }
    let response = request.send().await.map_err(|_| Listing::Failed(unreachable(base)))?;
    if matches!(response.status().as_u16(), 401 | 403) {
        return Err(Listing::Refused);
    }
    if !response.status().is_success() {
        return Err(Listing::Failed(format!("OmniRoute {}", response.status())));
    }
    let bytes = net::read_capped(response, net::MAX_BODY).await.map_err(Listing::Failed)?;
    let body: Value = serde_json::from_slice(&bytes).map_err(|_| Listing::Failed(t("Unexpected API response.")))?;
    Ok(parse_models(&body))
}

fn parse_models(body: &Value) -> Vec<String> {
    body.get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .map(str::to_string)
        .collect()
}

// ── Starting it ───────────────────────────────────────────────────────────────

/// Node.js and OmniRoute's own entry script, as npm installed them.
struct Launcher {
    node: PathBuf,
    script: PathBuf,
}

/// Found through the `omniroute` command npm put on the PATH, whatever its
/// prefix; npm's default folder on Windows otherwise. None if either is missing.
fn launcher() -> Option<Launcher> {
    let dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    let script = dirs.iter().find_map(|dir| script_in(dir)).or_else(default_script)?;
    let node_name = if cfg!(windows) { "node.exe" } else { "node" };
    let node = dirs
        .iter()
        .map(|dir| dir.join(node_name))
        .find(|p| p.is_file())
        .or_else(default_node)?;
    Some(Launcher { node, script })
}

/// The entry script behind the `omniroute` command of one PATH folder.
fn script_in(dir: &std::path::Path) -> Option<PathBuf> {
    if cfg!(windows) {
        // npm's shim (omniroute.cmd) sits next to the package's folder.
        let script = dir.join("node_modules").join("omniroute").join("bin").join("omniroute.mjs");
        (dir.join("omniroute.cmd").is_file() && script.is_file()).then_some(script)
    } else {
        // npm links bin/omniroute to the package's script.
        let script = dir.join("omniroute").canonicalize().ok()?;
        (script.extension().is_some_and(|e| e == "mjs") && script.is_file()).then_some(script)
    }
}

fn default_script() -> Option<PathBuf> {
    let appdata = std::env::var_os("APPDATA")?;
    let script = PathBuf::from(appdata).join("npm").join("node_modules").join("omniroute").join("bin").join("omniroute.mjs");
    script.is_file().then_some(script)
}

fn default_node() -> Option<PathBuf> {
    let program_files = std::env::var_os("ProgramFiles")?;
    let node = PathBuf::from(program_files).join("nodejs").join("node.exe");
    node.is_file().then_some(node)
}

/// Held while Coucou starts it: whoever asks meanwhile (launch, Settings, the
/// chat) waits for that start instead of launching a second one.
static STARTING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Before the chat or its picker asks OmniRoute: if it is on this computer and
/// not answering — still starting after the computer started, or stopped since —
/// waits for it, starting it if no one is. The picker shows "Loading…" meanwhile.
pub async fn wake(server: &Server) -> Result<(), String> {
    if server.id != PROVIDER {
        return Ok(());
    }
    let Ok(url) = net::normalise_server_url(&server.url) else { return Ok(()) };
    if !net::is_loopback_url(&url) || running(&url).await || launcher().is_none() {
        return Ok(());
    }
    start_at(&url).await
}

/// Starts it in the background, as `omniroute serve --daemon` does, on the
/// port of its address; returns once it answers.
async fn start_at(url: &Url) -> Result<(), String> {
    if !net::is_loopback_url(url) {
        return Err(t("This OmniRoute runs on another computer: start it there."));
    }
    let _starting = STARTING.lock().await;
    if running(url).await {
        return Ok(());
    }
    let launcher = launcher().ok_or_else(|| t("OmniRoute isn't installed on this computer."))?;
    let port = url.port_or_known_default().unwrap_or(20128).to_string();
    let mut command = std::process::Command::new(&launcher.node);
    // Its daemon starts the server as plain `node`: the one found here comes first.
    if let Some(dir) = launcher.node.parent() {
        let rest = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect::<Vec<_>>()).unwrap_or_default();
        if let Ok(path) = std::env::join_paths(std::iter::once(dir.to_path_buf()).chain(rest)) {
            command.env("PATH", path);
        }
    }
    command
        .arg(&launcher.script)
        .args(["serve", "--daemon", "--no-open", "--port", &port])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let mut child = crate::platform::no_console(&mut command).spawn().map_err(|e| e.to_string())?;
    crate::log::line(format!("omniroute: starting on port {port}"));
    // It hands the server to a daemon and exits.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    let started = std::time::Instant::now();
    while started.elapsed() < START_TIMEOUT {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if running(url).await {
            return Ok(());
        }
    }
    Err(t("OmniRoute didn't start. Run omniroute in a terminal once to see why."))
}

// ── Commands ──────────────────────────────────────────────────────────────────

fn current(shared: &State<Shared>) -> Config {
    shared.settings.lock().unwrap().omniroute.clone()
}

#[tauri::command]
pub async fn omniroute_status(shared: State<'_, Shared>) -> Result<Status, String> {
    Ok(status_of(&current(&shared)).await)
}

#[tauri::command]
pub async fn omniroute_start(shared: State<'_, Shared>) -> Result<Status, String> {
    let config = current(&shared);
    start_at(&base(&config)?).await?;
    Ok(status_of(&config).await)
}

/// Settings → OmniRoute → API key, for the address typed next to it.
#[tauri::command]
pub fn omniroute_set_key(url: String, key: String) -> Result<(), String> {
    set_key(&url, &key)
}

/// Whether a key is saved for the address in use — what the key row shows,
/// at once, without asking OmniRoute anything.
#[tauri::command]
pub fn omniroute_key_saved(shared: State<'_, Shared>) -> bool {
    base(&current(&shared)).ok().and_then(|url| key_for(&url)).is_some()
}

/// Its dashboard, where its providers, combos and keys are managed.
#[tauri::command]
pub fn omniroute_dashboard(shared: State<'_, Shared>) -> Result<(), String> {
    let url = base(&current(&shared))?;
    crate::platform::open_url(&net::join(&url, "dashboard"));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::tests::serve_once;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    fn url(s: &str) -> Url {
        net::normalise_server_url(s).unwrap()
    }

    #[test]
    fn an_empty_address_is_the_usual_one_and_a_pasted_one_is_cleaned() {
        assert_eq!(bound_url(&base(&Config::default()).unwrap()), "http://127.0.0.1:20128");
        let typed = Config { url: "localhost:20129/v1/".into(), ..Default::default() };
        assert_eq!(bound_url(&base(&typed).unwrap()), "http://127.0.0.1:20129");
    }

    #[test]
    fn the_key_only_goes_to_the_address_it_was_entered_for() {
        let stored = r#"{"url":"http://127.0.0.1:20128","key":"sk-or"}"#;
        assert_eq!(key_from(stored, &url("http://localhost:20128")).as_deref(), Some("sk-or"));
        assert_eq!(key_from(stored, &url("http://127.0.0.1:9999")), None);
        // Never over plain http to another machine, even if it was entered for it.
        let remote = r#"{"url":"http://10.0.0.2:20128","key":"sk-or"}"#;
        assert_eq!(key_from(remote, &url("http://10.0.0.2:20128")), None);
        let https = r#"{"url":"https://router.example.com","key":"sk-or"}"#;
        assert_eq!(key_from(https, &url("https://router.example.com")).as_deref(), Some("sk-or"));
        assert_eq!(key_from("not json", &url("http://127.0.0.1:20128")), None);
    }

    #[test]
    fn turned_off_it_has_no_address_and_turned_on_the_usual_one() {
        let mut settings = Settings::default();
        assert_eq!(server(&settings).url, "");
        settings.omniroute.enabled = true;
        let s = server(&settings);
        assert_eq!((s.id, s.name, s.url.as_str()), ("omniroute", "OmniRoute", "http://127.0.0.1:20128"));
    }

    #[test]
    fn the_model_list_is_read_and_a_refusal_is_told_apart() {
        let body = br#"{"object":"list","data":[{"id":"cc/claude-sonnet-4-5"},{"id":"my-combo"}]}"#;
        let u = serve_once("200 OK", &format!("Content-Length: {}\r\n", body.len()), body.to_vec());
        assert_eq!(block_on(list_models(&url(&u), Some("k"))).ok().unwrap(), vec!["cc/claude-sonnet-4-5", "my-combo"]);
        let u = serve_once("401 Unauthorized", "Content-Length: 2\r\n", b"{}".to_vec());
        assert!(matches!(block_on(list_models(&url(&u), None)), Err(Listing::Refused)));
        assert!(matches!(block_on(list_models(&url("http://127.0.0.1:1"), None)), Err(Listing::Failed(_))));
    }

    #[test]
    fn a_messages_answer_comes_back_whole_and_errors_say_what_happened() {
        let body = br#"{"content":[{"type":"text","text":"Hello"}],"stop_reason":"end_turn"}"#;
        let u = serve_once("200 OK", &format!("Content-Length: {}\r\n", body.len()), body.to_vec());
        let reply = block_on(post_messages(&url(&u), Some("k"), &json!({}), Duration::from_secs(5))).unwrap();
        assert_eq!(reply["stop_reason"], "end_turn");

        for status in ["401 Unauthorized", "403 Forbidden"] {
            let u = serve_once(status, "Content-Length: 2\r\n", b"{}".to_vec());
            let err = block_on(post_messages(&url(&u), Some("bad"), &json!({}), Duration::from_secs(5))).unwrap_err();
            assert!(err.contains("valid API key"), "{err}");
        }
        let detail = br#"{"error":{"message":"model not found"}}"#;
        let u = serve_once("404 Not Found", &format!("Content-Length: {}\r\n", detail.len()), detail.to_vec());
        let err = block_on(post_messages(&url(&u), None, &json!({}), Duration::from_secs(5))).unwrap_err();
        assert!(err.contains("model not found"), "{err}");
        let err = block_on(post_messages(&url("http://127.0.0.1:1"), None, &json!({}), Duration::from_secs(5))).unwrap_err();
        assert!(err.starts_with("Cannot reach http://127.0.0.1:1"), "{err}");
    }

    #[test]
    fn the_features_ask_for_their_model_first() {
        let config = Config { enabled: true, features: true, ..Default::default() };
        let err = block_on(messages(&config, json!({}), Duration::from_secs(1))).unwrap_err();
        assert!(err.contains("Pick the model"), "{err}");
    }

    /// Against the OmniRoute installed on this computer, started if it isn't:
    /// `cargo test omniroute::tests::live -- --ignored --nocapture`. The key is
    /// the one saved in Settings (or OMNIROUTE_TEST_KEY), never printed; with
    /// OMNIROUTE_TEST_MODEL, a chat turn and a features request go through it.
    #[test]
    #[ignore]
    fn live() {
        let url = base(&Config::default()).unwrap();
        let key = std::env::var("OMNIROUTE_TEST_KEY").ok().filter(|k| !k.trim().is_empty()).or_else(|| key_for(&url));
        println!("key: {}", if key.is_some() { "yes" } else { "none" });
        block_on(async {
            println!("launcher found: {}", launcher().is_some());
            let was_running = running(&url).await;
            println!("running before: {was_running}");
            if !was_running {
                let started = std::time::Instant::now();
                start_at(&url).await.expect("started");
                println!("started in {:.1}s", started.elapsed().as_secs_f32());
            }
            let listed = std::time::Instant::now();
            let models = list_models(&url, key.as_deref()).await;
            println!("listed in {:.2}s", listed.elapsed().as_secs_f32());
            match models {
                Ok(models) => println!("models: {} (first: {:?})", models.len(), models.first()),
                Err(Listing::Refused) => println!("models: refused ({})", if key.is_some() { "key refused" } else { "asks for a key" }),
                Err(Listing::Failed(err)) => println!("models: failed: {err}"),
            }
            let Some(model) = std::env::var("OMNIROUTE_TEST_MODEL").ok().filter(|m| !m.is_empty()) else { return };
            // The features: claude::complete's request, as routed here.
            let body = json!({
                "model": model, "max_tokens": 64, "system": "Answer with one word.",
                "messages": [{ "role": "user", "content": "Say hello." }],
            });
            match post_messages(&url, key.as_deref(), &body, Duration::from_secs(120)).await {
                Ok(reply) => {
                    let blocks = reply.get("content").and_then(Value::as_array).cloned().unwrap_or_default();
                    println!("features /v1/messages: {:?}", crate::claude::response_text(&blocks));
                }
                Err(err) => println!("features /v1/messages failed: {err}"),
            }
            // « OK Coucou »: a turn with a tool.
            let tools = json!([{ "name": "get_time", "description": "The current time.", "input_schema": { "type": "object", "properties": {} } }]);
            let body = json!({
                "model": model, "max_tokens": 256, "system": "Use the tool when asked the time.",
                "messages": [{ "role": "user", "content": "What time is it? Use get_time." }], "tools": tools,
            });
            match post_messages(&url, key.as_deref(), &body, Duration::from_secs(120)).await {
                Ok(reply) => println!("voice tools: stop_reason {:?}, blocks {:?}", reply["stop_reason"],
                    reply["content"].as_array().map(|b| b.iter().map(|x| x["type"].clone()).collect::<Vec<_>>())),
                Err(err) => println!("voice tools failed: {err}"),
            }
            // The chat: local_chat's streamed OpenAI-compatible turn, as the island sends it.
            let mut settings = Settings::default();
            settings.omniroute.enabled = true;
            let mut server = server(&settings);
            if server.key.is_none() {
                server.key = key.clone();
            }
            let chat = crate::chat::Chat::default();
            let mut deltas = 0;
            match crate::local_chat::send_with(&chat, &server, &model, "Say hello in three words.".into(), None, |_| deltas += 1).await {
                Ok(reply) => println!("chat: {:?} ({deltas} deltas)", reply.text),
                Err(err) => println!("chat failed: {err}"),
            }
        });
    }

    #[test]
    fn waking_leaves_other_servers_and_remote_routers_alone() {
        let server = |id, url: &str| Server { id, name: NAME, url: url.into(), key: None };
        assert!(block_on(wake(&server("ollama", "http://127.0.0.1:1"))).is_ok());
        assert!(block_on(wake(&server(PROVIDER, "https://router.example.com"))).is_ok());
        assert!(block_on(wake(&server(PROVIDER, ""))).is_ok());
    }

    #[test]
    fn a_server_elsewhere_is_never_started_from_here() {
        let err = block_on(start_at(&url("https://router.example.com"))).unwrap_err();
        assert!(err.contains("another computer"), "{err}");
    }
}
