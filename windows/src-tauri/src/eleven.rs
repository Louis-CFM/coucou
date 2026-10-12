// Maki's conversation side, through an ElevenLabs agent. Windows only.
//
// The wake word stays on the device (voice.rs). Once it's heard, the page
// (src/voice/eleven.ts) talks to the user's ElevenLabs agent over a WebSocket
// opened with a signed URL, which this module fetches with the API key kept
// in the credential store — the page never sees the key. The agent's client
// tools run here: `ask_hermes` hands the request to the Hermes agent on this
// PC (`hermes -z`), the `coucou` tool is the page's own.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::i18n::t;

pub const KEY: &str = "elevenlabs-api-key";
/// The agent created for Maki on the user's ElevenLabs account.
pub const DEFAULT_AGENT: &str = "agent_8401m4q6khr6f6xsz32805aq1fve";
// Maki calls back with the answer, so no call is held open while Hermes works.
const HERMES_TIMEOUT: Duration = Duration::from_secs(300);
const HERMES_MAX: usize = 4000;

/// A one-time WebSocket URL for the agent, signed with the user's key.
#[tauri::command]
pub async fn eleven_signed_url(agent_id: Option<String>) -> Result<String, String> {
    let key = crate::secrets::get(KEY).ok_or_else(|| t("No ElevenLabs API key — add it in Settings → Voice."))?;
    let agent = agent_id.filter(|a| a.starts_with("agent_") && a.len() < 80).unwrap_or_else(|| DEFAULT_AGENT.to_string());
    let client = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().map_err(|e| e.to_string())?;
    let res = client
        .get("https://api.elevenlabs.io/v1/convai/conversation/get-signed-url")
        .query(&[("agent_id", agent.as_str())])
        .header("xi-api-key", key)
        .send()
        .await
        .map_err(|_| t("Can't reach ElevenLabs."))?;
    if !res.status().is_success() {
        crate::log::line(format!("eleven: signed url refused ({})", res.status()));
        return Err(t("ElevenLabs refused the key or the agent."));
    }
    let j: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    let url = j["signed_url"].as_str().unwrap_or_default().to_string();
    // Only ElevenLabs' own conversation socket.
    if !url.starts_with("wss://api.elevenlabs.io/") && !url.starts_with("wss://api.us.elevenlabs.io/") && !url.starts_with("wss://api.eu.residency.elevenlabs.io/") {
        return Err(t("ElevenLabs refused the key or the agent."));
    }
    Ok(url)
}

/// The ElevenLabs credits this month: used, limit, and when they reset.
#[derive(serde::Serialize)]
pub struct ElevenUsage {
    used: u64,
    limit: u64,
    /// Unix seconds.
    resets_at: u64,
}

#[tauri::command]
pub async fn eleven_usage() -> Result<ElevenUsage, String> {
    let key = crate::secrets::get(KEY).ok_or_else(|| t("No ElevenLabs API key — add it in Settings → Voice."))?;
    let client = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().map_err(|e| e.to_string())?;
    let res = client
        .get("https://api.elevenlabs.io/v1/user/subscription")
        .header("xi-api-key", key)
        .send()
        .await
        .map_err(|_| t("Can't reach ElevenLabs."))?;
    if !res.status().is_success() {
        crate::log::line(format!("eleven: usage refused ({})", res.status()));
        return Err(t("ElevenLabs refused the key or the agent."));
    }
    let j: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    Ok(ElevenUsage {
        used: j["character_count"].as_u64().unwrap_or(0),
        limit: j["character_limit"].as_u64().unwrap_or(0),
        resets_at: j["next_character_count_reset_unix"].as_u64().unwrap_or(0),
    })
}

fn hermes_exe() -> Option<std::path::PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA").map(std::path::PathBuf::from)?;
    let exe = local.join("hermes").join("hermes-agent").join(".venv").join("Scripts").join("hermes.exe");
    exe.is_file().then_some(exe).or_else(|| crate::platform::find_on_path("hermes"))
}

/// Reads Hermes' session store while it works and prints one line per step
/// (the command it runs, the page it reads…): `hermes -z` itself is silent
/// until the answer. Runs on Hermes' own Python, which has sqlite3 built in.
// ponytail: polls Hermes' state.db schema (sessions/messages); if Hermes changes it, only the live steps go quiet.
const WATCHER: &str = r#"
import sqlite3, sys, time, json, os
sys.stdout.reconfigure(encoding="utf-8")
since = float(sys.argv[1]); db = os.path.expandvars(r"%LOCALAPPDATA%\hermes\state.db")
sid = None; last = 0; quiet = 0
def short(s, n=90):
    s = " ".join(str(s).split()); return s if len(s) <= n else s[:n-1] + "\u2026"
while True:
    time.sleep(1); quiet += 1
    try:
        c = sqlite3.connect("file:" + db + "?mode=ro", uri=True, timeout=2)
        if sid is None:
            r = c.execute("select id from sessions where started_at >= ? order by started_at desc limit 1", (since,)).fetchone()
            sid = r and r[0]
        if sid:
            for mid, role, content, calls, tool in c.execute("select id, role, content, tool_calls, tool_name from messages where session_id=? and id>? order by id", (sid, last)).fetchall():
                last = mid
                if role == "assistant" and calls:
                    for k in json.loads(calls):
                        f = k.get("function", k); args = f.get("arguments") or "{}"
                        try: a = json.loads(args)
                        except Exception: a = {}
                        what = next((a[x] for x in ("command", "query", "url", "path", "action", "text") if x in a), "")
                        print(short(f.get("name", "tool") + (": " + str(what) if what else "")), flush=True); quiet = 0
                elif role == "tool" and content:
                    print(short("\u2192 " + content, 70), flush=True); quiet = 0
        c.close()
    except Exception:
        pass
    if quiet and quiet % 10 == 0:
        print("thinking\u2026", flush=True)
"#;

/// Hermes' Python, next to hermes.exe.
fn hermes_python(exe: &std::path::Path) -> Option<std::path::PathBuf> {
    let py = exe.with_file_name("python.exe");
    py.is_file().then_some(py)
}

/// Streams Hermes' steps to the island and the log until `child` is dropped.
fn watch_hermes(exe: &std::path::Path) -> Option<std::process::Child> {
    let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64() - 2.0;
    let mut cmd = Command::new(hermes_python(exe)?);
    cmd.args(["-I", "-c", WATCHER, &since.to_string()]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    crate::platform::no_console(&mut cmd);
    let mut child = cmd.spawn().ok()?;
    let out = child.stdout.take()?;
    std::thread::spawn(move || {
        use std::io::BufRead;
        for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
            crate::log::line(format!("hermes: {line}"));
            crate::voice::emit("hermes-progress", line);
        }
    });
    Some(child)
}

/// Trims what Hermes prints to the answer itself, capped.
pub fn hermes_answer(stdout: &str) -> String {
    let text = stdout.trim();
    let text: String = text.chars().take(HERMES_MAX).collect();
    text
}

/// The agent's `ask_hermes`: one request to Hermes on this PC (`hermes -z`).
#[tauri::command]
pub async fn ask_hermes(request: String) -> Result<String, String> {
    let Some(exe) = hermes_exe() else { return Err(t("Hermes isn't installed on this PC.")) };
    let request: String = request.chars().take(4000).collect();
    tauri::async_runtime::spawn_blocking(move || {
        let exe_path = exe.clone();
        let mut cmd = Command::new(exe);
        // Voice requests get a lean toolset: the full one makes the prompt so big
        // the free model took ~106 s for a one-line command; this takes ~35 s.
        cmd.arg("-z").arg(&request).args(["-t", "terminal,file,web,memory,computer_use"]).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        if let Some(home) = std::env::var_os("USERPROFILE") {
            cmd.current_dir(home);
        }
        crate::platform::no_console(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| format!("hermes: {e}"))?;
        let started = Instant::now();
        crate::voice::emit("hermes-progress", t("Hermes is working…"));
        let mut watcher = watch_hermes(&exe_path);
        let mut stdout = child.stdout.take().ok_or("hermes: no output")?;
        // Read on a thread so a hung Hermes can be stopped at the timeout.
        let reader = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = stdout.read_to_string(&mut s);
            s
        });
        let stop_watcher = |w: &mut Option<std::process::Child>| {
            if let Some(w) = w.as_mut() {
                let _ = w.kill();
            }
        };
        loop {
            if let Ok(Some(_)) = child.try_wait() {
                stop_watcher(&mut watcher);
                break;
            }
            if started.elapsed() > HERMES_TIMEOUT {
                stop_watcher(&mut watcher);
                let _ = child.kill();
                crate::log::line("eleven: hermes timed out");
                return Err(t("Hermes took too long."));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        let out = reader.join().unwrap_or_default();
        crate::log::line(format!("eleven: hermes answered in {} s", started.elapsed().as_secs()));
        let answer = hermes_answer(&out);
        if answer.is_empty() { Err(t("Hermes gave no answer.")) } else { Ok(answer) }
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Lower-case letters and digits only: "Telegram Desktop" → "telegramdesktop".
fn squash(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

/// The best Start menu entry for a spoken name: exact, then starts with, then
/// contains (shortest wins, so "Spotify" beats "Spotify Uninstall").
pub fn best_app<'a>(apps: &'a [(String, String)], name: &str) -> Option<&'a (String, String)> {
    let want = squash(name.trim_start_matches("the ").trim_end_matches(" app"));
    if want.is_empty() {
        return None;
    }
    let skip = |n: &str| n.contains("uninstall") || n.contains("readme") || n.contains("help");
    let pick = |f: &dyn Fn(&str) -> bool| {
        apps.iter().filter(|(n, _)| {
            let n = squash(n);
            !skip(&n) && f(&n)
        }).min_by_key(|(n, _)| n.len())
    };
    pick(&|n| n == want).or_else(|| pick(&|n| n.starts_with(&want))).or_else(|| pick(&|n| n.contains(&want)))
}

static APPS: std::sync::Mutex<Vec<(String, String)>> = std::sync::Mutex::new(Vec::new());

/// Every app in the Start menu, desktop and Store, as (name, AppID).
fn start_apps() -> Vec<(String, String)> {
    let mut cmd = Command::new("powershell.exe");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", "Get-StartApps | ForEach-Object { $_.Name + [char]9 + $_.AppID }"])
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    crate::platform::no_console(&mut cmd);
    let out = cmd.output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    out.lines().filter_map(|l| l.split_once('\t')).map(|(n, id)| (n.trim().to_string(), id.trim().to_string())).collect()
}

/// The agent's "open an app": launches an installed app by name. Never a web search.
#[tauri::command]
pub async fn open_app(name: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let found = {
            let apps = APPS.lock().unwrap().clone();
            best_app(&apps, &name).cloned()
        };
        // Not in the cached list: the list may be stale (a new install), read it again.
        let found = found.or_else(|| {
            let fresh = start_apps();
            let hit = best_app(&fresh, &name).cloned();
            *APPS.lock().unwrap() = fresh;
            hit
        });
        let Some((app, id)) = found else { return Err(format!("No app called {name} is installed.")) };
        let mut cmd = Command::new("explorer.exe");
        cmd.arg(format!("shell:AppsFolder\\{id}"));
        cmd.spawn().map_err(|e| e.to_string())?;
        crate::log::line(format!("eleven: opened app {app}"));
        Ok(app)
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Locks the PC, like Win+L.
#[tauri::command]
pub fn lock_screen() -> Result<(), String> {
    let mut cmd = Command::new("rundll32.exe");
    cmd.arg("user32.dll,LockWorkStation");
    cmd.spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apps_are_found_by_spoken_name() {
        let apps: Vec<(String, String)> = [
            ("Telegram Desktop", "tg"), ("Spotify", "sp"), ("Uninstall Spotify", "un"),
            ("Notepad", "np"), ("Notepad++", "npp"), ("Opera GX Browser", "gx"), ("Opera Browser", "op"),
        ].iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
        let id = |n: &str| best_app(&apps, n).map(|x| x.1.as_str());
        assert_eq!(id("Telegram"), Some("tg"));
        assert_eq!(id("spotify"), Some("sp"));
        assert_eq!(id("notepad"), Some("np"));
        assert_eq!(id("the opera app"), Some("op"));
        assert_eq!(id("Solar Eclipse by Drake"), None);
        assert_eq!(id(""), None);
    }

    #[test]
    fn hermes_answers_are_trimmed_and_capped() {
        assert_eq!(hermes_answer("  hello from hermes\n"), "hello from hermes");
        assert_eq!(hermes_answer(&"x".repeat(9000)).len(), HERMES_MAX);
    }
}
