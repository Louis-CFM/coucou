use base64::Engine;
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::path::{Path, PathBuf};
#[cfg(windows)]
use std::process::Command;

static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

#[allow(dead_code)]
const TRUSTED_CLIENT_TOKEN: &str = "6A5AA1D4EAFF4E9FB37E23D68491D6F4";
#[allow(dead_code)]
const WIN_EPOCH: u64 = 11644473600;

#[allow(dead_code)]
pub fn generate_sec_ms_gec() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let mut ticks = now + WIN_EPOCH;
    ticks -= ticks % 300;
    ticks *= 10_000_000;

    let input = format!("{}{}", ticks, TRUSTED_CLIENT_TOKEN);
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    format!("{:X}", hasher.finalize())
}

#[cfg(windows)]
fn resolve_edge_tts_cmd() -> Option<(PathBuf, Vec<String>)> {
    // 1. Direct which / PATH check
    if let Ok(path) = which::which("edge-tts") {
        return Some((path, vec![]));
    }
    // 2. Python user scripts in LOCALAPPDATA
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        let base = Path::new(&local).join("Programs").join("Python");
        if let Ok(entries) = std::fs::read_dir(&base) {
            for entry in entries.flatten() {
                let candidate = entry.path().join("Scripts").join("edge-tts.exe");
                if candidate.exists() {
                    return Some((candidate, vec![]));
                }
            }
        }
    }
    // 3. Fallback to python -m edge_tts
    if let Ok(py) = which::which("python") {
        return Some((py, vec!["-m".to_string(), "edge_tts".to_string()]));
    }
    None
}

#[cfg(windows)]
fn speak_windows_sapi(
    text: &str,
    voice_name: &str,
    lang: &str,
    _rate: &str,
    _volume: &str,
) -> Result<Vec<u8>, String> {
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let script = format!(
        r#"
Add-Type -AssemblyName System.Speech;
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer;
$installed = $synth.GetInstalledVoices();
$matched = $null;
foreach ($v in $installed) {{
    if ($v.VoiceInfo.Name -like '*{0}*') {{ $matched = $v.VoiceInfo.Name; break; }}
}}
if (-not $matched) {{
    foreach ($v in $installed) {{
        if ($v.VoiceInfo.Culture.Name -like '*{1}*') {{ $matched = $v.VoiceInfo.Name; break; }}
    }}
}}
if ($matched) {{ $synth.SelectVoice($matched); }}
$ms = New-Object System.IO.MemoryStream;
$synth.SetOutputToWaveStream($ms);
$synth.Speak('{2}');
[System.Convert]::ToBase64String($ms.ToArray());
"#,
        voice_name.replace('\'', "''"),
        lang.replace('\'', "''"),
        text.replace('\'', "''")
    );

    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| format!("PowerShell SAPI failed: {e}"))?;

    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        return Err(format!("SAPI execution error: {err}"));
    }

    let b64 = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if b64.is_empty() {
        return Err("Empty audio returned from Windows SAPI".into());
    }

    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .map_err(|e| format!("Base64 audio decode failed: {e}"))?;
    crate::log::line("tts generated via Windows SAPI");
    Ok(bytes)
}

#[cfg(not(windows))]
fn speak_windows_sapi(
    _text: &str,
    _voice: &str,
    _lang: &str,
    _rate: &str,
    _volume: &str,
) -> Result<Vec<u8>, String> {
    Err("Windows SAPI not available on this platform".into())
}

pub async fn speak(
    text: &str,
    voice: &str,
    lang: &str,
    rate: &str,
    volume: &str,
    pitch: &str,
) -> Result<Vec<u8>, String> {
    STOP_REQUESTED.store(false, Ordering::Relaxed);

    // 1. Try python edge-tts CLI if installed on the system
    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        let temp_dir = std::env::temp_dir();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temp_file = temp_dir.join(format!("coucou_tts_{}_{}.mp3", std::process::id(), nanos));
        let temp_str = temp_file.to_string_lossy().to_string();
        let temp_txt_file = temp_dir.join(format!("coucou_tts_{}_{}.txt", std::process::id(), nanos));
        let temp_txt_str = temp_txt_file.to_string_lossy().to_string();

        let _ = std::fs::write(&temp_txt_file, text);

        if let Some((cmd_path, extra_args)) = resolve_edge_tts_cmd() {
            let mut cmd = Command::new(cmd_path);
            for arg in &extra_args {
                cmd.arg(arg);
            }
            cmd.args([
                format!("--voice={voice}"),
                format!("--rate={rate}"),
                format!("--volume={volume}"),
                format!("--pitch={pitch}"),
                "--file".to_string(),
                temp_txt_str.clone(),
                format!("--write-media={temp_str}"),
            ])
            .creation_flags(CREATE_NO_WINDOW);

            if let Ok(out) = cmd.output() {
                if out.status.success() && temp_file.exists() {
                    if let Ok(bytes) = std::fs::read(&temp_file) {
                        let _ = std::fs::remove_file(&temp_file);
                        let _ = std::fs::remove_file(&temp_txt_file);
                        crate::log::line("tts generated via edge-tts");
                        return Ok(bytes);
                    }
                } else {
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    crate::log::line(format!("tts edge-tts error: {}", stderr.trim()));
                }
            }
        }
        let _ = std::fs::remove_file(&temp_file);
        let _ = std::fs::remove_file(&temp_txt_file);

        crate::log::line("tts edge-tts failed, falling back to SAPI");
    }

    // 2. Fallback to Windows SAPI / Speech Synthesis
    speak_windows_sapi(text, voice, lang, rate, volume)
}

#[tauri::command]
pub async fn tts_speak(
    text: String,
    voice: String,
    lang: String,
    rate: Option<String>,
    volume: Option<String>,
    pitch: Option<String>,
) -> Result<Vec<u8>, String> {
    let r = rate.unwrap_or_else(|| "+0%".to_string());
    let v = volume.unwrap_or_else(|| "+0%".to_string());
    let p = pitch.unwrap_or_else(|| "+0Hz".to_string());
    speak(&text, &voice, &lang, &r, &v, &p).await
}

#[tauri::command]
pub fn tts_stop() -> Result<(), String> {
    STOP_REQUESTED.store(true, Ordering::Relaxed);
    Ok(())
}
