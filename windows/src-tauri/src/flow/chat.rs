// The chat's microphone — the Windows side of MacDictation.swift's use in the
// island's prompt: dictate instead of typing. The words come from Flow's own
// on-device model and land in the chat field, never pasted elsewhere; the
// user's dictionary and replacements apply, as in a Flow dictation.

use std::sync::{Arc, Mutex};
use std::time::Instant;

use tauri::AppHandle;

use crate::i18n::t;
use crate::speech::{self, audio};

struct Recording {
    capture: audio::Capture,
    take: Arc<Mutex<audio::Take>>,
    started: Instant,
}

static RECORDING: Mutex<Option<Recording>> = Mutex::new(None);

/// Opens the microphone (Flow's choice of microphone). Err: why it can't, in a sentence.
#[tauri::command]
pub fn chat_dictate_start(app: AppHandle) -> Result<(), String> {
    if !speech::is_ready() {
        return Err(t("Download the voice model first, in Coucou → Settings → Recognition."));
    }
    let mut slot = RECORDING.lock().unwrap();
    if slot.is_some() {
        return Ok(());
    }
    let mic = super::get(&app).map(|f| f.store.lock().unwrap().prefs.mic.clone()).unwrap_or_default();
    let take = Arc::new(Mutex::new(audio::Take::default()));
    let sink = take.clone();
    let capture = audio::Capture::start(audio::Source::Mic(if mic.is_empty() { None } else { Some(mic) }), move |samples| {
        let mut t = sink.lock().unwrap();
        // Five minutes at most: a microphone left on by mistake stops growing.
        if t.samples.len() < 16_000 * 300 {
            t.samples.extend_from_slice(samples);
        }
        t.peak = samples.iter().fold(t.peak, |m, &s| m.max(s.abs()));
    })
    .map_err(|err| {
        crate::log::line(format!("chat dictation: microphone: {err}"));
        t("Coucou can't hear you: the microphone is not allowed or not available.")
    })?;
    *slot = Some(Recording { capture, take, started: Instant::now() });
    Ok(())
}

/// Stops listening and returns what was said ("" for silence or a slip of the finger).
#[tauri::command]
pub async fn chat_dictate_stop(app: AppHandle) -> String {
    let Some(mut rec) = RECORDING.lock().unwrap().take() else { return String::new() };
    rec.capture.stop();
    let (samples, peak) = {
        let mut take = rec.take.lock().unwrap();
        (std::mem::take(&mut take.samples), take.peak)
    };
    if samples.len() < 16_000 / 4 || peak < 0.004 || rec.started.elapsed().as_millis() < 250 {
        return String::new();
    }
    let flow = super::get(&app);
    tauri::async_runtime::spawn_blocking(move || {
        let raw = speech::transcribe(&samples).map(|tr| tr.text.trim().to_string()).unwrap_or_default();
        if raw.is_empty() {
            return String::new();
        }
        match flow {
            Some(flow) => {
                let prepared = flow.store.lock().unwrap().prepare(&raw);
                super::text::finish(&prepared.text, &prepared.snippets)
            }
            None => raw,
        }
    })
    .await
    .unwrap_or_default()
}

/// The chat closed while listening: the microphone goes off, the words are dropped.
#[tauri::command]
pub fn chat_dictate_cancel() {
    if let Some(mut rec) = RECORDING.lock().unwrap().take() {
        rec.capture.stop();
    }
}
