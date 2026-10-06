// Voice: the page records with MediaRecorder and hands the bytes over; this
// module posts them to the 9router's OpenAI-compatible /audio/transcriptions
// and returns the text. The key stays in the Credential Manager, as for chat.
//
// The multipart body, the reply parsing and the error wording are pure
// functions so they can be tested without a server or a microphone.

use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

use crate::router;

pub const DEFAULT_MODEL: &str = "groq/whisper-large-v3";
/// OpenAI's own upload limit; a 60 s opus clip is a few hundred kB.
pub const MAX_AUDIO_BYTES: usize = 25 * 1024 * 1024;
const TIMEOUT: Duration = Duration::from_secs(60);

pub const NO_STT_HINT: &str = "Add a Groq or OpenAI key in 9router to enable voice.";

/// Recorder MIME type → file name the gateway can recognise by extension.
pub fn file_name_for(mime: &str) -> &'static str {
    let base = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    match base.as_str() {
        "audio/webm" | "video/webm" => "speech.webm",
        "audio/ogg" => "speech.ogg",
        "audio/wav" | "audio/x-wav" | "audio/wave" => "speech.wav",
        "audio/mp4" | "audio/m4a" | "audio/x-m4a" => "speech.m4a",
        "audio/mpeg" | "audio/mp3" => "speech.mp3",
        _ => "speech.webm",
    }
}

fn clean_mime(mime: &str) -> String {
    let m = mime.split(';').next().unwrap_or("").trim();
    if m.is_empty() || !m.starts_with("audio/") && !m.starts_with("video/") || m.chars().any(|c| c.is_control() || c == '"') {
        "audio/webm".into()
    } else {
        m.to_string()
    }
}

/// multipart/form-data with `file` and `model` (and `response_format=json`).
/// Returns (content-type header, body).
pub fn build_multipart(boundary: &str, model: &str, mime: &str, audio: &[u8]) -> (String, Vec<u8>) {
    let mut body = Vec::with_capacity(audio.len() + 512);
    let mut field = |name: &str, value: &str| {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    };
    field("model", model);
    field("response_format", "json");
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{}\"\r\nContent-Type: {}\r\n\r\n",
            file_name_for(mime),
            clean_mime(mime)
        )
        .as_bytes(),
    );
    body.extend_from_slice(audio);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

fn new_boundary() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("----coucou-voice-{nanos:x}-{:x}", std::process::id())
}

/// `{"text":"…"}` (OpenAI json), or a plain-text body. An `error` object in a
/// 200 is an error.
pub fn parse_transcription(body: &str) -> Result<String, String> {
    let trimmed = body.trim();
    if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
        if let Some(err) = v.get("error") {
            let detail = err
                .as_str()
                .or_else(|| err.get("message").and_then(Value::as_str))
                .unwrap_or("unknown error");
            return Err(map_error(200, detail));
        }
        return match v.get("text").and_then(Value::as_str) {
            Some(t) => Ok(t.trim().to_string()),
            None if v.is_string() => Ok(v.as_str().unwrap().trim().to_string()),
            None => Err("9router sent an unexpected transcription.".into()),
        };
    }
    if trimmed.starts_with('<') {
        return Err("9router sent an unexpected transcription.".into());
    }
    Ok(trimmed.to_string())
}

/// 9router's message → what the voice button shows. "No credentials for
/// provider" means the gateway has no speech-to-text key configured.
pub fn map_error(status: u16, detail: &str) -> String {
    let lower = detail.to_ascii_lowercase();
    if lower.contains("no credentials for provider") {
        return format!("9router has no key for this voice model ({}). {NO_STT_HINT}", detail.trim());
    }
    if status == 404 {
        return format!("This 9router has no speech-to-text endpoint (404). {NO_STT_HINT}");
    }
    if status == 0 {
        return detail.to_string();
    }
    let msg = router::error_message(status, &format!(r#"{{"error":{}}}"#, Value::String(detail.to_string())));
    if (400..500).contains(&status) && (lower.contains("model") || lower.contains("provider")) {
        format!("{msg}. Check the voice model in Settings.")
    } else {
        msg
    }
}

/// Non-2xx body → readable error.
pub fn error_from_body(status: u16, body: &str) -> String {
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| {
            let err = v.get("error")?;
            err.as_str()
                .or_else(|| err.get("message").and_then(Value::as_str))
                .map(str::to_string)
        })
        .unwrap_or_else(|| body.trim().chars().take(200).collect());
    map_error(status, &detail)
}

pub async fn transcribe(base: &str, model: &str, mime: &str, audio: Vec<u8>) -> Result<String, String> {
    if audio.is_empty() {
        return Err("Nothing was recorded.".into());
    }
    if audio.len() > MAX_AUDIO_BYTES {
        return Err("That recording is too long to transcribe.".into());
    }
    let base = router::normalize_base_url(base)?;
    let model = router::validate_model(model).map_err(|_| "Set a voice model in Settings.".to_string())?;
    let key = router::api_key()?;
    let (content_type, body) = build_multipart(&new_boundary(), &model, mime, &audio);
    let response = router::client(TIMEOUT)?
        .post(format!("{base}/audio/transcriptions"))
        .bearer_auth(&key)
        .header(reqwest::header::CONTENT_TYPE, content_type)
        .body(body)
        .send()
        .await
        .map_err(|e| router::network_error(e, TIMEOUT))?;
    let status = response.status();
    let text = response.text().await.map_err(|e| router::network_error(e, TIMEOUT))?;
    if !status.is_success() {
        return Err(error_from_body(status.as_u16(), &text));
    }
    parse_transcription(&text)
}

// ── Windows microphone privacy ────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MicStatus {
    pub blocked: bool,
    pub message: String,
}

pub const MIC_OFF: &str = "Microphone is off: Windows Settings → Privacy & security → Microphone.";

/// The three switches under Settings → Privacy & security → Microphone, as
/// read from CapabilityAccessManager\ConsentStore\microphone: the device-wide
/// one (HKLM), "Let apps access" (HKCU) and "Let desktop apps access"
/// (HKCU\…\NonPackaged). Only an explicit "Deny" blocks.
pub fn mic_status_from(device: Option<&str>, apps: Option<&str>, desktop_apps: Option<&str>) -> MicStatus {
    let denied = |v: Option<&str>| v.is_some_and(|v| v.eq_ignore_ascii_case("deny"));
    let which = if denied(device) {
        Some("Microphone access for this device")
    } else if denied(apps) {
        Some("Let apps access your microphone")
    } else if denied(desktop_apps) {
        Some("Let desktop apps access your microphone")
    } else {
        None
    };
    match which {
        Some(switch) => MicStatus { blocked: true, message: format!("{MIC_OFF} Turn on \"{switch}\".") },
        None => MicStatus { blocked: false, message: String::new() },
    }
}

#[cfg(windows)]
fn read_consent(hklm: bool, sub: &str) -> Option<String> {
    use windows::core::HSTRING;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};

    let root = if hklm { HKEY_LOCAL_MACHINE } else { HKEY_CURRENT_USER };
    let path = HSTRING::from(format!(
        r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone{sub}"
    ));
    let name = HSTRING::from("Value");
    let mut buf = [0u16; 64];
    let mut size = (buf.len() * 2) as u32;
    let rc = unsafe {
        RegGetValueW(root, &path, &name, RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr().cast()), Some(&mut size))
    };
    if rc.is_err() {
        return None;
    }
    let len = (size as usize / 2).saturating_sub(1).min(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]).trim_end_matches('\0').to_string())
}

pub fn mic_status() -> MicStatus {
    let device = read_consent(true, "");
    let apps = read_consent(false, "");
    let desktop = read_consent(false, r"\NonPackaged");
    mic_status_from(device.as_deref(), apps.as_deref(), desktop.as_deref())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multipart_body_has_model_and_file() {
        let (ct, body) = build_multipart("BND", "groq/whisper-large-v3", "audio/webm;codecs=opus", b"\x1aE\xdf\xa3");
        assert_eq!(ct, "multipart/form-data; boundary=BND");
        let mut want = Vec::new();
        want.extend_from_slice(b"--BND\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngroq/whisper-large-v3\r\n");
        want.extend_from_slice(b"--BND\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n");
        want.extend_from_slice(b"--BND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.webm\"\r\nContent-Type: audio/webm\r\n\r\n");
        want.extend_from_slice(b"\x1aE\xdf\xa3");
        want.extend_from_slice(b"\r\n--BND--\r\n");
        assert_eq!(body, want);
    }

    #[test]
    fn file_names_follow_the_recorder_type() {
        assert_eq!(file_name_for("audio/webm;codecs=opus"), "speech.webm");
        assert_eq!(file_name_for("audio/ogg; codecs=opus"), "speech.ogg");
        assert_eq!(file_name_for("audio/wav"), "speech.wav");
        assert_eq!(file_name_for("audio/mp4"), "speech.m4a");
        assert_eq!(file_name_for(""), "speech.webm");
        let (_, body) = build_multipart("B", "m", "text/html\"\r\nX: y", b"");
        assert!(String::from_utf8_lossy(&body).contains("Content-Type: audio/webm\r\n"));
    }

    #[test]
    fn transcriptions_are_parsed() {
        assert_eq!(parse_transcription(r#"{"text":"  Start a codex task  "}"#).unwrap(), "Start a codex task");
        assert_eq!(parse_transcription(r#"{"text":"","x_groq":{}}"#).unwrap(), "");
        assert_eq!(parse_transcription("hello there\n").unwrap(), "hello there");
        assert!(parse_transcription(r#"{"segments":[]}"#).is_err());
        assert!(parse_transcription("<html>bad gateway</html>").is_err());
        assert_eq!(
            parse_transcription(r#"{"error":{"message":"No credentials for provider: groq"}}"#).unwrap_err(),
            format!("9router has no key for this voice model (No credentials for provider: groq). {NO_STT_HINT}")
        );
    }

    #[test]
    fn errors_are_mapped() {
        assert_eq!(
            error_from_body(400, r#"{"error":{"message":"No credentials for provider: openai","type":"x"}}"#),
            format!("9router has no key for this voice model (No credentials for provider: openai). {NO_STT_HINT}")
        );
        assert_eq!(
            error_from_body(404, "Not Found"),
            format!("This 9router has no speech-to-text endpoint (404). {NO_STT_HINT}")
        );
        assert_eq!(
            error_from_body(401, r#"{"error":"API key required"}"#),
            "9router rejected the API key (401): API key required"
        );
        assert_eq!(
            error_from_body(400, r#"{"error":"Unknown model: foo"}"#),
            "9router error 400: Unknown model: foo. Check the voice model in Settings."
        );
        assert_eq!(error_from_body(502, "Bad Gateway"), "9router error 502: Bad Gateway");
    }

    #[test]
    fn microphone_privacy_switches() {
        assert!(!mic_status_from(None, None, None).blocked);
        assert!(!mic_status_from(Some("Allow"), Some("Allow"), Some("Allow")).blocked);
        let s = mic_status_from(Some("Deny"), Some("Deny"), Some("Allow"));
        assert!(s.blocked);
        assert!(s.message.starts_with(MIC_OFF));
        assert!(s.message.contains("for this device"));
        assert!(mic_status_from(Some("Allow"), Some("deny"), None).message.contains("Let apps access"));
        assert!(mic_status_from(None, None, Some("Deny")).message.contains("desktop apps"));
    }

    /// Reads the real registry switches (no microphone needed).
    #[test]
    #[ignore]
    fn real_mic_status() {
        println!("{:?}", mic_status());
    }

    /// One second of a 440 Hz tone, 16 kHz mono 16-bit PCM.
    fn tiny_wav() -> Vec<u8> {
        let rate = 16_000u32;
        let samples: Vec<i16> = (0..rate)
            .map(|i| ((i as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin() * 8000.0) as i16)
            .collect();
        let data_len = (samples.len() * 2) as u32;
        let mut w = Vec::new();
        w.extend_from_slice(b"RIFF");
        w.extend_from_slice(&(36 + data_len).to_le_bytes());
        w.extend_from_slice(b"WAVEfmt ");
        w.extend_from_slice(&16u32.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&1u16.to_le_bytes());
        w.extend_from_slice(&rate.to_le_bytes());
        w.extend_from_slice(&(rate * 2).to_le_bytes());
        w.extend_from_slice(&2u16.to_le_bytes());
        w.extend_from_slice(&16u16.to_le_bytes());
        w.extend_from_slice(b"data");
        w.extend_from_slice(&data_len.to_le_bytes());
        for s in samples {
            w.extend_from_slice(&s.to_le_bytes());
        }
        w
    }

    /// Real 9router: posts a tiny WAV with the saved base URL, the voice model
    /// (or COUCOU_STT_MODEL) and the key from the Credential Manager.
    /// Prints the outcome, never the key.
    /// `cargo test -p coucou voice::tests::real_router_transcription -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn real_router_transcription() {
        let settings = crate::settings::load();
        let base = if settings.router_base_url.trim().is_empty() {
            "https://hindsight.example.com/hindsight".to_string()
        } else {
            settings.router_base_url.clone()
        };
        let model = std::env::var("COUCOU_STT_MODEL").unwrap_or(settings.stt_model.clone());
        println!("base={base} model={model}");
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        match rt.block_on(transcribe(&base, &model, "audio/wav", tiny_wav())) {
            Ok(text) => println!("OK text={text:?}"),
            Err(err) => println!("ERR {err}"),
        }
    }
}
