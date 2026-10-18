//! One voice turn, explicitly started by the user. Close capture before ASR,
//! inference and speech so Bluetooth can return to stereo while answering.
use std::sync::{Arc, Mutex, OnceLock, atomic::{AtomicBool, Ordering}};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};

use crate::{flow::pill, speech::{self, audio}};
use super::VoiceView;

struct Turn { stop: Arc<AtomicBool>, finish: Arc<AtomicBool> }
static TURN: Mutex<Option<Turn>> = Mutex::new(None);

pub fn active() -> bool { TURN.lock().unwrap().is_some() }
pub fn cancel(app: &AppHandle) {
    if let Some(turn) = TURN.lock().unwrap().as_ref() { turn.stop.store(true, Ordering::Relaxed); }
    super::cancel_speech(app);
}
pub fn finish() {
    if let Some(turn) = TURN.lock().unwrap().as_ref() { turn.finish.store(true, Ordering::Relaxed); }
}

pub fn toggle(app: &AppHandle) {
    crate::log::line("voice: manual turn requested");
    let mut turn = TURN.lock().unwrap();
    if let Some(current) = turn.as_ref() {
        current.stop.store(true, Ordering::Relaxed);
        super::cancel_speech(app);
        return;
    }
    if !super::requirements_met(app) {
        pill::announce(app, "mic", "#FF6B6B", crate::i18n::t("Choose a local Ollama model or configure Claude, and download the voice model first."), None, 7);
        return;
    }
    if pill::dictating(app) || crate::notes::is_recording(app) { return; }
    // The explicit voice turn temporarily takes the microphone from hotword
    // listening; sync starts it again only if that preference remains enabled.
    if let Some(background) = super::RUNNING.lock().unwrap().take() { background.stop.store(true, Ordering::Relaxed); }
    let stop = Arc::new(AtomicBool::new(false));
    let finish = Arc::new(AtomicBool::new(false));
    *turn = Some(Turn { stop: stop.clone(), finish: finish.clone() });
    let app = app.clone();
    if std::thread::Builder::new().name("coucou-voice-turn".into()).spawn(move || {
        run(&app, &stop, &finish);
        super::show(&app, None);
        let mut current = TURN.lock().unwrap();
        if current.as_ref().is_some_and(|t| Arc::ptr_eq(&t.stop, &stop)) { *current = None; }
        drop(current);
        super::sync(&app);
    }).is_err() { *turn = None; }
}

fn wait(stop: &AtomicBool, duration: Duration) {
    let until = Instant::now() + duration;
    while !stop.load(Ordering::Relaxed) && Instant::now() < until { std::thread::sleep(Duration::from_millis(50)); }
}

fn run(app: &AppHandle, stop: &AtomicBool, finish: &AtomicBool) {
    let mic = crate::flow::get(app).map(|f| f.store.lock().unwrap().prefs.mic.clone()).unwrap_or_default();
    let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<f32>>(8);
    let source = audio::Source::Mic(if mic.is_empty() { None } else { Some(mic) });
    let mut capture = match audio::Capture::start(source, move |data| { let _ = tx.try_send(data.to_vec()); }) {
        Ok(c) => c,
        Err(_) => {
            pill::announce(app, "mic", "#FF6B6B", crate::i18n::t("Coucou can't hear you: the microphone is not allowed or not available."), None, 7);
            return;
        }
    };
    crate::log::line("voice: microphone open");
    super::show(app, Some(VoiceView { phase: "listening".into(), heard: String::new(), answer: String::new() }));
    let mut vad = super::wake::Vad::default();
    let mut meter = audio::BandMeter::default();
    let mut samples = Vec::new();
    let started = Instant::now();
    while !stop.load(Ordering::Relaxed) && !finish.load(Ordering::Relaxed) && started.elapsed() < Duration::from_secs(20) {
        if pill::dictating(app) || crate::notes::is_recording(app) { stop.store(true, Ordering::Relaxed); break; }
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(chunk) => {
                let count = chunk.len().min((speech::SAMPLE_RATE as usize * 20).saturating_sub(samples.len()));
                samples.extend_from_slice(&chunk[..count]);
                meter.feed(&chunk);
                let _ = app.emit_to(pill::LABEL, "pill-bands", meter.levels);
                if !vad.feed(&chunk).is_empty() || samples.len() >= speech::SAMPLE_RATE as usize * 20 { break; }
            },
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {},
        }
    }
    capture.stop();
    // No audio device remains open during a potentially slow model call.
    drop(capture);
    crate::log::line(format!("voice: microphone closed after {:?}; {} samples", started.elapsed(), samples.len()));
    if stop.load(Ordering::Relaxed) { return; }
    let peak = samples.iter().fold(0.0_f32, |v, s| v.max(s.abs()));
    if samples.len() < speech::SAMPLE_RATE as usize / 3 || peak < 0.004 {
        pill::announce(app, "mic", "#FFB84D", crate::i18n::t("No speech detected. Check your microphone."), None, 6);
        return;
    }
    super::show(app, Some(VoiceView { phase: "thinking".into(), heard: String::new(), answer: String::new() }));
    let Some(transcript) = speech::transcribe(&samples) else { return; };
    drop(samples);
    let question = transcript.text.trim();
    crate::log::line(format!("voice: recognized {} words", crate::flow::text::word_count(question)));
    if question.is_empty() || stop.load(Ordering::Relaxed) { return; }
    super::show(app, Some(VoiceView { phase: "thinking".into(), heard: question.into(), answer: String::new() }));
    static BRAIN: OnceLock<Mutex<super::brain::Brain>> = OnceLock::new();
    let reply = BRAIN.get_or_init(|| Mutex::new(super::brain::Brain::default())).lock().unwrap().respond(app, question, stop);
    if stop.load(Ordering::Relaxed) { return; }
    crate::log::line(format!("voice: local answer ready={}; elapsed={:?}", reply.is_some(), started.elapsed()));
    let language = reply.as_ref().and_then(|r| r.language.clone());
    let answer = reply.map(|r| r.text).filter(|s| !s.is_empty()).unwrap_or_else(|| crate::i18n::t("Coucou couldn't answer: check the selected voice provider."));
    super::show(app, Some(VoiceView { phase: "speaking".into(), heard: question.into(), answer: answer.clone() }));
    super::speak(app, &answer, Some(stop), language.as_deref());
    crate::log::line("voice: speech finished");
    wait(stop, Duration::from_secs(5));
}
