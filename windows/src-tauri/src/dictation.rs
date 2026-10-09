// Dictation — the chat field's mic, the port of MacDictation.swift.
//
// Windows.Media.SpeechRecognition runs a continuous session: every finished
// phrase reaches the island as a `dictation-line` event and lands at the
// input's caret. The session reports its own end with `dictation-end` — a tap
// on the mic again, the silence auto-stop, or an error — so the button always
// settles. Linux has no engine wired yet: `dictation_supported` hides the mic.

use std::sync::Mutex;

use tauri::AppHandle;
#[cfg(windows)]
use tauri::{Emitter, Manager};

#[cfg(windows)]
use crate::island::WINDOW_LABEL;

#[derive(Default)]
pub struct Dictation {
    live: Mutex<Option<Live>>,
}

#[cfg(windows)]
struct Live {
    // Kept alive for the session's lifetime: dropping the recognizer while the
    // session runs tears the whole thing down.
    _recognizer: windows::Media::SpeechRecognition::SpeechRecognizer,
    session: windows::Media::SpeechRecognition::SpeechContinuousRecognitionSession,
}

#[cfg(not(windows))]
struct Live;

#[cfg(windows)]
#[derive(Clone, serde::Serialize)]
struct Line {
    text: String,
}

#[cfg(windows)]
#[derive(Clone, serde::Serialize)]
struct Failed {
    code: &'static str,
}

/// The chat bar only draws the mic where there is an engine behind it.
#[tauri::command]
pub fn dictation_supported() -> bool {
    cfg!(windows)
}

/// Starts listening; a second tap stops it, as does the session's own end.
#[tauri::command]
pub async fn dictation_start(app: AppHandle, d: tauri::State<'_, Dictation>) -> Result<(), String> {
    if d.live.lock().unwrap().is_some() {
        return Ok(());
    }
    #[cfg(windows)]
    {
        let live = start(&app).map_err(|e| {
            crate::log::line(format!("dictation: {e}"));
            "dictation"
        })?;
        *d.live.lock().unwrap() = Some(live);
    }
    #[cfg(not(windows))]
    {
        let _ = app;
        return Err("dictation".into());
    }
    Ok(())
}

/// Commits what was heard so far; the Completed handler clears the session.
#[tauri::command]
pub async fn dictation_stop(d: tauri::State<'_, Dictation>) -> Result<(), String> {
    #[cfg(windows)]
    if let Some(live) = d.live.lock().unwrap().take() {
        let _ = live.session.StopAsync().and_then(|a| a.get());
    }
    #[cfg(not(windows))]
    let _ = d;
    Ok(())
}

#[cfg(windows)]
fn start(app: &AppHandle) -> windows::core::Result<Live> {
    use windows::Foundation::TypedEventHandler;
    use windows::Media::SpeechRecognition::*;

    // No constraints: the recognizer falls back to the free-form dictation
    // grammar in the system speech language — like the Mac's SFSpeechRecognizer.
    let recognizer = SpeechRecognizer::new()?;
    let compiled = recognizer.CompileConstraintsAsync()?.get()?;
    if compiled.Status()? != SpeechRecognitionResultStatus::Success {
        return Err(windows::core::Error::from_hresult(
            windows::Win32::Foundation::E_FAIL,
        ));
    }
    let session = recognizer.ContinuousRecognitionSession()?;

    let for_lines = app.clone();
    session.ResultGenerated(&TypedEventHandler::new(
        move |_, args: windows::core::Ref<'_, SpeechContinuousRecognitionResultGeneratedEventArgs>| {
            let result = args.ok()?.Result()?;
            let status = result.Status()?;
            if status == SpeechRecognitionResultStatus::Success {
                let text = result.Text()?.to_string_lossy();
                if !text.trim().is_empty() {
                    let _ = for_lines.emit_to(WINDOW_LABEL, "dictation-line", Line { text });
                }
            } else if let Some(code) = failure_code(status) {
                let _ = for_lines.emit_to(WINDOW_LABEL, "dictation-error", Failed { code });
            }
            Ok(())
        },
    ))?;

    let for_done = app.clone();
    session.Completed(&TypedEventHandler::new(
        move |_, _args: windows::core::Ref<'_, SpeechContinuousRecognitionCompletedEventArgs>| {
            let _ = for_done.emit_to(WINDOW_LABEL, "dictation-end", ());
            for_done.state::<Dictation>().live.lock().unwrap().take();
            Ok(())
        },
    ))?;

    session.StartAsync()?.get()?;
    Ok(Live {
        _recognizer: recognizer,
        session,
    })
}

/// The statuses worth telling the user about; pause/resume/timeout are the
/// session's normal breathing and UserCanceled is the user's own tap.
#[cfg(windows)]
fn failure_code(
    status: windows::Media::SpeechRecognition::SpeechRecognitionResultStatus,
) -> Option<&'static str> {
    use windows::Media::SpeechRecognition::SpeechRecognitionResultStatus as S;
    match status {
        s if s == S::MicrophoneUnavailable => Some("mic"),
        s if s == S::NetworkFailure => Some("net"),
        s if s == S::AudioQualityFailure => Some("audio"),
        s if s == S::TopicLanguageNotSupported
            || s == S::GrammarLanguageMismatch
            || s == S::GrammarCompilationFailure =>
        {
            Some("language")
        }
        s if s == S::Unknown => Some("unknown"),
        _ => None,
    }
}
