// Now playing from the Spotify desktop app, via the Windows media session.
// No Spotify account and no network: we only talk to the app the user already
// opened. Track changes update the card; they never become an alert.

use std::sync::Mutex;
use std::time::Duration;

use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession,
    GlobalSystemMediaTransportControlsSessionManager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus,
};

#[derive(Clone, PartialEq)]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    pub playing: bool,
    pub available: bool,
}

impl NowPlaying {
    fn closed() -> Self {
        Self {
            title: String::new(),
            artist: String::new(),
            playing: false,
            available: false,
        }
    }
}

/// One SMTC call at a time. The poll and a button can otherwise overlap.
static LOCK: Mutex<()> = Mutex::new(());

pub fn snapshot() -> NowPlaying {
    let _guard = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    read().unwrap_or_else(|_| NowPlaying::closed())
}

pub fn perform(action: &str) -> NowPlaying {
    let _guard = LOCK.lock().unwrap_or_else(|p| p.into_inner());
    if let Some(session) = find_spotify() {
        let _ = match action {
            "next" => session.TrySkipNextAsync().and_then(|op| op.get()),
            "prev" => session.TrySkipPreviousAsync().and_then(|op| op.get()),
            _ => session.TryTogglePlayPauseAsync().and_then(|op| op.get()),
        };
        // The session status trails the click by a moment.
        drop(_guard);
        std::thread::sleep(Duration::from_millis(280));
        return snapshot();
    }
    NowPlaying::closed()
}

fn read() -> windows::core::Result<NowPlaying> {
    let Some(session) = find_spotify() else {
        return Ok(NowPlaying::closed());
    };
    let playback = session.GetPlaybackInfo()?;
    let status = playback.PlaybackStatus()?;
    let props = session.TryGetMediaPropertiesAsync()?.get()?;
    Ok(NowPlaying {
        title: props.Title().unwrap_or_default().to_string(),
        artist: props.Artist().unwrap_or_default().to_string(),
        playing: status == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing,
        available: true,
    })
}

fn find_spotify() -> Option<GlobalSystemMediaTransportControlsSession> {
    let manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().ok()?.get().ok()?;
    let sessions = manager.GetSessions().ok()?;
    let count = sessions.Size().ok()?;
    for i in 0..count {
        let Ok(session) = sessions.GetAt(i) else { continue };
        let Ok(id) = session.SourceAppUserModelId() else { continue };
        if id.to_string().to_ascii_lowercase().contains("spotify") {
            return Some(session);
        }
    }
    None
}
