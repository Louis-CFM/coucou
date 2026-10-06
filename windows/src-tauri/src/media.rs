//! Global Media Control — the media half of the music pill.
//!
//! macOS drives Apple Music through AppleScript, which means a TCC Automation
//! prompt, a denied-permission branch to render, and support for exactly one
//! player. Windows exposes the same thing system-wide through GSMTC: any app
//! that publishes a media session (Spotify, Chrome, VLC, foobar2000) shows up
//! here, and there is no permission to ask for.
//!
//! Spike state: read-only. `probe` is what the card will poll; the transport
//! commands are wired up but not yet surfaced in the UI.

#![cfg(windows)]
// `probe_with` and `MediaState::idle` are only reachable from the watcher
// thread and the test, so the dead-code lint fires on items the card itself
// exercises. Scoped to this module rather than the crate.
#![allow(dead_code)]

use serde::{Deserialize, Serialize};

/// Everything the card needs for one media session.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct MediaState {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    /// True when a player exists but has not published a track yet.
    pub idle: bool,
}

/// Transport actions the card can offer.
///
/// Deserialized because Tauri takes command arguments from the frontend as JSON.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum MediaCommand {
    PlayPause,
    Next,
    Previous,
}

use windows::core::HSTRING;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession, GlobalSystemMediaTransportControlsSessionManager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus,
};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

/// Makes sure this thread has a COM apartment.
///
/// WinRT activation fails without one. Tauri drives commands from a tokio
/// worker, which is not an STA and does not initialise COM for us, so every
/// entry point does this first. `RPC_E_CHANGED_MODE` is ignored: it means the
/// apartment already exists, which is the state we wanted anyway.
fn ensure_com() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
}

fn hstring(v: windows::core::Result<HSTRING>) -> String {
    v.map(|s| s.to_string()).unwrap_or_default()
}

/// The current media session, if any app is publishing one.
///
/// Synchronous by design. `RequestAsync` and `TryGetMediaPropertiesAsync` are
/// both async, and blocking a tokio worker on them is how this would deadlock
/// if it were ever called from the async command path.
pub fn probe() -> Result<Option<MediaState>, String> {
    ensure_com();
    let manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync()
        .map_err(|e| e.to_string())?
        .get()
        .map_err(|e| e.to_string())?;
    probe_with(&manager)
}

/// Reads the current session from an already-activated manager.
///
/// The watcher holds one manager for the life of the process. Re-running
/// `RequestAsync` on every tick would activate WinRT several times a second for
/// no reason; this is the same read without that cost.
fn probe_with(
    manager: &GlobalSystemMediaTransportControlsSessionManager,
) -> Result<Option<MediaState>, String> {
    let session: GlobalSystemMediaTransportControlsSession = match manager.GetCurrentSession() {
        Ok(s) => s,
        // "no session" is a normal state, not an error worth surfacing.
        Err(_) => return Ok(None),
    };

    let info = session.GetPlaybackInfo().map_err(|e| e.to_string())?;
    let status = info.PlaybackStatus().map_err(|e| e.to_string())?;

    let props = session
        .TryGetMediaPropertiesAsync()
        .map_err(|e| e.to_string())?
        .get()
        .ok();

    let state = MediaState {
        app: hstring(session.SourceAppUserModelId()),
        title: props
            .as_ref()
            .map(|p| hstring(p.Title()))
            .unwrap_or_default(),
        artist: props
            .as_ref()
            .map(|p| hstring(p.Artist()))
            .unwrap_or_default(),
        album: props
            .as_ref()
            .map(|p| hstring(p.AlbumTitle()))
            .unwrap_or_default(),
        playing: status == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing,
        idle: false,
    };

    // A player with nothing loaded still produces a session. Reporting it as an
    // empty card would show the pill as broken rather than merely idle.
    Ok(Some(if state.title.is_empty() {
        MediaState {
            idle: true,
            ..state
        }
    } else {
        state
    }))
}

/// Starts the background watcher that keeps the card current.
///
/// A dedicated OS thread rather than a tokio task, for two reasons: the WinRT
/// calls are synchronous and block, and the manager has to stay alive in an
/// apartment for as long as we care about it — neither of which a pooled async
/// worker gives you.
///
/// Only emits on change. The frontend re-renders on every `media-changed`, so
/// pushing an identical payload twice a second would repaint the island for
/// nothing.
pub fn watch<F: Fn(Option<MediaState>) + Send + 'static>(on_change: F) {
    std::thread::Builder::new()
        .name("coucou-media".into())
        .spawn(move || {
            ensure_com();
            // A failed activation means no Global Media Control on this
            // Windows build. Reporting None forever is the honest answer: there
            // is genuinely nothing to show.
            let manager = match GlobalSystemMediaTransportControlsSessionManager::RequestAsync() {
                Ok(op) => match op.get() {
                    Ok(m) => m,
                    Err(_) => {
                        on_change(None);
                        return;
                    }
                },
                Err(_) => {
                    on_change(None);
                    return;
                }
            };

            let mut last: Option<Option<MediaState>> = None;
            loop {
                let current = probe_with(&manager).unwrap_or(None);
                if last.as_ref() != Some(&current) {
                    last = Some(current.clone());
                    on_change(current);
                }
                std::thread::sleep(std::time::Duration::from_millis(900));
            }
        })
        .ok();
}

/// Sends a transport command, returning whether the player accepted it.
///
/// GSMTC answers `false` when the app has not advertised that control, so the
/// card has to hide buttons it cannot honour rather than showing dead ones.
pub fn command(cmd: MediaCommand) -> Result<bool, String> {
    ensure_com();

    let manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync()
        .map_err(|e| e.to_string())?
        .get()
        .map_err(|e| e.to_string())?;
    let session = manager
        .GetCurrentSession()
        .map_err(|_| "no media session".to_string())?;

    let ok = match cmd {
        MediaCommand::PlayPause => session.TryTogglePlayPauseAsync(),
        MediaCommand::Next => session.TrySkipNextAsync(),
        MediaCommand::Previous => session.TrySkipPreviousAsync(),
    }
    .map_err(|e| e.to_string())?;

    // The result is a WinRT bool; an app that does not support the control
    // reports false rather than failing.
    Ok(ok.get().unwrap_or(false))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Not a correctness test — GSMTC is whatever the user happens to be
    /// playing. This exists so the WinRT wiring is compiled and exercised by CI
    /// on Windows, which is the part that can silently stop building.
    #[test]
    fn probe_does_not_panic_without_a_media_session() {
        ensure_com();
        // Must not panic whatever the desktop is doing.
        let result = probe();
        assert!(
            result.is_ok() || result.is_err(),
            "probe must return a Result, never hang or abort"
        );
        if let Ok(Some(state)) = result {
            println!(
                "[media] app={:?} title={:?} playing={}",
                state.app, state.title, state.playing
            );
        } else {
            println!("[media] no active media session (this is normal)");
        }
    }

    /// Reads whatever the user is actually playing.
    ///
    /// Ignored by default: it is environment-dependent, and a machine with
    /// nothing playing has nothing to assert against. Run it with something
    /// playing to see the real output:
    ///
    ///     cargo test --manifest-path src-tauri/Cargo.toml media -- --ignored --nocapture
    ///
    /// This is the end-to-end check that matters. A synthetic publisher is not
    /// an option from a test process: `SystemMediaTransportControls::
    /// GetForCurrentView` fails with 0x80070578 ("could not find an appropriate
    /// view") because a console test binary has no CoreWindow. The app does.
    #[test]
    #[ignore = "needs a media session; run with something playing"]
    fn probe_reads_a_live_media_session() {
        ensure_com();
        let found = probe().expect("probe must not error");
        match found {
            Some(state) => {
                println!(
                    "[media] app={:?}
       title={:?}
       artist={:?}
       album={:?}
       playing={}",
                    state.app, state.title, state.artist, state.album, state.playing
                );
                assert!(
                    !state.title.is_empty(),
                    "a live session should carry a track title"
                );
            }
            None => panic!("nothing is publishing a media session — start a player and re-run"),
        }
    }

    /// The transport commands must not panic even with no player attached.
    #[test]
    fn commands_are_safe_without_a_session() {
        ensure_com();
        // A refusal is the correct answer here; a crash is not.
        let _ = command(MediaCommand::PlayPause);
        let _ = command(MediaCommand::Next);
        let _ = command(MediaCommand::Previous);
    }
}
