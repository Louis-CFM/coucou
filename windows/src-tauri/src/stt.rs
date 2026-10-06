use base64::Engine;
use reqwest::multipart::{Form, Part};
use serde_json::Value;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

pub fn resolve_whisper_python() -> Option<PathBuf> {
    let unsloth_fixed = PathBuf::from(r"C:\Users\felix\.unsloth\studio\unsloth_studio\Scripts\python.exe");
    if unsloth_fixed.exists() {
        return Some(unsloth_fixed);
    }

    if let Ok(user_profile) = std::env::var("USERPROFILE") {
        let candidate = PathBuf::from(user_profile).join(r".unsloth\studio\unsloth_studio\Scripts\python.exe");
        if candidate.exists() {
            return Some(candidate);
        }
    }

    if let Ok(whisper_path) = which::which("whisper.exe").or_else(|_| which::which("whisper")) {
        if let Some(parent) = whisper_path.parent() {
            let sibling = parent.join("python.exe");
            if sibling.exists() {
                return Some(sibling);
            }
            let sibling_no_ext = parent.join("python");
            if sibling_no_ext.exists() {
                return Some(sibling_no_ext);
            }
        }
    }

    if let Ok(python_path) = which::which("python.exe").or_else(|_| which::which("python")) {
        #[cfg(windows)]
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        let mut cmd = Command::new(&python_path);
        cmd.args(["-c", "import whisper"]);
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        if let Ok(status) = cmd.status() {
            if status.success() {
                return Some(python_path);
            }
        }
    }

    None
}

pub fn transcribe_local_whisper(audio_bytes: &[u8], lang: &str) -> Result<String, String> {
    let python_bin = resolve_whisper_python()
        .ok_or_else(|| "Local Whisper python environment not found".to_string())?;

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp_wav = std::env::temp_dir().join(format!("coucou_whisper_{}_{}.wav", std::process::id(), nanos));
    std::fs::write(&temp_wav, audio_bytes).map_err(|e| format!("Failed to write temp wav: {e}"))?;

    let wav_path_str = temp_wav.to_string_lossy().replace('\\', "/");

    let short_lang = if lang.starts_with("id") {
        "id"
    } else if lang.starts_with("en") {
        "en"
    } else {
        lang.split('-').next().unwrap_or(lang)
    };

    match crate::whisper_server::transcribe(
        &wav_path_str,
        "auto",
        "Halo, percakapan dalam bahasa Indonesia atau Inggris.",
    ) {
        Ok(text) => {
            let _ = std::fs::remove_file(&temp_wav);
            crate::log::line(format!("stt local whisper (server) transcribed: '{text}'"));
            return Ok(text);
        }
        Err(e) => crate::log::line(format!("stt whisper server unavailable, one-shot fallback: {e}")),
    }

    let script = format!(
        r#"
import sys, warnings
warnings.filterwarnings('ignore')
import whisper
try:
    model = whisper.load_model('base')
except Exception:
    model = whisper.load_model('tiny')
res = model.transcribe(
    r'{wav_path}',
    language='{short_lang}',
    fp16=False,
    verbose=False,
    condition_on_previous_text=False,
    temperature=0.0,
    initial_prompt='Halo, percakapan dalam bahasa Indonesia atau Inggris.'
)
text = res.get('text', '').strip()
print('RESULT:' + text)
"#,
        wav_path = wav_path_str,
        short_lang = short_lang
    );

    #[cfg(windows)]
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let mut cmd = Command::new(&python_bin);
    cmd.args(["-c", &script]);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let output = cmd.output();
    let _ = std::fs::remove_file(&temp_wav);

    let out = output.map_err(|e| {
        let msg = format!("Local whisper process failed: {e}");
        crate::log::line(format!("stt local whisper failed: {msg}"));
        msg
    })?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let msg = format!("Local whisper failed: {}", stderr.trim());
        crate::log::line(format!("stt local whisper failed: {msg}"));
        return Err(msg);
    }

    let stdout = String::from_utf8_lossy(&out.stdout);
    let text = stdout
        .lines()
        .find_map(|l| {
            let trimmed = l.trim();
            trimmed.strip_prefix("RESULT:").map(|rest| rest.trim().to_string())
        })
        .unwrap_or_default();

    crate::log::line(format!("stt local whisper transcribed: '{text}'"));
    Ok(text)
}

#[cfg(windows)]
fn transcribe_windows_native(audio_bytes: &[u8]) -> Result<String, String> {
    const CREATE_NO_WINDOW: u32 = 0x08000000;

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp_wav = std::env::temp_dir().join(format!("coucou_stt_{}_{}.wav", std::process::id(), nanos));
    std::fs::write(&temp_wav, audio_bytes).map_err(|e| format!("Failed to write temp wav: {e}"))?;

    let wav_path_str = temp_wav.to_string_lossy().to_string();
    let script = format!(
        r#"
Add-Type -AssemblyName System.Speech;
try {{
    $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine;
    $recognizer.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar));
    $recognizer.SetInputToWaveFile('{0}');
    $result = $recognizer.Recognize();
    if ($result) {{ [Console]::WriteLine($result.Text); }}
    $recognizer.Dispose();
}} catch {{
    [Console]::WriteLine('ERROR: ' + $_.Exception.Message);
}}
"#,
        wav_path_str.replace('\'', "''")
    );

    let output = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW)
        .output();

    let _ = std::fs::remove_file(&temp_wav);

    let out = output.map_err(|e| {
        let msg = format!("Native recognition process failed: {e}");
        crate::log::line(format!("stt native failed: {msg}"));
        msg
    })?;

    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if text.starts_with("ERROR: ") {
        crate::log::line(format!("stt native failed: {text}"));
        return Err(text);
    }
    crate::log::line(format!("stt native recognized: '{text}'"));
    Ok(text)
}

#[cfg(not(windows))]
fn transcribe_windows_native(_bytes: &[u8]) -> Result<String, String> {
    Err("Native recognition only supported on Windows".into())
}

#[tauri::command]
pub async fn stt_transcribe(
    audio_base64: String,
    lang: String,
    provider: String,
    whisper_url: String,
) -> Result<String, String> {
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(&audio_base64)
        .map_err(|e| format!("Invalid base64 audio: {e}"))?;

    crate::log::line(format!("stt_transcribe called, bytes={}, provider={provider}, lang={lang}", audio_bytes.len()));

    if provider == "whisper" {
        let clean_url = whisper_url.trim_end_matches('/');
        let endpoint = format!("{clean_url}/v1/audio/transcriptions");
        crate::log::line(format!("calling whisper endpoint: {endpoint}"));

        let client = reqwest::Client::new();
        let part_res = Part::bytes(audio_bytes.clone())
            .file_name("audio.wav")
            .mime_str("audio/wav");

        let call_remote = async {
            let part = part_res.map_err(|e| format!("Mime error: {e}"))?;
            let short_lang = if lang.starts_with("id") {
                "id"
            } else if lang.starts_with("en") {
                "en"
            } else {
                lang.split('-').next().unwrap_or(&lang)
            };

            let form = Form::new()
                .part("file", part)
                .text("model", "whisper-1")
                .text("language", short_lang.to_string());

            let res = client
                .post(&endpoint)
                .multipart(form)
                .send()
                .await
                .map_err(|e| {
                    crate::log::line(format!("stt whisper network failed: {e}"));
                    format!("Whisper connection failed: {e}")
                })?;

            if !res.status().is_success() {
                let status = res.status();
                let body = res.text().await.unwrap_or_default();
                crate::log::line(format!("stt whisper returned {status}: {body}"));
                return Err(format!("Whisper returned {status}: {body}"));
            }

            let json: Value = res
                .json()
                .await
                .map_err(|e| format!("Failed to parse Whisper response: {e}"))?;

            let text = json["text"].as_str().unwrap_or("").trim().to_string();
            crate::log::line(format!("stt whisper transcribed: '{text}'"));
            Ok(text)
        };

        match call_remote.await {
            Ok(text) => Ok(text),
            Err(e) => {
                crate::log::line(format!("remote whisper failed ({e}), falling back to local whisper"));
                transcribe_local_whisper(&audio_bytes, &lang)
            }
        }
    } else {
        if lang.starts_with("id") || resolve_whisper_python().is_some() {
            match transcribe_local_whisper(&audio_bytes, &lang) {
                Ok(text) => Ok(text),
                Err(err) => {
                    crate::log::line(format!("local whisper failed ({err}), falling back to windows native"));
                    transcribe_windows_native(&audio_bytes)
                }
            }
        } else {
            transcribe_windows_native(&audio_bytes)
        }
    }
}
