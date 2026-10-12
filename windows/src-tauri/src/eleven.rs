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
pub const DEFAULT_AGENT: &str = "agent_1001m4q3zm64emqtn3ay9jk246m8";
const HERMES_TIMEOUT: Duration = Duration::from_secs(115);
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

fn hermes_exe() -> Option<std::path::PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA").map(std::path::PathBuf::from)?;
    let exe = local.join("hermes").join("hermes-agent").join(".venv").join("Scripts").join("hermes.exe");
    exe.is_file().then_some(exe).or_else(|| crate::platform::find_on_path("hermes"))
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
        let mut cmd = Command::new(exe);
        cmd.arg("-z").arg(&request).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
        if let Some(home) = std::env::var_os("USERPROFILE") {
            cmd.current_dir(home);
        }
        crate::platform::no_console(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| format!("hermes: {e}"))?;
        let started = Instant::now();
        let mut stdout = child.stdout.take().ok_or("hermes: no output")?;
        // Read on a thread so a hung Hermes can be stopped at the timeout.
        let reader = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = stdout.read_to_string(&mut s);
            s
        });
        loop {
            if let Ok(Some(_)) = child.try_wait() {
                break;
            }
            if started.elapsed() > HERMES_TIMEOUT {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hermes_answers_are_trimmed_and_capped() {
        assert_eq!(hermes_answer("  hello from hermes\n"), "hello from hermes");
        assert_eq!(hermes_answer(&"x".repeat(9000)).len(), HERMES_MAX);
    }
}
