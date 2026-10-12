// Voice: say "Maki", then what you want. Windows only.
//
// Two Windows speech recognisers, one after the other, never both at once:
// - The wake listener runs on the device (the OneCore speech engine of the
//   chosen language) with a tiny grammar: the wake word and its "hey" / "ok"
//   forms. Nothing leaves the PC while it waits.
// - Once it hears the wake word, one dictation turn (Microsoft's online speech
//   service — Settings → Privacy → Speech → Online speech recognition) takes
//   the command, with the words so far streamed to the island, and ends on a
//   pause. Then the wake listener comes back.
//
// No audio is ever written anywhere, and transcripts are never logged. What
// the command means and what Coucou does about it is the page's job
// (src/voice/), which can't approve anything (CLAUDE.md).

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex, OnceLock};
use std::time::Duration;

use tauri::{AppHandle, Emitter};
use windows::core::HSTRING;
use windows_collections::IIterable;
use windows::Foundation::{TimeSpan, TypedEventHandler};
use windows::Globalization::Language;
use windows::Media::SpeechRecognition::{
    SpeechContinuousRecognitionResultGeneratedEventArgs, SpeechContinuousRecognitionSession,
    SpeechRecognitionConfidence, SpeechRecognitionHypothesisGeneratedEventArgs, SpeechRecognitionListConstraint,
    SpeechRecognitionResultStatus, SpeechRecognitionScenario, SpeechRecognitionTopicConstraint, SpeechRecognizer,
};

static APP: OnceLock<AppHandle> = OnceLock::new();
static ON: AtomicBool = AtomicBool::new(false);
/// Bumped by every settings change: an old listener sees it and stops.
static GENERATION: AtomicU64 = AtomicU64::new(0);
static CONFIG: LazyLock<Mutex<Config>> = LazyLock::new(Default::default);
/// The island asked to listen now (its mic button), without the wake word.
static ASK: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Default)]
struct Config {
    wake_word: String,
    language: String,
}

fn emit<S: serde::Serialize + Clone>(event: &str, payload: S) {
    if let Some(app) = APP.get() {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, event, payload);
    }
}

/// The phrases the wake listener knows: "maki", "hey maki", "ok maki"…
pub fn wake_phrases(word: &str) -> Vec<String> {
    let w = word.trim().to_lowercase();
    let w = if w.is_empty() { "maki".to_string() } else { w };
    ["", "hey ", "ok ", "okay ", "hi "].iter().map(|p| format!("{p}{w}")).collect()
}

fn span(ms: i64) -> TimeSpan {
    TimeSpan { Duration: ms * 10_000 }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

pub fn start(app: &AppHandle, on: bool, wake_word: &str, language: &str) {
    let _ = APP.set(app.clone());
    apply(on, wake_word, language);
}

/// Settings saved: the listener restarts with the new word or language, or stops.
pub fn apply(on: bool, wake_word: &str, language: &str) {
    *CONFIG.lock().unwrap() = Config { wake_word: wake_word.to_string(), language: language.to_string() };
    ON.store(on, Ordering::SeqCst);
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if on {
        let _ = std::thread::Builder::new().name("coucou-voice".into()).spawn(move || {
            // Windows refuses until online speech recognition is on (0x80045509,
            // "speech privacy policy not accepted"): try again now and then, so
            // turning it on is all it takes.
            let mut told = false;
            while current(generation) {
                match run(generation) {
                    Ok(()) => break,
                    Err(e) => {
                        if !told {
                            crate::log::line(format!("voice: {e}"));
                            emit("voice-state", "needs-online");
                            told = true;
                        }
                        for _ in 0..200 {
                            if !current(generation) {
                                return;
                            }
                            std::thread::sleep(Duration::from_millis(100));
                        }
                    }
                }
            }
        });
    } else {
        emit("voice-state", "off");
    }
}

fn current(generation: u64) -> bool {
    ON.load(Ordering::SeqCst) && GENERATION.load(Ordering::SeqCst) == generation
}

fn recognizer(language: &str) -> windows::core::Result<SpeechRecognizer> {
    if language.is_empty() {
        return SpeechRecognizer::new();
    }
    match Language::CreateLanguage(&HSTRING::from(language)) {
        Ok(lang) => SpeechRecognizer::Create(&lang).or_else(|_| SpeechRecognizer::new()),
        Err(_) => SpeechRecognizer::new(),
    }
}

fn run(generation: u64) -> windows::core::Result<()> {
    let config = CONFIG.lock().unwrap().clone();
    crate::log::line("voice: listening for the wake word");
    emit("voice-state", "waiting");
    while current(generation) {
        let heard = wait_for_wake(&config, generation)?;
        if !current(generation) {
            break;
        }
        if heard {
            command_turn(&config)?;
        }
    }
    Ok(())
}

/// Blocks until the wake word (true), an island request (true) or a settings
/// change (false). On the device: a list grammar, nothing sent anywhere.
fn wait_for_wake(config: &Config, generation: u64) -> windows::core::Result<bool> {
    let rec = recognizer(&config.language)?;
    let phrases: Vec<HSTRING> = wake_phrases(&config.wake_word).iter().map(HSTRING::from).collect();
    let list = SpeechRecognitionListConstraint::Create(&IIterable::<HSTRING>::from(phrases))?;
    rec.Constraints()?.Append(&list)?;
    let compiled = rec.CompileConstraintsAsync()?.get()?;
    if compiled.Status()? != SpeechRecognitionResultStatus::Success {
        crate::log::line(format!("voice: wake grammar didn't compile ({:?})", compiled.Status()?));
        return Err(windows::core::Error::from_hresult(windows::core::HRESULT(-1)));
    }
    let woke = std::sync::Arc::new(AtomicBool::new(false));
    let w = woke.clone();
    let session: SpeechContinuousRecognitionSession = rec.ContinuousRecognitionSession()?;
    session.ResultGenerated(&TypedEventHandler::<SpeechContinuousRecognitionSession, SpeechContinuousRecognitionResultGeneratedEventArgs>::new(
        move |_, args| {
            if let Some(args) = args.as_ref() {
                let r = args.Result()?;
                let sure = matches!(r.Confidence()?, SpeechRecognitionConfidence::High | SpeechRecognitionConfidence::Medium);
                if sure && r.Status()? == SpeechRecognitionResultStatus::Success {
                    w.store(true, Ordering::SeqCst);
                }
            }
            Ok(())
        },
    ))?;
    session.StartAsync()?.get()?;
    let asked = loop {
        if woke.load(Ordering::SeqCst) {
            break true;
        }
        if ASK.swap(false, Ordering::SeqCst) {
            break true;
        }
        if !current(generation) {
            break false;
        }
        std::thread::sleep(Duration::from_millis(80));
    };
    let _ = session.StopAsync().and_then(|a| a.get());
    // Let go of the microphone before the command's recogniser takes it: two
    // recognisers on one mic make the second one end at once ("unknown").
    let _ = rec.Close();
    drop(rec);
    if asked {
        crate::log::line("voice: woke");
        std::thread::sleep(Duration::from_millis(250));
    }
    Ok(asked)
}

/// One command: dictation until a pause, the words so far sent as they come.
fn command_turn(config: &Config) -> windows::core::Result<()> {
    emit("voice-state", "listening");
    let rec = recognizer(&config.language)?;
    let topic = SpeechRecognitionTopicConstraint::Create(SpeechRecognitionScenario::Dictation, &HSTRING::new())?;
    rec.Constraints()?.Append(&topic)?;
    let compiled = rec.CompileConstraintsAsync()?.get()?;
    if compiled.Status()? != SpeechRecognitionResultStatus::Success {
        // Usually: online speech recognition is off in Windows' privacy settings.
        crate::log::line(format!("voice: dictation unavailable ({:?})", compiled.Status()?));
        emit("voice-state", "needs-online");
        std::thread::sleep(Duration::from_millis(1500));
        emit("voice-state", "waiting");
        return Ok(());
    }
    let timeouts = rec.Timeouts()?;
    timeouts.SetInitialSilenceTimeout(span(5000))?;
    timeouts.SetEndSilenceTimeout(span(1200))?;
    timeouts.SetBabbleTimeout(span(15000))?;
    rec.HypothesisGenerated(&TypedEventHandler::<SpeechRecognizer, SpeechRecognitionHypothesisGeneratedEventArgs>::new(|_, args| {
        if let Some(args) = args.as_ref() {
            let text = args.Hypothesis()?.Text()?.to_string();
            emit("voice-partial", text);
        }
        Ok(())
    }))?;
    let result = rec.RecognizeAsync()?.get();
    let _ = rec.Close();
    match result {
        Ok(r) if r.Status()? == SpeechRecognitionResultStatus::Success => {
            let text = r.Text()?.to_string();
            // That something was heard, never what.
            crate::log::line("voice: command heard");
            emit("voice-command", text);
        }
        Ok(r) => {
            crate::log::line(format!("voice: no command ({:?})", r.Status()?));
            emit("voice-command", String::new());
        }
        Err(e) => {
            crate::log::line(format!("voice: dictation failed ({e})"));
            emit("voice-state", "needs-online");
        }
    }
    emit("voice-state", "waiting");
    Ok(())
}

/// The island's mic button: listen for a command now, without the wake word.
#[tauri::command]
pub fn voice_listen_now() -> bool {
    if !ON.load(Ordering::SeqCst) {
        return false;
    }
    ASK.store(true, Ordering::SeqCst);
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wake_word_comes_with_its_greetings() {
        assert_eq!(wake_phrases("Maki"), ["maki", "hey maki", "ok maki", "okay maki", "hi maki"]);
        assert_eq!(wake_phrases(" ")[0], "maki");
    }
}
