//! Explicit, continuous conversations. Capture is owned only while listening;
//! no audio device remains open during transcription, tools or spoken replies.
use super::{
    dialogue::{self, Command, Idle, Pet},
    VoiceView,
};
use crate::{
    flow::pill,
    speech::{self, audio},
};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

static SESSION: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);
static FINISH: AtomicBool = AtomicBool::new(false);
// An explicit session takes over from the hotword. After Super/timeout, the
// microphone stays closed until a new session or an explicit hotword preference.
static HOTWORD_SUSPENDED: AtomicBool = AtomicBool::new(false);
pub fn active() -> bool {
    SESSION.lock().unwrap().is_some()
}
pub fn suspend_hotword() -> bool {
    HOTWORD_SUSPENDED.load(Ordering::Relaxed)
}
pub fn allow_hotword() {
    HOTWORD_SUSPENDED.store(false, Ordering::Relaxed);
}

fn reserve(app: &AppHandle) -> Result<Arc<AtomicBool>, String> {
    if super::manual::active() { return Err(crate::i18n::t("The microphone is already in use.")); }
    let mut session = SESSION.lock().unwrap();
    if session.is_some() || pill::dictating(app) || crate::notes::is_recording(app) {
        return Err(crate::i18n::t("The microphone is already in use."));
    }
    if !speech::is_ready() {
        return Err(crate::i18n::t(
            "Download the voice model so Coucou can hear you.",
        ));
    }
    let stop = Arc::new(AtomicBool::new(false));
    *session = Some(stop.clone());
    HOTWORD_SUSPENDED.store(true, Ordering::Relaxed);
    if let Some(background) = super::RUNNING.lock().unwrap().take() {
        background.stop.store(true, Ordering::Relaxed);
    }
    speech::preload();
    Ok(stop)
}

fn finish(app: &AppHandle, stop: &Arc<AtomicBool>) {
    let mut session = SESSION.lock().unwrap();
    if session.as_ref().is_some_and(|s| Arc::ptr_eq(s, stop)) {
        *session = None;
        super::show(app, None);
    }
}

#[tauri::command]
pub fn voice_session_toggle(app: AppHandle) {
    toggle(&app);
}

pub fn toggle(app: &AppHandle) {
    if let Some(stop) = SESSION.lock().unwrap().as_ref() {
        stop.store(true, Ordering::Relaxed);
        super::cancel_speech(app);
        super::show(app, None);
        return;
    }
    if super::manual::active() { super::manual::cancel(app); return; }
    if pill::dictating(app) {
        crate::flow::voice_dictation(app, false);
        return;
    }
    let stop = match reserve(app) {
        Ok(stop) => stop,
        Err(error) => {
            pill::announce(app, "mic", "#FFB84D", error, None, 6);
            return;
        }
    };
    let (worker_app, worker_stop) = (app.clone(), stop.clone());
    if std::thread::Builder::new()
        .name("coucou-dialogue".into())
        .spawn(move || {
            let dictate = run(&worker_app, &worker_stop);
            finish(&worker_app, &worker_stop);
            if dictate && !worker_stop.load(Ordering::Relaxed) {
                crate::flow::voice_dictation(&worker_app, true);
            }
        })
        .is_err()
    {
        finish(app, &stop);
    }
}

pub fn cancel(app: &AppHandle) {
    if let Some(stop) = SESSION.lock().unwrap().as_ref() {
        stop.store(true, Ordering::Relaxed);
        super::cancel_speech(app);
        super::show(app, None);
    }
}

pub fn finish_capture() { if active() { FINISH.store(true, Ordering::Relaxed); } }

fn view(app: &AppHandle, phase: &str, heard: &str, answer: &str, pet: Option<Pet>) {
    super::show_for_pet(
        app,
        Some(VoiceView {
            phase: phase.into(),
            heard: heard.into(),
            answer: answer.into(),
        }),
        pet.map(Pet::pill),
    );
}

fn available(app: &AppHandle, pet: Pet) -> bool {
    match pet {
        Pet::Codex => crate::codex_chat::installed(),
        Pet::Gravity => crate::gravity_chat::executable().is_ok(),
        Pet::Claude | Pet::Gemini => crate::gravity_chat::executable().is_ok(),
        Pet::Ollama => super::local::config(&app.state::<crate::Shared>().settings.lock().unwrap()).is_some(),
    }
}

/// Returns one speech segment or None on stop/inactivity. Bounded queues and
/// VAD bound the audio retained in memory. No recording is saved on disk.
fn listen(app: &AppHandle, stop: &AtomicBool, idle: &mut Idle) -> Result<Option<Vec<f32>>, String> {
    let Some(_lease) = super::capture_lease(stop) else {
        return Ok(None);
    };
    let mic = crate::flow::get(app)
        .map(|f| f.store.lock().unwrap().prefs.mic.clone())
        .unwrap_or_default();
    let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<f32>>(8);
    let mut capture = audio::Capture::start(
        audio::Source::Mic((!mic.is_empty()).then_some(mic)),
        move |data| {
            let _ = tx.try_send(data.to_vec());
        },
    )
    .map_err(|_| {
        crate::i18n::t("Coucou can't hear you: the microphone is not allowed or not available.")
    })?;
    let mut vad = super::wake::Vad::default();
    FINISH.store(false, Ordering::Relaxed);
    let mut meter = audio::BandMeter::default();
    let segment = loop {
        if stop.load(Ordering::Relaxed)
            || idle.expired(Instant::now())
            || pill::dictating(app)
            || crate::notes::is_recording(app)
        {
            break None;
        }
        if FINISH.swap(false, Ordering::Relaxed) {
            if let Some(segment) = vad.feed(&vec![0.0; vad.hangover * super::wake::FRAME]).into_iter().next() { break Some(segment); }
        }
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(chunk) => {
                let segments = vad.feed(&chunk);
                if vad.in_speech() {
                    idle.touch(Instant::now());
                }
                meter.feed(&chunk);
                let _ = app.emit_to(pill::LABEL, "pill-bands", meter.levels);
                if let Some(segment) = segments.into_iter().next() {
                    break Some(segment);
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break None,
        }
    };
    capture.stop();
    Ok(segment)
}

fn run(app: &AppHandle, stop: &Arc<AtomicBool>) -> bool {
    let seconds = app
        .state::<crate::Shared>()
        .settings
        .lock()
        .unwrap()
        .voice_idle_seconds;
    let mut idle = Idle::new(Instant::now(), seconds);
    let mut selected = None;
    let mut brains = HashMap::<Pet, super::brain::Brain>::new();
    let mut answer = crate::i18n::t("Say a pet name, such as Codex or Gravity, or say dictation.");
    while !stop.load(Ordering::Relaxed) {
        view(
            app,
            "listening",
            selected.map(Pet::name).unwrap_or(""),
            &answer,
            selected,
        );
        let samples = match listen(app, stop, &mut idle) {
            Ok(Some(samples)) => samples,
            Ok(None) => break,
            Err(error) => {
                pill::announce(app, "mic", "#FF6B6B", error, None, 7);
                break;
            }
        };
        if stop.load(Ordering::Relaxed) {
            break;
        }
        view(app, "thinking", "", "", selected);
        let transcript = speech::transcribe(&samples)
            .map(|t| t.text)
            .unwrap_or_default();
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let aliases = app
            .state::<crate::Shared>()
            .settings
            .lock()
            .unwrap()
            .voice_pet_aliases
            .clone();
        let question = match dialogue::parse_with_aliases(&transcript, &aliases) {
            Command::Stop => break,
            Command::Dictate => return true,
            Command::Select(pet, question) => {
                if !available(app, pet) {
                    answer = crate::i18n::t("Connect this pet in Settings → Chat first.");
                    idle.touch(Instant::now());
                    continue;
                }
                selected = Some(pet);
                let _ = app.emit_to(crate::island::WINDOW_LABEL, "voice-pet", pet.provider());
                if question.is_empty() {
                    answer = pet.name().into();
                    idle.touch(Instant::now());
                    continue;
                }
                question
            }
            Command::Message(question) => question,
        };
        let Some(pet) = selected else {
            idle.touch(Instant::now());
            continue;
        };
        if question.is_empty() {
            idle.touch(Instant::now());
            continue;
        }
        view(app, "thinking", &format!("{} · {question}", pet.name()), "", Some(pet));
        let reply = brains.entry(pet).or_default().respond_as(
            app,
            &question,
            pet.provider(),
            Some(stop.clone()),
        );
        if stop.load(Ordering::Relaxed) {
            break;
        }
        answer = reply
            .map(|r| r.text)
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| crate::i18n::t("Connect this pet in Settings → Chat first."));
        view(
            app,
            "speaking",
            &format!("{} · {question}", pet.name()),
            &answer,
            Some(pet),
        );
        super::speak_stoppable(app, &answer, Some(stop), Some(pet.provider()));
        idle.touch(Instant::now());
    }
    false
}

/// Learn what local ASR writes for the user's pronunciation. Only the spelling
/// is persisted; microphone samples and the user's voice are never retained.
#[tauri::command]
pub async fn voice_learn_alias(app: AppHandle, provider: String) -> Result<String, String> {
    let pet = Pet::from_provider(&provider).ok_or_else(|| "Unknown pet.".to_string())?;
    let stop = reserve(&app)?;
    tauri::async_runtime::spawn_blocking(move || {
        view(&app, "listening", pet.name(), &crate::i18n::t("Say only this pet's name."), Some(pet));
        let result = (|| {
            let samples = listen(&app, &stop, &mut Idle::new(Instant::now(), 20))?.ok_or_else(|| crate::i18n::t("No speech detected. Check your microphone."))?;
            let spelling = speech::transcribe(&samples).map(|t| super::wake::normalize(&t.text)).filter(|s| !s.is_empty() && s.len() <= 80)
                .ok_or_else(|| crate::i18n::t("No speech detected. Check your microphone."))?;
            if stop.load(Ordering::Relaxed) { return Err(crate::i18n::t("Cancelled")); }
            let shared = app.state::<crate::Shared>();
            let mut settings = shared.settings.lock().unwrap();
            let mut candidate = settings.voice_pet_aliases.clone();
            candidate.entry(provider.clone()).or_default().push(spelling.clone());
            if !matches!(dialogue::parse_with_aliases(&spelling, &candidate), Command::Select(selected, ref question) if selected == pet && question.is_empty()) {
                return Err(crate::i18n::t("This name already selects another pet. Try a different name."));
            }
            let aliases = settings.voice_pet_aliases.entry(provider.clone()).or_default();
            if !aliases.contains(&spelling) {
                if aliases.len() >= 20 { aliases.remove(0); }
                aliases.push(spelling.clone());
            }
            crate::settings::save(&settings).map_err(|e| e.to_string())?;
            let _ = app.emit("settings-changed", settings.clone());
            Ok(spelling)
        })();
        finish(&app, &stop);
        result
    }).await.map_err(|e| e.to_string())?
}
