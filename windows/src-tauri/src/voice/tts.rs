//! Explicit local, online Read Aloud, and cancellable system speech options.
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Mutex,
};
use std::time::Duration;
use tauri::{AppHandle, Manager};

pub fn generate(
    app: &AppHandle,
    output: &str,
    provider: Option<&str>,
    text: &str,
    stop: Option<&AtomicBool>,
) -> Option<String> {
    if !matches!(output, "local" | "edge") {
        return None;
    }
    let settings = app
        .state::<crate::Shared>()
        .settings
        .lock()
        .unwrap()
        .clone();
    if output == "edge" {
        let epoch = NATIVE_EPOCH.load(Ordering::Relaxed);
        let python = settings.edge_voice_python.strip_prefix("~/")
            .map(|relative| crate::platform::home_dir().join(relative))
            .unwrap_or_else(|| std::path::PathBuf::from(&settings.edge_voice_python));
        let result = crate::speech::edge_tts::generate(
            &python,
            text,
            || {
                NATIVE_EPOCH.load(Ordering::Relaxed) == epoch
                    && !stop.is_some_and(|s| s.load(Ordering::Relaxed))
            },
        );
        if result.is_none()
            && NATIVE_EPOCH.load(Ordering::Relaxed) == epoch
            && !stop.is_some_and(|s| s.load(Ordering::Relaxed))
        {
            crate::flow::pill::announce(app, "voice", "#FFB84D", crate::i18n::t(
                "Raquel is unavailable. Check the internet connection and voice runtime. The reply remains as text."
            ), None, 7);
        }
        return result.map(|mp3| {
            crate::log::line(format!("voice: Raquel synthesis ready ({} bytes)", mp3.len()));
            format!("data:audio/mpeg;base64,{}", super::base64(&mp3))
        });
    }
    let configured = provider
        .and_then(|p| settings.local_voice_dirs.get(p))
        .filter(|s| !s.trim().is_empty())
        .or_else(|| {
            settings
                .local_voice_dirs
                .get("default")
                .filter(|s| !s.trim().is_empty())
        });
    if stop.is_some_and(|s| s.load(Ordering::Relaxed)) {
        return None;
    }
    let epoch = NATIVE_EPOCH.load(Ordering::Relaxed);
    // No implicit voice: the evaluated Piper candidates were rejected. Only a
    // folder explicitly chosen by the user can become their local voice.
    let result = configured.and_then(|directory| {
        crate::speech::local_tts::generate(std::path::Path::new(directory), text, move || {
            NATIVE_EPOCH.load(Ordering::Relaxed) == epoch
        })
    });
    if result.is_none() && NATIVE_EPOCH.load(Ordering::Relaxed) == epoch {
        crate::flow::pill::announce(
            app,
            "voice",
            "#FFB84D",
            crate::i18n::t(
                "Local voice unavailable. Check the pt-PT model folder. Using the system voice.",
            ),
            None,
            7,
        );
    }
    result.map(|wav| format!("data:audio/wav;base64,{}", super::base64(&wav)))
}

// Own only the process started for this reply. Never cancel another app's
// speech service, desktop audio, or a user's CLI process.
static NATIVE: Mutex<Option<std::process::Child>> = Mutex::new(None);
static NATIVE_EPOCH: AtomicU64 = AtomicU64::new(0);
pub fn epoch() -> u64 {
    NATIVE_EPOCH.load(Ordering::Relaxed)
}
pub fn cancel_native() {
    NATIVE_EPOCH.fetch_add(1, Ordering::Relaxed);
    if let Some(mut child) = NATIVE.lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}
pub fn say_native(text: &str, lang: Option<&str>) -> bool {
    #[cfg(target_os = "linux")]
    {
        use std::io::Write;
        use std::process::{Command, Stdio};
        cancel_native();
        let epoch = NATIVE_EPOCH.load(Ordering::Relaxed);
        let language = lang.unwrap_or("").split('-').next().unwrap_or("");
        let (exe, direct) = if let Some(exe) = crate::platform::find_on_path("espeak-ng") {
            (exe, true)
        } else if let Some(exe) = crate::platform::find_on_path("spd-say") {
            (exe, false)
        } else {
            return false;
        };
        let mut cmd = Command::new(exe);
        if direct {
            cmd.arg("--stdin");
            if !language.is_empty() {
                cmd.args(["-v", language]);
            }
        } else {
            cmd.arg("-w");
            if !language.is_empty() {
                cmd.args(["-l", language]);
            }
            cmd.arg(text);
        }
        let mut child = match cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => return false,
        };
        if direct {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
        }
        {
            let mut slot = NATIVE.lock().unwrap();
            if NATIVE_EPOCH.load(Ordering::Relaxed) != epoch {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
            *slot = Some(child);
        }
        loop {
            if NATIVE_EPOCH.load(Ordering::Relaxed) != epoch {
                return false;
            }
            {
                let mut slot = NATIVE.lock().unwrap();
                let Some(child) = slot.as_mut() else {
                    return false;
                };
                match child.try_wait() {
                    Ok(Some(status)) => {
                        let success = status.success();
                        *slot = None;
                        return success;
                    }
                    Err(_) => {
                        *slot = None;
                        return false;
                    }
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (text, lang);
        false
    }
}
