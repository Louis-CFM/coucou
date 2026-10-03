// Images, video, speech and 3D models for models whose output isn't text,
// from any OpenAI-compatible provider (3D: Pollinations' native route).
//
// Same rules as the chat: the API key stays on this side and only ever goes to
// the provider's own host (result links on a CDN are fetched without it). The
// results land in local_dir()/media, and the webview can only read, copy or
// preview a file from that folder, named by its bare file name.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use crate::claude::{api_detail, friendly_error};
use crate::settings::ModelEntry;
use crate::{island, log, platform, roam};

/// Groq's Orpheus reads at most this many characters per request.
const ORPHEUS_MAX_INPUT: usize = 200;
/// Video jobs take minutes; past this one is given up on.
const VIDEO_TIMEOUT: Duration = Duration::from_secs(20 * 60);
const POLL_EVERY: Duration = Duration::from_secs(4);
/// Polls in a row that may fail (a network blip) before the job is given up on.
const POLL_RETRIES: u32 = 3;

/// The voices of Groq's canopylabs/orpheus-v1-english
/// (console.groq.com/docs/text-to-speech/orpheus).
const ORPHEUS_VOICES: [&str; 6] = ["autumn", "diana", "hannah", "austin", "daniel", "troy"];

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MediaFile {
    /// Bare file name in the media folder.
    pub name: String,
    /// "image", "video", "audio" or "3d".
    pub kind: String,
}

/// What a model most likely makes, from its id: "image", "video", "audio",
/// "3d" or "text". Only a first guess for the Settings form; the user can change it.
pub fn guess_output(model: &str) -> &'static str {
    let m = model.to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| m.contains(w));
    if has(&["whisper", "transcri", "speech-to-text", "scribe", "-stt"]) {
        "stt"
    } else if has(&["trellis", "rodin", "asset-harvester", "hunyuan3d", "tripo", "triposr", "sf3d", "3d"]) {
        "3d"
    } else if has(&["sora", "veo", "kling", "seedance", "hailuo", "runway", "wan2", "ltx-video", "video"]) {
        "video"
    } else if has(&["orpheus", "tts", "speech", "playai", "kokoro", "eleven"]) {
        "audio"
    } else if has(&[
        "dall-e", "gpt-image", "flux", "imagen", "stable-diffusion", "sdxl", "sd3", "seedream", "recraft",
        "ideogram", "image",
    ]) {
        "image"
    } else {
        "text"
    }
}

/// One generation with `entry`, whose `output` is "image", "video", "audio" or
/// "3d". Returns any text the model wrote alongside, and the saved files.
/// `source` is the picture an image-to-3D model works from. `progress` gets a
/// video job's percentage while it runs.
pub async fn generate(
    entry: &ModelEntry,
    key: &str,
    prompt: &str,
    source: Option<&Path>,
    progress: impl Fn(Option<f64>),
) -> Result<(String, Vec<MediaFile>), String> {
    let model = entry.model.trim();
    if model.is_empty() {
        return Err("This model has no model name. Fix it in Settings → Models.".into());
    }
    let base = entry.endpoint.trim().trim_end_matches('/');
    // The chat accepts the full chat URL as the endpoint; the other routes hang off the base.
    let base = base.strip_suffix("/chat/completions").unwrap_or(base);
    let kind = entry.output.as_str();
    let (text, blobs) = match kind {
        "image" => image(base, model, key, prompt).await?,
        "video" => (String::new(), vec![video(base, model, key, prompt, progress).await?]),
        "audio" => (String::new(), vec![speech(base, model, key, prompt, &entry.voice).await?]),
        "3d" => (String::new(), vec![model3d(base, model, key, prompt, source, &entry.detail).await?]),
        other => return Err(format!("Unknown output kind \"{other}\".")),
    };
    if blobs.is_empty() {
        return Err(format!("The provider answered, but sent no {kind}."));
    }
    let files = blobs.iter().enumerate().map(|(i, b)| save(kind, i, b)).collect::<Result<Vec<_>, _>>()?;
    Ok((text, files))
}

fn http(timeout_secs: u64) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .build()
        .map_err(|e| e.to_string())
}

/// Sends a request; a non-2xx answer becomes the provider's message in words.
async fn send(req: reqwest::RequestBuilder, model: &str) -> Result<reqwest::Response, String> {
    let response = req.send().await.map_err(|e| format!("Network error: {e}"))?;
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let text = response.text().await.unwrap_or_default();
    Err(friendly_error(status.as_u16(), &api_detail(&text), model))
}

async fn json_of(response: reqwest::Response) -> Result<Value, String> {
    let text = response.text().await.map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|_| format!("Unexpected answer: {}", text.chars().take(200).collect::<String>()))
}

// ── Images ────────────────────────────────────────────────────────────────────

/// Where an image is: inline bytes, or a link to fetch.
#[derive(Debug, PartialEq)]
enum Src {
    Bytes(Vec<u8>),
    Url(String),
}

/// OpenRouter makes images through the chat route; everyone else (OpenAI,
/// Together, Fireworks, xAI…) through /images/generations.
// ponytail: decided by host; add a per-model switch if another chat-route provider shows up.
fn uses_chat_route(base: &str) -> bool {
    host_of(base).is_some_and(|h| h == "openrouter.ai" || h.ends_with(".openrouter.ai"))
}

async fn image(base: &str, model: &str, key: &str, prompt: &str) -> Result<(String, Vec<Vec<u8>>), String> {
    // gpt-image models can take a couple of minutes at high quality.
    let client = http(240)?;
    let (text, srcs) = if uses_chat_route(base) {
        let body = json!({
            "model": model,
            "messages": [{ "role": "user", "content": prompt }],
            "modalities": ["image", "text"],
        });
        let v = json_of(send(client.post(format!("{base}/chat/completions")).bearer_auth(key).json(&body), model).await?).await?;
        chat_images(&v)
    } else {
        // No response_format: gpt-image rejects it and always answers b64_json;
        // dall-e answers a url by default. Both are handled.
        let body = json!({ "model": model, "prompt": prompt, "n": 1 });
        let v = json_of(send(client.post(format!("{base}/images/generations")).bearer_auth(key).json(&body), model).await?).await?;
        (String::new(), generation_images(&v))
    };
    let mut out = Vec::new();
    for src in srcs {
        out.push(match src {
            Src::Bytes(b) => b,
            // Signed CDN links: never with the key.
            Src::Url(url) => fetch(&client, &url, None, model).await?,
        });
    }
    Ok((text, out))
}

/// `/images/generations`: `data[].b64_json` or `data[].url`.
fn generation_images(v: &Value) -> Vec<Src> {
    v.get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|d| {
            if let Some(b) = d.get("b64_json").and_then(Value::as_str) {
                base64::engine::general_purpose::STANDARD.decode(b.trim()).ok().map(Src::Bytes)
            } else {
                d.get("url").and_then(Value::as_str).and_then(src_of)
            }
        })
        .collect()
}

/// OpenRouter's chat route: `message.images[].image_url.url` (data URLs), and
/// whatever text the model wrote.
fn chat_images(v: &Value) -> (String, Vec<Src>) {
    let message = v.pointer("/choices/0/message");
    let mut images: Vec<Src> = message
        .and_then(|m| m.get("images"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|i| i.pointer("/image_url/url").and_then(Value::as_str).and_then(src_of))
        .collect();
    // Some providers put the picture among the content parts instead.
    let text = match message.and_then(|m| m.get("content")) {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Array(parts)) => {
            let mut text = String::new();
            for part in parts {
                if let Some(src) = part.pointer("/image_url/url").and_then(Value::as_str).and_then(src_of) {
                    images.push(src);
                } else if let Some(t) = part.get("text").and_then(Value::as_str) {
                    text.push_str(t);
                }
            }
            text.trim().to_string()
        }
        _ => String::new(),
    };
    (text, images)
}

/// A data URL is decoded here; an http(s) link is fetched later.
fn src_of(url: &str) -> Option<Src> {
    if let Some(rest) = url.strip_prefix("data:") {
        let (head, data) = rest.split_once(',')?;
        if !head.ends_with(";base64") {
            return None;
        }
        return base64::engine::general_purpose::STANDARD.decode(data.trim()).ok().map(Src::Bytes);
    }
    (url.starts_with("https://") || url.starts_with("http://")).then(|| Src::Url(url.to_string()))
}

/// GETs a result link. `key` is only ever passed for the provider's own host;
/// reqwest also drops it on a redirect to another host.
async fn fetch(client: &reqwest::Client, url: &str, key: Option<&str>, model: &str) -> Result<Vec<u8>, String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("The provider sent an unusable result link.".into());
    }
    let mut req = client.get(url);
    if let Some(key) = key {
        req = req.bearer_auth(key);
    }
    let bytes = send(req, model).await?.bytes().await.map_err(|e| format!("Network error: {e}"))?;
    Ok(bytes.to_vec())
}

fn host_of(url: &str) -> Option<String> {
    reqwest::Url::parse(url).ok()?.host_str().map(str::to_lowercase)
}

/// Same scheme, host and port: the only links the key may go to.
fn same_origin(a: &str, b: &str) -> bool {
    match (reqwest::Url::parse(a), reqwest::Url::parse(b)) {
        (Ok(a), Ok(b)) => {
            a.scheme() == b.scheme()
                && a.host_str() == b.host_str()
                && a.port_or_known_default() == b.port_or_known_default()
        }
        _ => false,
    }
}

// ── Video ─────────────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq)]
enum Job {
    /// Queued or rendering, with the percentage when the provider gives one.
    Running(Option<f64>),
    /// Finished; a link to the file when the job carries one.
    Done(Option<String>),
    Failed(String),
}

/// A video job's state: OpenAI's `status` (queued, in_progress, completed,
/// failed) and `progress` (0–100), plus the words other providers use.
fn job_status(v: &Value) -> Job {
    let status = v.get("status").and_then(Value::as_str).unwrap_or("").to_lowercase();
    match status.as_str() {
        "completed" | "succeeded" | "success" | "done" => Job::Done(
            ["/url", "/video_url", "/output/url", "/result/url"]
                .iter()
                .find_map(|p| v.pointer(p).and_then(Value::as_str))
                .filter(|u| u.starts_with("https://") || u.starts_with("http://"))
                .map(str::to_string),
        ),
        "failed" | "error" | "cancelled" | "canceled" | "expired" => {
            let why = v
                .pointer("/error/message")
                .or_else(|| v.get("error"))
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or(status);
            Job::Failed(why)
        }
        _ => Job::Running(v.get("progress").and_then(Value::as_f64)),
    }
}

/// A multipart/form-data body of plain text fields (reqwest's multipart
/// feature isn't worth pulling in for two fields). Returns the content type
/// and the body; the boundary never appears in a value.
fn multipart(fields: &[(&str, &str)], seed: u128) -> (String, Vec<u8>) {
    let mut boundary = format!("----coucou{seed:x}");
    while fields.iter().any(|(k, v)| k.contains(&boundary) || v.contains(&boundary)) {
        boundary.push('x');
    }
    let mut body = String::new();
    for (name, value) in fields {
        body.push_str(&format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"));
    }
    body.push_str(&format!("--{boundary}--\r\n"));
    (format!("multipart/form-data; boundary={boundary}"), body.into_bytes())
}

/// OpenAI's Videos API: create the job, poll it, download the file.
async fn video(base: &str, model: &str, key: &str, prompt: &str, progress: impl Fn(Option<f64>)) -> Result<Vec<u8>, String> {
    let client = http(120)?;
    let (content_type, body) = multipart(&[("model", model), ("prompt", prompt)], now_nanos());
    let req = client.post(format!("{base}/videos")).bearer_auth(key).header("content-type", content_type).body(body);
    let mut job = json_of(send(req, model).await?).await?;
    let id = job.get("id").and_then(Value::as_str).unwrap_or("").to_string();
    // It goes into a URL path: only the characters ids are made of.
    if id.is_empty() || id.contains("..") || !id.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) {
        return Err("The provider didn't return a usable video job id.".into());
    }
    let started = Instant::now();
    let mut failures = 0;
    let link = loop {
        match job_status(&job) {
            Job::Done(link) => break link,
            Job::Failed(why) => return Err(format!("The video failed: {why}")),
            Job::Running(p) => progress(p),
        }
        if started.elapsed() > VIDEO_TIMEOUT {
            return Err("The video is taking too long; gave up after 20 minutes.".into());
        }
        tokio::time::sleep(POLL_EVERY).await;
        match send(client.get(format!("{base}/videos/{id}")).bearer_auth(key), model).await {
            Ok(r) => {
                job = json_of(r).await?;
                failures = 0;
            }
            Err(err) if failures < POLL_RETRIES => {
                failures += 1;
                log::line(format!("video poll failed ({failures}): {err}"));
            }
            Err(err) => return Err(err),
        }
    };
    progress(Some(100.0));
    // A big file over a slow link: no overall timeout on the download itself.
    let download = http(15 * 60)?;
    match link {
        Some(url) => {
            let key = same_origin(&url, base).then_some(key);
            fetch(&download, &url, key, model).await
        }
        None => fetch(&download, &format!("{base}/videos/{id}/content"), Some(key), model).await,
    }
}

// ── Speech ────────────────────────────────────────────────────────────────────

fn is_orpheus(model: &str) -> bool {
    model.to_lowercase().contains("orpheus")
}

/// The voice to ask for: the one picked in Settings, else the model's default
/// (Orpheus has its own six; OpenAI's TTS models start at "alloy").
fn voice_for(model: &str, picked: &str) -> String {
    let picked = picked.trim();
    if !picked.is_empty() {
        // Groq's voice ids are lowercase.
        return if is_orpheus(model) { picked.to_lowercase() } else { picked.to_string() };
    }
    if is_orpheus(model) { ORPHEUS_VOICES[5] } else { "alloy" }.to_string()
}

/// `POST /audio/speech` (Groq, OpenAI). WAV, the only format Orpheus makes and
/// one every TTS model there offers.
async fn speech(base: &str, model: &str, key: &str, text: &str, voice: &str) -> Result<Vec<u8>, String> {
    let chars = text.chars().count();
    if is_orpheus(model) && chars > ORPHEUS_MAX_INPUT {
        return Err(format!(
            "Orpheus reads at most {ORPHEUS_MAX_INPUT} characters at a time; this is {chars}. Try a shorter line."
        ));
    }
    let body = json!({ "model": model, "input": text, "voice": voice_for(model, voice), "response_format": "wav" });
    let response = send(http(120)?.post(format!("{base}/audio/speech")).bearer_auth(key).json(&body), model).await?;
    Ok(response.bytes().await.map_err(|e| format!("Network error: {e}"))?.to_vec())
}

// ── Speech to text ────────────────────────────────────────────────────────────

/// multipart/form-data with text fields and one file. The boundary is long and
/// random; a body that happens to contain it gets a longer one.
fn multipart_file(fields: &[(&str, &str)], file_field: &str, file_name: &str, mime: &str, bytes: &[u8], seed: u128) -> (String, Vec<u8>) {
    let mut boundary = format!("----coucou{seed:x}");
    while bytes.windows(boundary.len()).any(|w| w == boundary.as_bytes()) {
        boundary.push('x');
    }
    let mut body = Vec::new();
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{file_name}\"\r\nContent-Type: {mime}\r\n\r\n").as_bytes(),
    );
    body.extend_from_slice(bytes);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

/// `POST /audio/transcriptions` (Groq, OpenAI): the recording in, its text out.
pub async fn transcribe(entry: &ModelEntry, key: &str, audio: Vec<u8>, mime: &str) -> Result<String, String> {
    let model = entry.model.trim();
    if audio.is_empty() {
        return Err("Nothing was recorded.".into());
    }
    let base = entry.endpoint.trim().trim_end_matches('/');
    let base = base.strip_suffix("/chat/completions").unwrap_or(base);
    // The extension is how providers tell the format apart.
    let mime = mime.split(';').next().unwrap_or("audio/webm").trim();
    let ext = match mime {
        "audio/ogg" => "ogg",
        "audio/wav" | "audio/x-wav" => "wav",
        "audio/mp4" | "audio/m4a" => "m4a",
        "audio/mpeg" => "mp3",
        _ => "webm",
    };
    let (content_type, body) = multipart_file(
        &[("model", model), ("response_format", "json")],
        "file",
        &format!("speech.{ext}"),
        mime,
        &audio,
        now_nanos(),
    );
    let req = http(120)?.post(format!("{base}/audio/transcriptions")).bearer_auth(key).header("content-type", content_type).body(body);
    let v = json_of(send(req, model).await?).await?;
    Ok(v.get("text").and_then(Value::as_str).unwrap_or("").trim().to_string())
}

// ── 3D ────────────────────────────────────────────────────────────────────────

/// Models that turn a picture into 3D and ignore the words (TRELLIS 2, NVIDIA
/// Asset Harvester); text-to-3D ones (Rodin) can do without a picture.
fn needs_picture(model: &str) -> bool {
    let m = model.to_lowercase();
    m.contains("trellis") || m.contains("asset-harvester")
}

fn is_pollinations(url: &str) -> bool {
    host_of(url).is_some_and(|h| h == "pollinations.ai" || h.ends_with(".pollinations.ai"))
}

/// Pollinations' 3D route: `POST {root}/3d/{prompt}` with JSON `{model, image,
/// resolution}`. The answer is the file itself: GLB, or PLY for Gaussian-splat
/// models. It waits for the whole generation, so the timeout is long.
async fn model3d(base: &str, model: &str, key: &str, prompt: &str, source: Option<&Path>, detail: &str) -> Result<Vec<u8>, String> {
    let image = match source {
        Some(path) => Some(upload_picture(base, key, model, path).await?),
        None if needs_picture(model) => {
            return Err(format!(
                "{model} makes 3D from a picture: drop an image on the island, or make one with an image model first."
            ))
        }
        None => None,
    };
    // The OpenAI-compatible base ends in /v1; the 3D route hangs off the root.
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let mut url = reqwest::Url::parse(&format!("{root}/3d/")).map_err(|_| "This model's provider address isn't a valid URL.".to_string())?;
    // The prompt is a path segment (image-only models ignore it, but it's required).
    let words: String = prompt.trim().chars().take(300).collect();
    url.path_segments_mut()
        .map_err(|_| "This model's provider address isn't a valid URL.".to_string())?
        .pop_if_empty()
        .push(if words.is_empty() { "3d model" } else { &words });
    let mut body = json!({ "model": model });
    if let Some(image) = image {
        body["image"] = json!(image);
    }
    if model.to_lowercase().contains("trellis") {
        let detail = detail.trim().to_lowercase();
        body["resolution"] = json!(if ["low", "medium", "high"].contains(&detail.as_str()) { detail.as_str() } else { "low" });
    }
    let response = send(http(15 * 60)?.post(url).bearer_auth(key).json(&body), model).await?;
    Ok(response.bytes().await.map_err(|e| format!("Network error: {e}"))?.to_vec())
}

/// Image-to-3D models take the picture as a link, so it goes to Pollinations'
/// media store first (an unlisted link that expires after 30 days).
async fn upload_picture(base: &str, key: &str, model: &str, path: &Path) -> Result<String, String> {
    if !is_pollinations(base) {
        return Err("This model needs its picture as a link, and Coucou can only upload pictures to Pollinations.".into());
    }
    let bytes = std::fs::read(path).map_err(|_| "Couldn't read the picture.".to_string())?;
    let mime = match sniff(&bytes) {
        Some(("png", _)) => "image/png",
        Some(("jpg", _)) => "image/jpeg",
        Some(("webp", _)) => "image/webp",
        Some(("gif", _)) => "image/gif",
        _ => return Err("3D models work from a picture (PNG, JPEG, WebP or GIF).".into()),
    };
    let ext = mime.rsplit('/').next().unwrap_or("png");
    let req = http(120)?
        .post("https://media.pollinations.ai/upload")
        .bearer_auth(key)
        .header("content-type", mime)
        .header("x-file-name", format!("coucou.{ext}"))
        .body(bytes);
    let v = json_of(send(req, model).await?).await?;
    uploaded_url(&v).ok_or_else(|| "Pollinations didn't return a link for the picture.".to_string())
}

/// The link in an upload answer, if it really points at Pollinations' store.
fn uploaded_url(v: &Value) -> Option<String> {
    v.get("url")
        .and_then(Value::as_str)
        .filter(|u| u.starts_with("https://media.pollinations.ai/"))
        .map(str::to_string)
}

/// The latest image made in this session, for an image-to-3D model when no
/// picture was dropped.
static LAST_IMAGE: Mutex<Option<String>> = Mutex::new(None);

pub fn last_image() -> Option<PathBuf> {
    let name = LAST_IMAGE.lock().ok()?.clone()?;
    media_path(&name).ok()
}

// ── Files ─────────────────────────────────────────────────────────────────────

pub fn media_dir() -> PathBuf {
    platform::local_dir().join("media")
}

fn now_nanos() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}

/// File type from the first bytes: (extension, kind). The provider's word for
/// it isn't trusted, and an error page must never be saved as a picture.
fn sniff(b: &[u8]) -> Option<(&'static str, &'static str)> {
    let at = |i: usize, sig: &[u8]| b.get(i..i + sig.len()) == Some(sig);
    Some(if at(0, b"\x89PNG\r\n\x1a\n") {
        ("png", "image")
    } else if at(0, &[0xFF, 0xD8, 0xFF]) {
        ("jpg", "image")
    } else if at(0, b"GIF8") {
        ("gif", "image")
    } else if at(0, b"RIFF") && at(8, b"WEBP") {
        ("webp", "image")
    } else if at(0, b"RIFF") && at(8, b"WAVE") {
        ("wav", "audio")
    } else if at(4, b"ftyp") {
        if at(8, b"M4A ") {
            ("m4a", "audio")
        } else if at(8, b"avif") {
            ("avif", "image")
        } else {
            ("mp4", "video")
        }
    } else if at(0, &[0x1A, 0x45, 0xDF, 0xA3]) {
        ("webm", "video")
    } else if at(0, b"OggS") {
        ("ogg", "audio")
    } else if at(0, b"fLaC") {
        ("flac", "audio")
    } else if at(0, b"ID3") || (b.len() > 1 && b[0] == 0xFF && b[1] & 0xE0 == 0xE0) {
        ("mp3", "audio")
    } else if at(0, b"glTF") {
        ("glb", "3d")
    } else if at(0, b"ply\n") || at(0, b"ply\r\n") {
        ("ply", "3d")
    } else {
        return None;
    })
}

fn save(kind: &str, index: usize, bytes: &[u8]) -> Result<MediaFile, String> {
    let ext = match sniff(bytes) {
        Some((ext, k)) if k == kind => ext,
        _ => {
            let start = String::from_utf8_lossy(&bytes[..bytes.len().min(200)]).to_string();
            log::line(format!("media: expected {kind}, got {} bytes starting {start:?}", bytes.len()));
            return Err(format!("The provider sent something that isn't {kind}."));
        }
    };
    let dir = media_dir();
    platform::ensure_private_dir(&platform::local_dir()).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let name = format!("{kind}-{}-{index}.{ext}", now_nanos() / 1_000_000);
    std::fs::write(dir.join(&name), bytes).map_err(|e| format!("Couldn't save the {kind}: {e}"))?;
    if kind == "image" {
        if let Ok(mut last) = LAST_IMAGE.lock() {
            *last = Some(name.clone());
        }
    }
    Ok(MediaFile { name, kind: kind.to_string() })
}

/// A file the webview names: a bare name we could have written, nothing
/// path-like (no separators, `..`, drive letters or `:stream`).
fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 100
        && !name.starts_with('.')
        && !name.contains("..")
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

fn media_path(name: &str) -> Result<PathBuf, String> {
    let path = media_dir().join(name);
    // symlink_metadata: a link planted in the folder doesn't lead out of it.
    let is_file = std::fs::symlink_metadata(&path).map(|m| m.is_file()).unwrap_or(false);
    if valid_name(name) && is_file {
        Ok(path)
    } else {
        Err("No such media file.".into())
    }
}

/// A free name for `name` in `dir`: "name (2).ext" and so on if taken.
fn free_spot(dir: &std::path::Path, name: &str) -> PathBuf {
    let (stem, ext) = name.rsplit_once('.').unwrap_or((name, ""));
    let mut dest = dir.join(name);
    let mut i = 2;
    while dest.exists() && i < 1000 {
        dest = dir.join(format!("{stem} ({i}).{ext}"));
        i += 1;
    }
    dest
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn guess_model_output(model: String) -> String {
    guess_output(&model).to_string()
}

/// A generated file's bytes, for the page to show as a blob: URL.
#[tauri::command]
pub fn media_bytes(name: String) -> Result<tauri::ipc::Response, String> {
    let bytes = std::fs::read(media_path(&name)?).map_err(|e| e.to_string())?;
    Ok(tauri::ipc::Response::new(bytes))
}

/// Copies a generated file to the Downloads folder; returns where it went.
#[tauri::command]
pub fn media_download(name: String) -> Result<String, String> {
    let src = media_path(&name)?;
    let dir = dirs::download_dir().unwrap_or_else(|| platform::home_dir().join("Downloads"));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let dest = free_spot(&dir, &format!("coucou-{name}"));
    std::fs::copy(&src, &dest).map_err(|e| format!("Couldn't copy to Downloads: {e}"))?;
    Ok(dest.to_string_lossy().into_owned())
}

/// Full-screen preview. The island is a fixed 720×320 panel and a window made
/// after launch comes up blank (see create_settings_window), so the preview
/// borrows the roam overlay: already made at launch, covering a monitor,
/// transparent, and idle unless Mochi is out roaming.
#[tauri::command]
pub fn media_preview(app: AppHandle, name: String, kind: String) -> Result<(), String> {
    media_path(&name)?;
    let win = app.get_webview_window(roam::LABEL).ok_or("No preview window.")?;
    // Not while Mochi is out roaming on it (and not twice).
    if !roam::claim_overlay() {
        return Err("Mochi is busy on the screen right now.".into());
    }
    PREVIEWING.store(true, Ordering::SeqCst);
    let _ = app.emit_to(roam::LABEL, "preview-open", MediaFile { name, kind });
    show_overlay(&app, &win);
    Ok(())
}

/// Set while the overlay shows a preview, so a stray close can never end a roam.
static PREVIEWING: AtomicBool = AtomicBool::new(false);

#[tauri::command]
pub fn media_preview_close(app: AppHandle) {
    if !PREVIEWING.swap(false, Ordering::SeqCst) {
        return;
    }
    if let Some(win) = app.get_webview_window(roam::LABEL) {
        hide_overlay(&win);
    }
    roam::release_overlay();
}

#[cfg(windows)]
fn show_overlay(app: &AppHandle, win: &tauri::WebviewWindow) {
    // The island's monitor.
    let monitor = island::window(app)
        .and_then(|w| w.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());
    if let Some(m) = monitor {
        let _ = win.set_position(*m.position());
        let _ = win.set_size(*m.size());
    }
    // Unlike a roam, the preview takes clicks and the keyboard (Esc).
    platform::set_click_through(win, false);
    platform::set_activating(win, true);
    platform::set_memory_low(win, false);
    let _ = win.show();
    let _ = win.set_always_on_top(true);
    let _ = win.set_focus();
}

#[cfg(windows)]
fn hide_overlay(win: &tauri::WebviewWindow) {
    let _ = win.hide();
    platform::set_click_through(win, true);
    platform::set_activating(win, false);
    platform::set_memory_low(win, true);
}

#[cfg(target_os = "linux")]
fn show_overlay(app: &AppHandle, win: &tauri::WebviewWindow) {
    if let Some(isl) = island::window(app) {
        platform::set_roam_input(win, true);
        platform::show_roam_overlay(win, &isl);
    }
}

#[cfg(target_os = "linux")]
fn hide_overlay(win: &tauri::WebviewWindow) {
    platform::set_roam_input(win, false);
    platform::hide_roam_overlay(win);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_is_guessed_from_the_model_id() {
        for (id, kind) in [
            ("dall-e-3", "image"),
            ("gpt-image-1", "image"),
            ("black-forest-labs/FLUX.1-schnell", "image"),
            ("imagen-4.0-generate-001", "image"),
            ("google/gemini-2.5-flash-image-preview", "image"),
            ("sora-2", "video"),
            ("veo-3.0-generate-preview", "video"),
            ("kling-v2", "video"),
            ("canopylabs/orpheus-v1-english", "audio"),
            ("gpt-4o-mini-tts", "audio"),
            ("tts-1", "audio"),
            ("llama-3.3-70b-versatile", "text"),
            ("meta-llama/llama-4-scout-17b-16e-instruct", "text"),
            ("claude-opus-5", "text"),
            ("whisper-large-v3", "stt"),
        ] {
            assert_eq!(guess_output(id), kind, "{id}");
        }
    }

    #[test]
    fn images_api_answers_are_parsed() {
        let v = json!({ "data": [{ "b64_json": "iVBORw0KGgo=" }, { "url": "https://cdn.example/a.png?sig=1" }, { "url": "file:///etc/passwd" }] });
        assert_eq!(
            generation_images(&v),
            vec![Src::Bytes(b"\x89PNG\r\n\x1a\n".to_vec()), Src::Url("https://cdn.example/a.png?sig=1".into())]
        );
        assert!(generation_images(&json!({ "error": "x" })).is_empty());
    }

    #[test]
    fn transcription_models_and_body() {
        for id in ["whisper-large-v3-turbo", "distil-whisper-large-v3-en", "gpt-4o-transcribe"] {
            assert_eq!(guess_output(id), "stt", "{id}");
        }
        // Speech out stays speech out.
        assert_eq!(guess_output("canopylabs/orpheus-v1-english"), "audio");
        let (ct, body) = multipart_file(&[("model", "whisper")], "file", "speech.webm", "audio/webm", b"\x1aE\xdf\xa3abc", 7);
        let boundary = ct.split("boundary=").nth(1).unwrap();
        let text = String::from_utf8_lossy(&body);
        assert!(text.contains("name=\"model\"\r\n\r\nwhisper\r\n"));
        assert!(text.contains("filename=\"speech.webm\"\r\nContent-Type: audio/webm\r\n\r\n"));
        assert!(text.ends_with(&format!("--{boundary}--\r\n")));
        // A body containing the boundary gets a longer one.
        let (ct2, _) = multipart_file(&[], "file", "a", "audio/webm", b"------coucou7", 7);
        assert!(ct2.ends_with("boundary=----coucou7x"));
    }

    #[test]
    fn three_d_models_are_recognised() {
        for id in ["microsoft/trellis-2", "trellis-2-high", "hyper3d/rodin-2.5", "nvidia/asset-harvester"] {
            assert_eq!(guess_output(id), "3d", "{id}");
        }
        assert!(needs_picture("microsoft/trellis-2") && needs_picture("nvidia/asset-harvester"));
        assert!(!needs_picture("hyper3d/rodin-2.5"));
        assert_eq!(sniff(b"glTF\x02\0\0\0"), Some(("glb", "3d")));
        assert_eq!(sniff(b"ply\nformat binary_little_endian 1.0\n"), Some(("ply", "3d")));
        // An error page is never saved as a model.
        assert_eq!(sniff(b"{\"error\":{}}"), None);
    }

    #[test]
    fn only_pollinations_upload_links_are_used() {
        let ok = json!({ "id": "3f9c", "url": "https://media.pollinations.ai/3f9c", "contentType": "image/png" });
        assert_eq!(uploaded_url(&ok).as_deref(), Some("https://media.pollinations.ai/3f9c"));
        assert_eq!(uploaded_url(&json!({ "url": "https://evil.example/x" })), None);
        assert_eq!(uploaded_url(&json!({ "id": "x" })), None);
        assert!(is_pollinations("https://gen.pollinations.ai/v1") && !is_pollinations("https://api.groq.com/openai/v1"));
    }

    #[test]
    fn openrouter_chat_images_are_parsed() {
        let v = json!({ "choices": [{ "message": {
            "content": " Here you go ",
            "images": [{ "type": "image_url", "image_url": { "url": "data:image/png;base64,iVBORw0KGgo=" } }]
        } }] });
        let (text, images) = chat_images(&v);
        assert_eq!(text, "Here you go");
        assert_eq!(images, vec![Src::Bytes(b"\x89PNG\r\n\x1a\n".to_vec())]);
        // Text only (the model declined): no images, the words still come back.
        let (text, images) = chat_images(&json!({ "choices": [{ "message": { "content": "Can't." } }] }));
        assert_eq!((text.as_str(), images.len()), ("Can't.", 0));
        assert_eq!(src_of("data:image/png,notbase64"), None);
        // The picture among the content parts instead.
        let (text, images) = chat_images(&json!({ "choices": [{ "message": { "content": [
            { "type": "text", "text": "Done" },
            { "type": "image_url", "image_url": { "url": "https://cdn.example/a.png" } }
        ] } }] }));
        assert_eq!(text, "Done");
        assert_eq!(images, vec![Src::Url("https://cdn.example/a.png".into())]);
    }

    #[test]
    fn video_job_states() {
        assert_eq!(job_status(&json!({ "id": "v", "status": "queued", "progress": 0 })), Job::Running(Some(0.0)));
        assert_eq!(job_status(&json!({ "status": "in_progress", "progress": 42.5 })), Job::Running(Some(42.5)));
        assert_eq!(job_status(&json!({ "status": "in_progress" })), Job::Running(None));
        assert_eq!(job_status(&json!({ "status": "completed", "progress": 100 })), Job::Done(None));
        assert_eq!(
            job_status(&json!({ "status": "succeeded", "video_url": "https://cdn.x/v.mp4" })),
            Job::Done(Some("https://cdn.x/v.mp4".into()))
        );
        assert_eq!(
            job_status(&json!({ "status": "failed", "error": { "code": "moderation", "message": "Blocked by moderation" } })),
            Job::Failed("Blocked by moderation".into())
        );
        assert_eq!(job_status(&json!({ "status": "expired" })), Job::Failed("expired".into()));
    }

    #[test]
    fn multipart_body_is_well_formed() {
        let (ct, body) = multipart(&[("model", "sora-2"), ("prompt", "a cat\non a mat")], 0xab);
        assert_eq!(ct, "multipart/form-data; boundary=----coucouab");
        assert_eq!(
            String::from_utf8(body).unwrap(),
            "------coucouab\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nsora-2\r\n\
             ------coucouab\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\na cat\non a mat\r\n\
             ------coucouab--\r\n"
        );
        // A prompt that happens to hold the boundary gets a longer one.
        let (ct, _) = multipart(&[("prompt", "x ----coucouab y")], 0xab);
        assert_eq!(ct, "multipart/form-data; boundary=----coucouabx");
    }

    #[test]
    fn file_types_are_sniffed() {
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\n...."), Some(("png", "image")));
        assert_eq!(sniff(&[0xFF, 0xD8, 0xFF, 0xE0]), Some(("jpg", "image")));
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), Some(("webp", "image")));
        assert_eq!(sniff(b"RIFF\0\0\0\0WAVEfmt "), Some(("wav", "audio")));
        assert_eq!(sniff(b"\0\0\0\x18ftypmp42"), Some(("mp4", "video")));
        assert_eq!(sniff(b"\0\0\0\x18ftypisom"), Some(("mp4", "video")));
        assert_eq!(sniff(&[0x1A, 0x45, 0xDF, 0xA3, 0]), Some(("webm", "video")));
        assert_eq!(sniff(b"ID3\x04"), Some(("mp3", "audio")));
        assert_eq!(sniff(b"{\"error\":\"nope\"}"), None);
        assert_eq!(sniff(b""), None);
    }

    #[test]
    fn only_bare_media_names_are_accepted() {
        assert!(valid_name("image-1759000000000-0.png"));
        for bad in ["", "../secret.txt", "..", "a/b.png", "a\\b.png", "C:x.png", "x.png:ads", ".hidden", "a..png"] {
            assert!(!valid_name(bad), "{bad}");
        }
        assert!(media_path("../settings.json").is_err());
        assert!(media_path("no-such-file.png").is_err());
    }

    #[test]
    fn the_key_only_goes_to_the_providers_origin() {
        assert!(same_origin("https://api.openai.com/v1/videos/x/content", "https://api.openai.com/v1"));
        assert!(!same_origin("https://cdn.openai.com/v.mp4", "https://api.openai.com/v1"));
        assert!(!same_origin("http://api.openai.com/v1", "https://api.openai.com/v1"));
        assert!(!same_origin("https://api.openai.com:8443/x", "https://api.openai.com/v1"));
        assert!(!same_origin("not a url", "https://api.openai.com/v1"));
        assert!(uses_chat_route("https://openrouter.ai/api/v1"));
        assert!(!uses_chat_route("https://api.openai.com/v1"));
        assert!(!uses_chat_route("https://openrouter.ai.evil.example/v1"));
    }

    #[test]
    fn voices_default_per_model() {
        assert_eq!(voice_for("canopylabs/orpheus-v1-english", ""), "troy");
        assert_eq!(voice_for("canopylabs/orpheus-v1-english", "Hannah"), "hannah");
        assert_eq!(voice_for("gpt-4o-mini-tts", ""), "alloy");
        assert_eq!(voice_for("gpt-4o-mini-tts", "coral"), "coral");
    }

    #[test]
    fn downloads_never_overwrite() {
        let dir = std::env::temp_dir().join(format!("coucou-media-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.png"), b"x").unwrap();
        assert_eq!(free_spot(&dir, "a.png"), dir.join("a (2).png"));
        assert_eq!(free_spot(&dir, "b.png"), dir.join("b.png"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
