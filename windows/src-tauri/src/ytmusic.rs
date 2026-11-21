// The YouTube Music pill.
//
// Windows reads the system media controls (SMTC) for YouTube Music PWAs and
// desktop clients, mirroring spotify.rs's Windows listener.

use tauri::AppHandle;

use crate::spotify::*;

pub const PILL_ID: &str = "integration_ytmusic";
/// Island events: the player's state, and a track's cover as a data URL.
#[allow(dead_code)]
const STATE_EVENT: &str = "ytmusic";
#[allow(dead_code)]
const ARTWORK_EVENT: &str = "ytmusic-artwork";

#[allow(dead_code)]
fn emit_state(app: &AppHandle, state: &PlayerState) {
    use tauri::Emitter;
    let _ = app.emit_to(crate::island::WINDOW_LABEL, STATE_EVENT, state);
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// The player as it is now, read again from YouTube Music.
#[tauri::command]
pub async fn ytmusic_refresh(app: AppHandle) -> Option<PlayerState> {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(move || win::refresh(&app)).await.ok().flatten()
    }
    #[cfg(not(windows))]
    {
        let _ = app;
        None
    }
}

/// A control from the card or the pill: `playPause`, `next`, `previous`,
/// `seek` (seconds), `shuffle` / `repeat` (1 on, 0 off).
#[tauri::command]
pub async fn ytmusic_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(move || win::control(&app, &action, value)).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        let _ = (app, action, value);
        false
    }
}

/// "Open YouTube Music": brings the PWA/app forward, or opens it.
#[tauri::command]
pub async fn ytmusic_open() -> bool {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(crate::platform::open_ytmusic).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// For Settings: whether YouTube Music can be launched.
#[tauri::command]
pub fn ytmusic_installed() -> bool {
    #[cfg(windows)]
    {
        true
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// Starts the listener when the pill is declared, stops it when it is not.
/// Called at launch and after every settings save.
pub fn sync(app: &AppHandle, active_integrations: &[String]) {
    let on = active_integrations.iter().any(|id| id == PILL_ID);
    #[cfg(windows)]
    {
        win::sync(app, on);
    }
    #[cfg(not(windows))]
    let _ = (app, on);
}

// ── Windows: the system media controls ────────────────────────────────────────

#[cfg(windows)]
mod win {
    use super::*;
    use std::collections::VecDeque;
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{LazyLock, Mutex};

    use windows::Foundation::TypedEventHandler;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionMediaProperties as MediaProperties,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Media::MediaPlaybackAutoRepeatMode;
    use windows::Storage::Streams::DataReader;
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

    /// What wakes the listener.
    enum Wake {
        /// The session's track, status or timeline moved.
        Changed,
        /// A player appeared or went away: find YouTube Music's session again.
        Sessions,
        Stop,
    }

    struct Shared {
        /// Bumped on every start and stop: a listener from an older one quits.
        generation: u64,
        active: bool,
        wake: Option<Sender<Wake>>,
        state: PlayerState,
    }

    static SHARED: LazyLock<Mutex<Shared>> = LazyLock::new(|| {
        Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default() })
    });

    /// Covers already read, by the track's art key; the newest last.
    static ART: LazyLock<Mutex<VecDeque<(String, String)>>> = LazyLock::new(|| Mutex::new(VecDeque::new()));

    /// WinRT needs COM on the calling thread. A thread that has it already, in
    /// either model, keeps it.
    fn com() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    // ── Start / stop ──────────────────────────────────────────────────────────

    pub fn sync(app: &AppHandle, on: bool) {
        let (tx, rx) = mpsc::channel();
        let (old, generation, state) = {
            let mut s = SHARED.lock().unwrap();
            if s.active == on {
                return;
            }
            s.active = on;
            s.generation += 1;
            s.state = PlayerState { installed: true, ..PlayerState::default() };
            let old = s.wake.take();
            if on {
                s.wake = Some(tx.clone());
            }
            (old, s.generation, s.state.clone())
        };
        if let Some(old) = old {
            let _ = old.send(Wake::Stop);
        }
        if on {
            let app = app.clone();
            let spawned = std::thread::Builder::new()
                .name("coucou-ytmusic".into())
                .spawn(move || listen(app, generation, tx, rx));
            if let Err(err) = spawned {
                crate::log::line(format!("ytmusic: no listener thread: {err}"));
            }
        } else {
            emit_state(app, &state);
        }
    }

    /// Waits on the session's events and tells the island what changed. Nothing
    /// runs between events.
    fn listen(app: AppHandle, generation: u64, tx: Sender<Wake>, rx: Receiver<Wake>) {
        com();
        let manager = match Manager::RequestAsync().and_then(|op| op.get()) {
            Ok(m) => m,
            Err(err) => {
                crate::log::line(format!("ytmusic: no media sessions: {err}"));
                return;
            }
        };
        let sessions_token = {
            let tx = tx.clone();
            manager
                .SessionsChanged(&TypedEventHandler::new(move |_, _| {
                    let _ = tx.send(Wake::Sessions);
                    Ok(())
                }))
                .ok()
        };

        let mut bound: Option<Bound> = None;
        let mut rebind = true;
        while current(generation) {
            if rebind {
                if let Some(b) = bound.take() {
                    b.unbind();
                }
                bound = find_session(&manager).and_then(|s| Bound::bind(s, &tx));
                rebind = false;
            }
            read_and_emit(&app, generation, bound.as_ref().map(|b| &b.session));

            // Events come in bursts (a new track moves everything): one read each.
            let mut stop = false;
            match rx.recv() {
                Ok(Wake::Changed) => {}
                Ok(Wake::Sessions) => rebind = true,
                Ok(Wake::Stop) | Err(_) => stop = true,
            }
            while let Ok(more) = rx.try_recv() {
                match more {
                    Wake::Changed => {}
                    Wake::Sessions => rebind = true,
                    Wake::Stop => stop = true,
                }
            }
            if stop {
                break;
            }
        }

        if let Some(b) = bound {
            b.unbind();
        }
        if let Some(token) = sessions_token {
            let _ = manager.RemoveSessionsChanged(token);
        }
    }

    /// YouTube Music's session, with the event handlers that wake the listener.
    struct Bound {
        session: Session,
        tokens: [Option<i64>; 3],
    }

    impl Bound {
        fn bind(session: Session, tx: &Sender<Wake>) -> Option<Bound> {
            let tokens = [
                session.MediaPropertiesChanged(&wake_on(tx)).ok(),
                session.PlaybackInfoChanged(&wake_on(tx)).ok(),
                session.TimelinePropertiesChanged(&wake_on(tx)).ok(),
            ];
            Some(Bound { session, tokens })
        }

        fn unbind(self) {
            let [media, playback, timeline] = self.tokens;
            if let Some(t) = media {
                let _ = self.session.RemoveMediaPropertiesChanged(t);
            }
            if let Some(t) = playback {
                let _ = self.session.RemovePlaybackInfoChanged(t);
            }
            if let Some(t) = timeline {
                let _ = self.session.RemoveTimelinePropertiesChanged(t);
            }
        }
    }

    /// A handler that wakes the listener, for any of the session's events.
    fn wake_on<A: windows::core::RuntimeType + 'static>(tx: &Sender<Wake>) -> TypedEventHandler<Session, A> {
        let tx = tx.clone();
        TypedEventHandler::new(move |_, _| {
            let _ = tx.send(Wake::Changed);
            Ok(())
        })
    }

    fn find_session(manager: &Manager) -> Option<Session> {
        let sessions = manager.GetSessions().ok()?;
        (0..sessions.Size().ok()?)
            .filter_map(|i| sessions.GetAt(i).ok())
            .find(|s| s.SourceAppUserModelId().is_ok_and(|id| is_ytmusic_app(&id.to_string_lossy())))
    }

    // ── Reading ───────────────────────────────────────────────────────────────

    /// Everything the session says, as it is now.
    struct Snapshot {
        track: Option<Track>,
        playing: bool,
        position: f64,
        /// When Windows last updated the position (Unix ms), if it says.
        updated_at: Option<f64>,
        shuffle: bool,
        repeat: bool,
    }

    fn snapshot(session: &Session) -> windows::core::Result<(Snapshot, MediaProperties)> {
        let props = session.TryGetMediaPropertiesAsync()?.get()?;
        let timeline = session.GetTimelineProperties()?;
        let start = timeline.StartTime()?.Duration;
        let duration = ticks_to_secs(timeline.EndTime()?.Duration - start);
        let track = windows_track(
            &props.Title()?.to_string_lossy(),
            &props.Artist()?.to_string_lossy(),
            &props.AlbumTitle()?.to_string_lossy(),
            duration,
        );
        let info = session.GetPlaybackInfo()?;
        let snapshot = Snapshot {
            playing: info.PlaybackStatus()? == Status::Playing && track.is_some(),
            track,
            position: ticks_to_secs(timeline.Position()?.Duration - start),
            updated_at: windows_time_to_unix_ms(timeline.LastUpdatedTime()?.UniversalTime),
            shuffle: info.IsShuffleActive().and_then(|r| r.Value()).unwrap_or(false),
            repeat: info
                .AutoRepeatMode()
                .and_then(|r| r.Value())
                .is_ok_and(|mode| mode != MediaPlaybackAutoRepeatMode::None),
        };
        Ok((snapshot, props))
    }

    fn read_and_emit(app: &AppHandle, generation: u64, session: Option<&Session>) {
        let read = session.and_then(|s| snapshot(s).ok());
        let now = now_ms();
        let (state, props) = {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return;
            }
            let props = match read {
                Some((snap, props)) => {
                    s.state.running = true;
                    s.state.installed = true;
                    s.state.track = snap.track;
                    s.state.playing = snap.playing;
                    // The position was true when Windows last updated it; while
                    // playing, the page runs it on from there.
                    let at = snap.updated_at.filter(|&t| t <= now).unwrap_or(now);
                    s.state.anchor(snap.position, at);
                    s.state.shuffle = snap.shuffle;
                    s.state.repeat = snap.repeat;
                    Some(props)
                }
                None => {
                    s.state.running = false;
                    s.state.installed = true;
                    s.state.clear(now);
                    None
                }
            };
            (s.state.clone(), props)
        };
        emit_state(app, &state);
        if let (Some(props), Some(track)) = (props, state.track.as_ref()) {
            artwork(app, track, &props);
        }
    }

    // ── Artwork ───────────────────────────────────────────────────────────────

    /// The track's cover, as a data URL. Brave PWA initially fires
    /// MediaPropertiesChanged with a placeholder logo and ~1s later fires again
    /// with the real cover under the same `art_url`, so we always read the
    /// fresh thumbnail first and only fall back to the cache if it's absent.
    fn artwork(app: &AppHandle, track: &Track, props: &MediaProperties) {
        use tauri::Emitter;
        let Some(key) = track.art_url.clone() else { return };
        let data = if let Some(fresh_data) = thumbnail(props).as_deref().and_then(data_url) {
            let mut art = ART.lock().unwrap();
            art.retain(|(k, _)| *k != key);
            art.push_back((key.clone(), fresh_data.clone()));
            while art.len() > 12 {
                art.pop_front();
            }
            fresh_data
        } else {
            let Some(cached) = ART.lock().unwrap().iter().find(|(k, _)| *k == key).map(|(_, d)| d.clone()) else {
                return;
            };
            cached
        };
        let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: key, data_url: data });
    }

    fn thumbnail(props: &MediaProperties) -> Option<Vec<u8>> {
        let stream = props.Thumbnail().ok()?.OpenReadAsync().ok()?.get().ok()?;
        let size = stream.Size().ok()?;
        if size == 0 || size > ARTWORK_LIMIT as u64 {
            return None;
        }
        let reader = DataReader::CreateDataReader(&stream).ok()?;
        let loaded = reader.LoadAsync(size as u32).ok()?.get().ok()?;
        let mut bytes = vec![0u8; loaded as usize];
        reader.ReadBytes(&mut bytes).ok()?;
        Some(bytes)
    }

    // ── Commands ──────────────────────────────────────────────────────────────

    pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
        let generation = {
            let s = SHARED.lock().unwrap();
            if !s.active {
                return None;
            }
            s.generation
        };
        com();
        let manager = Manager::RequestAsync().and_then(|op| op.get()).ok();
        let session = manager.as_ref().and_then(find_session);
        read_and_emit(app, generation, session.as_ref());
        let s = SHARED.lock().unwrap();
        (s.active && s.generation == generation).then(|| s.state.clone())
    }

    pub fn control(app: &AppHandle, action: &str, value: Option<f64>) -> bool {
        let state = {
            let s = SHARED.lock().unwrap();
            if !(s.active && s.state.running) {
                return false;
            }
            s.state.clone()
        };
        com();
        let Some(session) = Manager::RequestAsync().and_then(|op| op.get()).ok().and_then(|m| find_session(&m)) else {
            return false;
        };
        let v = value.unwrap_or(0.0);
        // A request Windows passed on, and the player said yes to.
        macro_rules! asked {
            ($op:expr) => {
                $op.and_then(|op| op.get()).unwrap_or(false)
            };
        }
        let seek_to = state.track.as_ref().map(|t| v.clamp(0.0, (t.duration - 1.0).max(0.0)));
        let done = match action {
            "playPause" => asked!(session.TryTogglePlayPauseAsync()),
            "next" => asked!(session.TrySkipNextAsync()),
            "previous" => asked!(session.TrySkipPreviousAsync()),
            "seek" => match (seek_to, session.GetTimelineProperties().and_then(|t| t.StartTime())) {
                (Some(target), Ok(start)) => {
                    asked!(session.TryChangePlaybackPositionAsync(start.Duration + (target * 10_000_000.0) as i64))
                }
                _ => false,
            },
            "shuffle" => asked!(session.TryChangeShuffleActiveAsync(v != 0.0)),
            "repeat" => asked!(session.TryChangeAutoRepeatModeAsync(if v != 0.0 {
                MediaPlaybackAutoRepeatMode::List
            } else {
                MediaPlaybackAutoRepeatMode::None
            })),
            _ => false,
        };
        if !done {
            return false;
        }
        // Show these at once, as the Mac does; the session's events confirm them.
        let optimistic = matches!(action, "seek" | "shuffle" | "repeat");
        if optimistic {
            let state = {
                let mut s = SHARED.lock().unwrap();
                match action {
                    "seek" => {
                        if let Some(target) = seek_to {
                            s.state.anchor(target, now_ms());
                        }
                    }
                    "shuffle" => s.state.shuffle = v != 0.0,
                    _ => s.state.repeat = v != 0.0,
                }
                s.state.clone()
            };
            emit_state(app, &state);
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::is_ytmusic_app;

    #[test]
    fn windows_media_sessions_of_ytmusic_are_recognised() {
        assert!(is_ytmusic_app("Brave._crx_cinhimbnkkghhklpknlkffjgod"));
        assert!(is_ytmusic_app("Chrome._crx_cinhimbnkkghhklpknlkffjgod"));
        assert!(is_ytmusic_app("msedge._crx_cinhimbnkkghhklpknlkffjgod"));
        assert!(is_ytmusic_app("YouTube Music"));
        assert!(is_ytmusic_app("ytmdesktop"));
        assert!(!is_ytmusic_app("Brave"));
        assert!(!is_ytmusic_app("chrome.exe"));
        assert!(!is_ytmusic_app("Spotify.exe"));
    }
}
