// Voice: "Maki, pause the music". Windows only.
//
// Everything runs on the device, on Windows' own speech engine with a list of
// phrases: the wake word alone, the wake word followed by a command ("maki
// next song"), and — after the wake word alone — the commands by themselves.
// The page (src/core/intents.ts voicePhrases) hands over that command list;
// a phrase the list doesn't hold is never heard, so nothing else is
// transcribed and nothing is sent anywhere. (Windows' online dictation, the
// only free-form recogniser, ends every turn empty for a desktop app without
// a package identity: it was tried.)
//
// No audio is ever written anywhere, and transcripts are never logged. What
// a command means and what Coucou does about it is the page's job
// (src/voice/), which can't approve anything (CLAUDE.md).

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex, OnceLock};
use std::time::Duration;

use tauri::{AppHandle, Emitter};
use windows::core::HSTRING;
use windows::Foundation::TypedEventHandler;
use windows::Globalization::Language;
use windows::Media::SpeechRecognition::{
    SpeechContinuousRecognitionResultGeneratedEventArgs, SpeechContinuousRecognitionSession,
    SpeechRecognitionConfidence, SpeechRecognitionListConstraint, SpeechRecognitionResultStatus, SpeechRecognizer,
};
use windows_collections::IIterable;

static APP: OnceLock<AppHandle> = OnceLock::new();
static ON: AtomicBool = AtomicBool::new(false);
/// Bumped by every settings or phrase change: an old listener sees it and stops.
static GENERATION: AtomicU64 = AtomicU64::new(0);
static CONFIG: LazyLock<Mutex<Config>> = LazyLock::new(Default::default);
/// The island asked to listen now (its mic button), without the wake word.
static ASK: AtomicBool = AtomicBool::new(false);
/// Maki talks through the ElevenLabs agent: the wake word opens a conversation.
static CONVERSE: AtomicBool = AtomicBool::new(false);
/// A conversation is on: the mic is the page's until it ends.
static TALKING: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Default)]
struct Config {
    wake_word: String,
    language: String,
    /// The commands the page understands, lower case.
    commands: Vec<String>,
}

pub(crate) fn emit<S: serde::Serialize + Clone>(event: &str, payload: S) {
    if let Some(app) = APP.get() {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, event, payload);
    }
}

fn word(w: &str) -> String {
    let w = w.trim().to_lowercase();
    if w.is_empty() { "maki".to_string() } else { w }
}

/// The wake word with its greetings: "maki", "hey maki", "ok maki"…
pub fn wake_phrases(wake: &str) -> Vec<String> {
    let w = word(wake);
    ["", "hey ", "ok ", "okay ", "hi "].iter().map(|p| format!("{p}{w}")).collect()
}

/// What the listener waits for: the wake word alone, or with a command.
pub fn wake_grammar(wake: &str, commands: &[String]) -> Vec<String> {
    let w = word(wake);
    let mut all = wake_phrases(wake);
    for c in commands {
        all.push(format!("{w} {c}"));
        all.push(format!("hey {w} {c}"));
    }
    all
}

/// "hey maki next song" → Some("next song"); "maki" → Some(""); else None.
pub fn after_wake(heard: &str, wake: &str) -> Option<String> {
    let h = heard.trim().to_lowercase();
    let w = word(wake);
    let rest = ["hey ", "ok ", "okay ", "hi ", ""].iter().find_map(|p| h.strip_prefix(&format!("{p}{w}")))?;
    Some(rest.trim().to_string())
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

pub fn start(app: &AppHandle, on: bool, wake_word: &str, language: &str) {
    let _ = APP.set(app.clone());
    apply(on, wake_word, language);
}

/// Settings saved: the listener restarts with the new word or language, or stops.
pub fn apply(on: bool, wake_word: &str, language: &str) {
    {
        let mut c = CONFIG.lock().unwrap();
        c.wake_word = wake_word.to_string();
        c.language = language.to_string();
    }
    ON.store(on, Ordering::SeqCst);
    restart();
}

fn restart() {
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if !ON.load(Ordering::SeqCst) {
        emit("voice-state", "off");
        return;
    }
    let _ = std::thread::Builder::new().name("coucou-voice".into()).spawn(move || {
        let mut told = false;
        while current(generation) {
            match run(generation) {
                Ok(()) => break,
                Err(e) => {
                    // Windows refuses until its speech privacy policy is
                    // accepted (0x80045509): try again now and then.
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
}

fn current(generation: u64) -> bool {
    ON.load(Ordering::SeqCst) && GENERATION.load(Ordering::SeqCst) == generation
}

fn recognizer(language: &str, phrases: &[String]) -> windows::core::Result<SpeechRecognizer> {
    let rec = match (!language.is_empty()).then(|| Language::CreateLanguage(&HSTRING::from(language))) {
        Some(Ok(lang)) => SpeechRecognizer::Create(&lang).or_else(|_| SpeechRecognizer::new())?,
        _ => SpeechRecognizer::new()?,
    };
    let list: Vec<HSTRING> = phrases.iter().map(HSTRING::from).collect();
    rec.Constraints()?.Append(&SpeechRecognitionListConstraint::Create(&IIterable::<HSTRING>::from(list))?)?;
    let compiled = rec.CompileConstraintsAsync()?.get()?;
    if compiled.Status()? != SpeechRecognitionResultStatus::Success {
        crate::log::line(format!("voice: grammar didn't compile ({:?})", compiled.Status()?));
        return Err(windows::core::Error::from_hresult(windows::core::HRESULT(-1)));
    }
    Ok(rec)
}

fn run(generation: u64) -> windows::core::Result<()> {
    let config = CONFIG.lock().unwrap().clone();
    crate::log::line(format!("voice: listening for the wake word ({} commands)", config.commands.len()));
    emit("voice-state", "waiting");
    while current(generation) {
        let heard = listen(&config, generation)?;
        if heard.is_some() && CONVERSE.load(Ordering::SeqCst) {
            // The page opens the conversation; the listener waits it out.
            TALKING.store(true, Ordering::SeqCst);
            crate::log::line("voice: conversation");
            emit("voice-wake", heard.clone().unwrap_or_default());
            while TALKING.load(Ordering::SeqCst) && current(generation) {
                std::thread::sleep(Duration::from_millis(150));
            }
            continue;
        }
        match heard {
            None => break,
            // The wake word and a command in one breath.
            Some(rest) if !rest.is_empty() => {
                crate::log::line("voice: command heard");
                emit("voice-command", rest);
            }
            // The wake word alone (or the mic button): the command comes next.
            Some(_) => command_turn(&config)?,
        }
    }
    Ok(())
}

/// Waits for the wake word, alone or with a command. None: settings changed.
fn listen(config: &Config, generation: u64) -> windows::core::Result<Option<String>> {
    let rec = recognizer(&config.language, &wake_grammar(&config.wake_word, &config.commands))?;
    let heard: Arc<Mutex<Option<String>>> = Arc::default();
    let h = heard.clone();
    let wake = config.wake_word.clone();
    let session: SpeechContinuousRecognitionSession = rec.ContinuousRecognitionSession()?;
    session.ResultGenerated(&TypedEventHandler::<SpeechContinuousRecognitionSession, SpeechContinuousRecognitionResultGeneratedEventArgs>::new(
        move |_, args| {
            if let Some(args) = args.as_ref() {
                let r = args.Result()?;
                let conf = r.Confidence()?;
                if r.Status()? == SpeechRecognitionResultStatus::Success && conf != SpeechRecognitionConfidence::Rejected {
                    if let Some(rest) = after_wake(&r.Text()?.to_string(), &wake) {
                        // The wake word alone must be sure (no false wakes); with a whole
                        // command after it, the phrase itself is the proof.
                        let sure = matches!(conf, SpeechRecognitionConfidence::High | SpeechRecognitionConfidence::Medium);
                        if sure || !rest.is_empty() {
                            *h.lock().unwrap() = Some(rest);
                        }
                    }
                }
            }
            Ok(())
        },
    ))?;
    session.StartAsync()?.get()?;
    let out = loop {
        if let Some(rest) = heard.lock().unwrap().take() {
            break Some(rest);
        }
        if ASK.swap(false, Ordering::SeqCst) {
            break Some(String::new());
        }
        if !current(generation) {
            break None;
        }
        std::thread::sleep(Duration::from_millis(60));
    };
    let _ = session.StopAsync().and_then(|a| a.get());
    // Let go of the microphone before the next recogniser takes it.
    let _ = rec.Close();
    Ok(out)
}

/// After the wake word alone: one command from the list, within a few seconds.
/// The same continuous session as the wake listener: a one-shot RecognizeAsync
/// ends at once with "unknown" on some PCs, the continuous one doesn't.
fn command_turn(config: &Config) -> windows::core::Result<()> {
    emit("voice-state", "listening");
    let rec = recognizer(&config.language, &config.commands)?;
    let heard: Arc<Mutex<Option<String>>> = Arc::default();
    let h = heard.clone();
    let session: SpeechContinuousRecognitionSession = rec.ContinuousRecognitionSession()?;
    session.ResultGenerated(&TypedEventHandler::<SpeechContinuousRecognitionSession, SpeechContinuousRecognitionResultGeneratedEventArgs>::new(
        move |_, args| {
            if let Some(args) = args.as_ref() {
                let r = args.Result()?;
                // Only listed commands can match at all: low confidence is still one of them.
                if r.Status()? == SpeechRecognitionResultStatus::Success && r.Confidence()? != SpeechRecognitionConfidence::Rejected {
                    let text = r.Text()?.to_string();
                    if !text.is_empty() {
                        *h.lock().unwrap() = Some(text);
                    }
                }
            }
            Ok(())
        },
    ))?;
    session.StartAsync()?.get()?;
    let deadline = std::time::Instant::now() + Duration::from_secs(7);
    let got = loop {
        if let Some(text) = heard.lock().unwrap().take() {
            break Some(text);
        }
        if std::time::Instant::now() > deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(60));
    };
    let _ = session.StopAsync().and_then(|a| a.get());
    let _ = rec.Close();
    match got {
        Some(text) => {
            crate::log::line("voice: command heard");
            emit("voice-command", text);
        }
        None => {
            crate::log::line("voice: no command understood");
            emit("voice-command", String::from("?"));
        }
    }
    emit("voice-state", "waiting");
    Ok(())
}

/// The page's commands (lower case): the listener restarts with them.
#[tauri::command]
pub fn voice_set_phrases(phrases: Vec<String>) {
    let mut list: Vec<String> = phrases.into_iter().map(|p| p.trim().to_lowercase()).filter(|p| !p.is_empty() && p.len() <= 80).collect();
    list.sort();
    list.dedup();
    list.truncate(1500);
    {
        let mut c = CONFIG.lock().unwrap();
        if c.commands == list {
            return;
        }
        c.commands = list;
    }
    restart();
}

/// The page talks through the ElevenLabs agent (true) or the phrase list (false).
#[tauri::command]
pub fn voice_converse(on: bool) {
    CONVERSE.store(on, Ordering::SeqCst);
}

/// The conversation is over: the wake word listener takes the mic back.
#[tauri::command]
pub fn voice_conversation_ended() {
    TALKING.store(false, Ordering::SeqCst);
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

    #[test]
    fn a_command_can_ride_with_the_wake_word() {
        let g = wake_grammar("Maki", &["next song".to_string()]);
        assert!(g.contains(&"maki next song".to_string()));
        assert!(g.contains(&"hey maki next song".to_string()));
        assert_eq!(after_wake("Hey Maki next song", "Maki").as_deref(), Some("next song"));
        assert_eq!(after_wake("maki", "Maki").as_deref(), Some(""));
        assert_eq!(after_wake("next song", "Maki"), None);
    }
}
