// Claude plan usage from claude.ai itself: the 5-hour and weekly numbers the
// Claude app shows, live. The Claude app keeps its sign-in to itself, and the
// Claude Code command line may be set up with another provider, so Coucou has
// its own: Settings → Agents → Plan usage → Connect opens claude.ai in a window
// of Coucou's, where you sign in once. The session stays in that window's own
// folder (claude-web in Coucou's folder), apart from every other window; your
// password goes to claude.ai only.
//
// A hidden copy of that window then asks claude.ai every minute, from inside the
// page as the site itself would: its organisations, then that one's usage. The
// answer comes back as a navigation to an address that never loads
// (coucou-report.invalid), which the window refuses and reads. Nothing is sent
// anywhere else, and Disconnect deletes the session.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::Value;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "claude-account";
const SIGN_IN: &str = "https://claude.ai/login";
/// A claude.ai page with nothing to run: where the hidden window waits between asks.
const QUIET: &str = "https://claude.ai/api/organizations";
const REPORT_HOST: &str = "coucou-report.invalid";
const EVERY: Duration = Duration::from_secs(60);
/// Numbers older than this aren't live any more: the Claude app's record is used instead.
pub const FRESH_MS: f64 = 5.0 * 60_000.0;

/// Asks claude.ai, from inside its own page, and reports by navigating to REPORT_HOST.
const PROBE: &str = r#"(async () => {
  const send = (o) => { location.href = 'https://coucou-report.invalid/#' + encodeURIComponent(JSON.stringify(o)); };
  try {
    const r = await fetch('/api/organizations', { credentials: 'include' });
    const orgs = r.ok ? await r.json() : null;
    if (!Array.isArray(orgs) || !orgs.length) return send({ signedIn: false, status: r.status });
    const has = (o, re) => (o.capabilities || []).some((c) => re.test(String(c)));
    const org = orgs.find((o) => has(o, /claude_(max|pro)/)) || orgs.find((o) => has(o, /chat/)) || orgs[0];
    const u = await fetch('/api/organizations/' + org.uuid + '/usage', { credentials: 'include' });
    if (!u.ok) return send({ signedIn: true, status: u.status });
    send({ signedIn: true, usage: await u.json() });
  } catch (e) { send({ error: String((e && e.message) || e) }); }
})();"#;

#[derive(Default)]
struct Account {
    /// The last usage claude.ai gave, and when (epoch ms).
    usage: Option<(f64, Value)>,
    /// What the last ask found: signed in, signed out, or not asked yet.
    signed_in: Option<bool>,
    /// The sign-in window is up.
    signing_in: bool,
}

static ACCOUNT: Mutex<Account> = Mutex::new(Account { usage: None, signed_in: None, signing_in: false });

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AccountStatus {
    pub connected: bool,
    pub signed_in: Option<bool>,
    pub signing_in: bool,
    /// When claude.ai last answered (epoch ms).
    pub updated_at: Option<f64>,
}

fn now_ms() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as f64).unwrap_or(0.0)
}

fn data_dir() -> PathBuf {
    crate::platform::local_dir().join("claude-web")
}

fn marker() -> PathBuf {
    crate::platform::local_dir().join("claude-account.on")
}

pub fn connected() -> bool {
    marker().is_file()
}

/// The last usage from claude.ai while it is still live, for claude_plan.rs.
pub fn latest() -> Option<Value> {
    let a = ACCOUNT.lock().unwrap();
    a.usage.as_ref().filter(|(at, _)| now_ms() - at < FRESH_MS).map(|(_, v)| v.clone())
}

fn status() -> AccountStatus {
    let a = ACCOUNT.lock().unwrap();
    AccountStatus { connected: connected(), signed_in: a.signed_in, signing_in: a.signing_in, updated_at: a.usage.as_ref().map(|(at, _)| *at) }
}

fn publish(app: &AppHandle) {
    let _ = app.emit("claude-account", status());
}

/// `%7B%22a%22…` → `{"a"…`: what encodeURIComponent made of the report.
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(hi), Some(lo)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((hi * 16 + lo) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// What the page reported: usage (signed in), signed out, or an error (nothing changes).
fn report(app: &AppHandle, fragment: &str) {
    let Ok(v) = serde_json::from_str::<Value>(&percent_decode(fragment)) else { return };
    let signed_in = v.get("signedIn").and_then(Value::as_bool);
    let usage = v.get("usage").filter(|u| u.is_object()).cloned();
    let was_signing_in = {
        let mut a = ACCOUNT.lock().unwrap();
        if signed_in.is_some() {
            a.signed_in = signed_in;
        }
        if let Some(u) = usage.clone() {
            a.usage = Some((now_ms(), u));
        } else if signed_in == Some(false) {
            a.usage = None;
        }
        let was = a.signing_in;
        if usage.is_some() {
            a.signing_in = false;
        }
        was
    };
    if usage.is_some() {
        if !connected() {
            let _ = std::fs::create_dir_all(crate::platform::local_dir());
            let _ = std::fs::write(marker(), b"1");
        }
        // Signed in: the window steps out of the way and waits, hidden, on a quiet page.
        if was_signing_in {
            if let Some(w) = app.get_webview_window(LABEL) {
                let _ = w.hide();
                if let Ok(url) = QUIET.parse() {
                    let _ = w.navigate(url);
                }
            }
        }
        let _ = app.emit("claude-usage", ());
    }
    publish(app);
}

fn ask(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.eval(PROBE);
    }
}

/// The window, made when there is none: hidden on the quiet page, or shown on the sign-in page.
fn window(app: &AppHandle, show: bool) -> Option<tauri::WebviewWindow> {
    if let Some(w) = app.get_webview_window(LABEL) {
        return Some(w);
    }
    let url = if show { SIGN_IN } else { QUIET };
    let reporter = app.clone();
    let loaded = app.clone();
    WebviewWindowBuilder::new(app, LABEL, WebviewUrl::External(url.parse().ok()?))
        .title(crate::i18n::t("Sign in to Claude"))
        .inner_size(480.0, 720.0)
        .center()
        .visible(show)
        .skip_taskbar(!show)
        .data_directory(data_dir())
        .on_navigation(move |url| {
            if url.host_str() == Some(REPORT_HOST) {
                report(&reporter, url.fragment().unwrap_or_default());
                return false;
            }
            true
        })
        .on_page_load(move |_, payload| {
            if payload.event() == PageLoadEvent::Finished && payload.url().host_str() == Some("claude.ai") {
                ask(&loaded);
            }
        })
        .build()
        .ok()
}

/// Settings → Connect: claude.ai's sign-in, in Coucou's own window. Async: a window
/// made from a command on the main thread would wait for itself.
#[tauri::command]
pub async fn claude_account_connect(app: AppHandle) {
    ACCOUNT.lock().unwrap().signing_in = true;
    if let Some(w) = window(&app, true) {
        if let Ok(url) = SIGN_IN.parse() {
            let _ = w.navigate(url);
        }
        let _ = w.set_skip_taskbar(false);
        let _ = w.show();
        let _ = w.set_focus();
    }
    publish(&app);
}

/// Settings → Disconnect: the window closes and its session is deleted.
#[tauri::command]
pub async fn claude_account_disconnect(app: AppHandle) {
    let _ = std::fs::remove_file(marker());
    {
        let mut a = ACCOUNT.lock().unwrap();
        *a = Account::default();
    }
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.destroy();
    }
    publish(&app);
    // The browser lets go of its files a moment after the window is gone.
    std::thread::spawn(|| {
        for _ in 0..5 {
            std::thread::sleep(Duration::from_secs(2));
            if std::fs::remove_dir_all(data_dir()).is_ok() || !data_dir().exists() {
                return;
            }
        }
    });
}

#[tauri::command]
pub fn claude_account_status() -> AccountStatus {
    status()
}

/// At launch: while connected, ask every minute (and every few seconds while signing in).
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(5));
        let mut last = std::time::Instant::now() - EVERY;
        loop {
            let signing_in = ACCOUNT.lock().unwrap().signing_in;
            // The sign-in window closed before it was done: nothing to wait for.
            if signing_in && app.get_webview_window(LABEL).is_none() {
                ACCOUNT.lock().unwrap().signing_in = false;
                publish(&app);
            } else if signing_in {
                // claude.ai may finish signing in without a page load: look every few seconds.
                ask(&app);
            } else if connected() && last.elapsed() >= EVERY {
                last = std::time::Instant::now();
                if app.get_webview_window(LABEL).is_some() {
                    ask(&app);
                } else {
                    // Made from this thread, never the main one; its first page load asks.
                    window(&app, false);
                }
            }
            std::thread::sleep(Duration::from_secs(3));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_report_reads_back_as_it_was_sent() {
        assert_eq!(percent_decode("%7B%22signedIn%22%3Atrue%7D"), r#"{"signedIn":true}"#);
        assert_eq!(percent_decode("a%2"), "a%2");
        assert_eq!(percent_decode("%E2%9C%93"), "✓");
    }
}
