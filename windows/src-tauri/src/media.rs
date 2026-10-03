//! What is playing right now, and the transport buttons, over SMTC.
//!
//! macOS reads Apple Music through `NSAppleScript`; Windows has no scripting
//! bridge to any player, so this goes through the System Media Transport
//! Controls session manager instead — which is player-agnostic: Spotify, VLC,
//! browsers and Apple Music's own preview all publish a session there.
//!
//! WinRT's async operations here are cheap and always complete, so they are
//! pulled with the blocking `get()` on a blocking thread rather than fought
//! with inside the tokio runtime.

use std::sync::atomic::Ordering;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub app: String,
    pub playing: bool,
}

impl NowPlaying {
    pub fn live(&self) -> bool {
        !(self.title.is_empty() && self.artist.is_empty())
    }
}

#[cfg(windows)]
mod imp {
    use super::NowPlaying;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };

    fn manager() -> windows::core::Result<Manager> {
        Manager::RequestAsync()?.get()
    }

    pub(super) fn session() -> Option<Session> {
        manager().ok()?.GetCurrentSession().ok()
    }

    pub fn snapshot() -> NowPlaying {
        let Some(session) = session() else {
            return NowPlaying::default();
        };
        let Ok(props) = session.TryGetMediaPropertiesAsync().and_then(|op| op.get()) else {
            return NowPlaying::default();
        };
        let mut now = NowPlaying {
            title: props.Title().map(|s| s.to_string()).unwrap_or_default(),
            artist: props.Artist().map(|s| s.to_string()).unwrap_or_default(),
            album: props.AlbumTitle().map(|s| s.to_string()).unwrap_or_default(),
            ..NowPlaying::default()
        };
        if !now.live() {
            return NowPlaying::default();
        }
        now.playing = session
            .GetPlaybackInfo()
            .and_then(|info| info.PlaybackStatus())
            .map(|s| s == Status::Playing)
            .unwrap_or(false);
        now.app = session
            .SourceAppUserModelId()
            .map(|s| s.to_string())
            .unwrap_or_default();
        now
    }

    pub fn control(action: &str) -> bool {
        let Some(session) = session() else {
            return false;
        };
        let op = match action {
            "play" => session.TryPlayAsync(),
            "pause" => session.TryPauseAsync(),
            "toggle" => session.TryTogglePlayPauseAsync(),
            "next" => session.TrySkipNextAsync(),
            "prev" => session.TrySkipPreviousAsync(),
            _ => return false,
        };
        op.and_then(|op| op.get()).is_ok()
    }
}

#[cfg(not(windows))]
mod imp {
    use super::NowPlaying;

    pub fn snapshot() -> NowPlaying {
        NowPlaying::default()
    }

    pub fn control(_action: &str) -> bool {
        false
    }
}

pub async fn snapshot() -> NowPlaying {
    tokio::task::spawn_blocking(imp::snapshot)
        .await
        .unwrap_or_default()
}

pub async fn control(action: &str) -> bool {
    let action = action.to_string();
    tokio::task::spawn_blocking(move || imp::control(&action))
        .await
        .unwrap_or(false)
}

fn enabled(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .map(|shared| shared.settings.lock().unwrap().music_enabled)
        .unwrap_or(false)
}

/// Emits `media` only when what is playing actually changes, so a track sitting
/// still costs nothing and the island is not woken for a status it already shows.
/// Turning the setting off emits one empty payload to clear the card.
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let mut ticker = tokio::time::interval(Duration::from_secs(2));
        let mut last = NowPlaying::default();
        loop {
            ticker.tick().await;
            let on = !crate::integrations::PAUSED.load(Ordering::Relaxed) && enabled(&app);
            let now = if on { snapshot().await } else { NowPlaying::default() };
            if now != last {
                last = now.clone();
                let _ = app.emit("media", &now);
            }
        }
    });
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    #[ignore = "needs a media player running on this machine"]
    fn whatever_is_playing_is_readable() {
        println!("session available: {}", imp::session().is_some());
        println!("now playing: {:?}", imp::snapshot());
        // An action nobody implements: reaches the session lookup and the WinRT
        // call dispatch without touching the user's playback.
        println!("unknown action -> {}", imp::control("noop"));
    }
}
