// A long-lived local Whisper process. Loading the model costs seconds, so it is
// loaded once and every later request (wake word, chat dictation) only pays for
// inference. It exits on its own when this process dies: its stdin closes.

use base64::Engine;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const SCRIPT: &str = include_str!("whisper_server.py");
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

struct Server {
    child: Child,
    stdin: ChildStdin,
    rx: Receiver<String>,
}

static SERVER: Mutex<Option<Server>> = Mutex::new(None);

fn start() -> Result<Server, String> {
    let python = crate::stt::resolve_whisper_python()
        .ok_or_else(|| "Local Whisper python environment not found".to_string())?;

    let dir = crate::settings::local_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("whisper server dir: {e}"))?;
    let script_path = dir.join("whisper_server.py");
    std::fs::write(&script_path, SCRIPT).map_err(|e| format!("whisper server script: {e}"))?;

    let mut cmd = Command::new(python);
    cmd.arg("-u")
        .arg(&script_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000);

    let mut child = cmd.spawn().map_err(|e| format!("whisper server spawn: {e}"))?;
    let stdin = child.stdin.take().ok_or("whisper server stdin")?;
    let stdout = child.stdout.take().ok_or("whisper server stdout")?;

    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for chunk in BufReader::new(stdout).split(b'\n') {
            let Ok(bytes) = chunk else { break };
            let line = String::from_utf8_lossy(&bytes).trim().to_string();
            if tx.send(line).is_err() {
                break;
            }
        }
    });

    crate::log::line("whisper server started");
    Ok(Server { child, stdin, rx })
}

/// Err.1 is true when the process is unusable and must be restarted.
fn run(server: &mut Server, path: &str, lang: &str, prompt: &str) -> Result<String, (String, bool)> {
    let req = serde_json::json!({ "path": path, "lang": lang, "prompt": prompt });
    writeln!(server.stdin, "{req}")
        .and_then(|_| server.stdin.flush())
        .map_err(|e| (format!("whisper server write: {e}"), true))?;

    let deadline = Instant::now() + REQUEST_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match server.rx.recv_timeout(remaining) {
            Ok(line) => {
                if let Some(text) = line.strip_prefix("RESULT:") {
                    return Ok(text.trim().to_string());
                }
                if let Some(err) = line.strip_prefix("ERROR:") {
                    return Err((format!("whisper server: {err}"), false));
                }
            }
            Err(_) => return Err(("whisper server timed out or exited".to_string(), true)),
        }
    }
}

pub fn transcribe(path: &str, lang: &str, prompt: &str) -> Result<String, String> {
    let mut guard = SERVER.lock().map_err(|_| "whisper server lock poisoned".to_string())?;
    let mut server = match guard.take() {
        Some(s) => s,
        None => start()?,
    };
    match run(&mut server, path, lang, prompt) {
        Ok(text) => {
            *guard = Some(server);
            Ok(text)
        }
        Err((msg, fatal)) => {
            if fatal {
                let _ = server.child.kill();
                let _ = server.child.wait();
            } else {
                *guard = Some(server);
            }
            crate::log::line(format!("whisper server error: {msg}"));
            Err(msg)
        }
    }
}

/// Loads the model in the background so the first wake word is not slow.
pub fn warm_up() {
    std::thread::spawn(|| {
        let Ok(mut guard) = SERVER.lock() else { return };
        if guard.is_none() {
            match start() {
                Ok(s) => *guard = Some(s),
                Err(e) => crate::log::line(format!("whisper server warm-up failed: {e}")),
            }
        }
    });
}

pub fn stop() {
    if let Ok(mut guard) = SERVER.lock() {
        if let Some(mut s) = guard.take() {
            let _ = s.child.kill();
            let _ = s.child.wait();
        }
    }
}

#[tauri::command]
pub async fn wake_transcribe(audio_base64: String, lang: String, prompt: String) -> Result<String, String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .map_err(|e| format!("wake audio decode: {e}"))?;

    tauri::async_runtime::spawn_blocking(move || {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let wav = std::env::temp_dir().join(format!("coucou_wake_{}_{}.wav", std::process::id(), nanos));
        std::fs::write(&wav, &bytes).map_err(|e| format!("wake wav write: {e}"))?;
        let path = wav.to_string_lossy().replace('\\', "/");
        let result = transcribe(&path, &lang, &prompt);
        let _ = std::fs::remove_file(&wav);
        result
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn wake_server_warm_up() {
    warm_up();
}

#[tauri::command]
pub fn wake_server_stop() {
    stop();
}
