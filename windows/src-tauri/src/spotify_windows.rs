// The Spotify pill on Windows: SMTC, the system media transport controls.
//
// Spotify publishes what it plays to Windows (the volume-flyout media card, the
// lock screen): its track, cover, playback status, shuffle and repeat, with the
// timeline. The same session takes play/pause, skip, seek, shuffle and repeat
// as method calls. This module reads it and drives it, as the Linux module does
// over MPRIS, and reports the same `PlayerState` to the island.
//
// Nothing runs on a timer. While the pill is declared, one thread sleeps on a
// channel that SMTC's events (the media, the playback info, the timeline, and a
// session appearing or going) write to. Position is not signalled while a track
// plays: the page runs it on from a timestamp, as it does on Linux.
//
// What SMTC does not have, and so what is different from the Mac and Linux:
// - no volume: the slider is shown but `volume` is not applied (the mixer's
//   per-app volume would be a separate source);
// - no track id: `smtc:<hash of title, artist, album>` stands in for it, and an
//   ad is recognised by its title and artist (spotify:ad:smtc);
// - a session exists once Spotify has something loaded, so "running" means that.

use super::*;

use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use tauri::Emitter;
use windows::Foundation::TypedEventHandler;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Media::MediaPlaybackAutoRepeatMode;
use windows::Storage::Streams::{DataReader, IRandomAccessStreamReference};
use windows::Win32::System::WinRT::{RoInitialize, RO_INIT_MULTITHREADED};

/// What `windows` 0.61 returns for an event registration.
type EventRegistrationToken = i64;

/// The listener sleeps on its channel; this only bounds a lost wake-up.
const IDLE_WAIT: Duration = Duration::from_secs(3600);
/// SMTC fires several events for one change: wait for the burst to end.
const SETTLE: Duration = Duration::from_millis(60);

enum Msg {
    /// The media, the playback info or the timeline changed.
    Changed,
    /// A session appeared or went: look for Spotify's again.
    Sessions,
    /// The pill was turned off.
    Stop,
}

struct Shared {
    /// Bumped on every start and stop: a listener from an older one quits.
    generation: u64,
    active: bool,
    /// How to wake (or stop) the listener.
    wake: Option<mpsc::Sender<Msg>>,
    state: PlayerState,
    /// The cover on screen: its key (`Track::art_url`) and the data URL.
    cover: Option<(String, String)>,
}

static SHARED: LazyLock<Mutex<Shared>> = LazyLock::new(|| {
    Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default(), cover: None })
});

/// WinRT wants every thread that calls it to be initialised.
fn init_winrt() {
    // Already initialised (by us, or by the runtime that owns the thread) is fine.
    let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
}

fn request_manager() -> windows::core::Result<Manager> {
    Manager::RequestAsync()?.get()
}

/// Spotify's session among everything that plays: the desktop build and the
/// Store one both have "spotify" in their AppUserModelId.
fn find_session(manager: &Manager) -> Option<Session> {
    let sessions = manager.GetSessions().ok()?;
    sessions
        .into_iter()
        .find(|s| s.SourceAppUserModelId().map(|id| is_spotify_source(&id.to_string())).unwrap_or(false))
}

// ── Reading ───────────────────────────────────────────────────────────────────

struct Read {
    track: Option<Track>,
    playing: bool,
    shuffle: bool,
    repeat: bool,
    /// Seconds, already run on to `now`.
    position: f64,
    thumb: Option<IRandomAccessStreamReference>,
}

fn read_session(session: &Session, now: f64) -> Option<Read> {
    let props = session.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
    let text = |r: windows::core::Result<windows::core::HSTRING>| r.map(|s| s.to_string()).unwrap_or_default();
    let title = text(props.Title());
    let artist = text(props.Artist());
    let album = text(props.AlbumTitle());
    let thumb = props.Thumbnail().ok();

    let info = session.GetPlaybackInfo().ok()?;
    let playing = info.PlaybackStatus().ok()? == Status::Playing;
    let shuffle = info.IsShuffleActive().ok().and_then(|r| r.Value().ok()).unwrap_or(false);
    let repeat = info
        .AutoRepeatMode()
        .ok()
        .and_then(|r| r.Value().ok())
        .is_some_and(|mode| mode != MediaPlaybackAutoRepeatMode::None);

    let seconds = |t: windows::Foundation::TimeSpan| t.Duration as f64 / 10_000_000.0;
    let (position, duration, updated) = match session.GetTimelineProperties() {
        Ok(t) => {
            let start = t.StartTime().map(seconds).unwrap_or(0.0);
            let end = t.EndTime().map(seconds).unwrap_or(0.0);
            let position = (t.Position().map(seconds).unwrap_or(0.0) - start).max(0.0);
            let updated = t.LastUpdatedTime().ok().and_then(|d| universal_ticks_to_unix_ms(d.UniversalTime));
            (position, (end - start).max(0.0), updated)
        }
        Err(_) => (0.0, 0.0, None),
    };

    let track = smtc_track(&title, &artist, &album, duration, thumb.is_some());
    Some(Read {
        playing: playing && track.is_some(),
        position: smtc_position(position, updated, playing, now, duration),
        track,
        shuffle,
        repeat,
        thumb,
    })
}

/// The cover's bytes, read from the session's thumbnail stream.
fn read_cover(thumb: &IRandomAccessStreamReference) -> Option<Vec<u8>> {
    let stream = thumb.OpenReadAsync().ok()?.get().ok()?;
    let size = stream.Size().ok()?;
    if size == 0 || size as usize > ARTWORK_LIMIT {
        return None;
    }
    let input = stream.GetInputStreamAt(0).ok()?;
    let reader = DataReader::CreateDataReader(&input).ok()?;
    let loaded = reader.LoadAsync(size as u32).ok()?.get().ok()?;
    let mut bytes = vec![0u8; loaded as usize];
    reader.ReadBytes(&mut bytes).ok()?;
    Some(bytes)
}

// ── Publishing ────────────────────────────────────────────────────────────────

/// Reads Spotify's session, keeps the result as the player's state and tells
/// the island. `None` when this listener is no longer the current one.
fn update(app: &AppHandle, generation: u64, session: Option<&Session>) -> Option<PlayerState> {
    let now = now_ms();
    let read = session.and_then(|s| read_session(s, now));
    let state = {
        let mut shared = SHARED.lock().unwrap();
        if !(shared.active && shared.generation == generation) {
            return None;
        }
        let volume = shared.state.volume;
        let installed = shared.state.installed || session.is_some();
        shared.state = match &read {
            Some(r) => PlayerState {
                running: true,
                installed: true,
                track: r.track.clone(),
                playing: r.playing,
                position: r.position,
                position_at: now,
                shuffle: r.shuffle,
                repeat: r.repeat,
                volume,
            },
            None => PlayerState { running: session.is_some(), installed, volume, ..PlayerState::default() },
        };
        shared.state.clone()
    };
    emit_state(app, &state);
    if let (Some(r), Some(url)) = (&read, state.track.as_ref().and_then(|t| t.art_url.as_deref())) {
        publish_cover(app, generation, url, r.thumb.as_ref());
    }
    Some(state)
}

/// Sends the track's cover to the island as a data URL (the page may not load
/// anything else). It is read at every change, not only on a new track: Spotify
/// can set the picture a moment after the title, and an update then replaces it.
fn publish_cover(app: &AppHandle, generation: u64, url: &str, thumb: Option<&IRandomAccessStreamReference>) {
    let data = thumb.and_then(read_cover).as_deref().and_then(data_url);
    let mut shared = SHARED.lock().unwrap();
    if !(shared.active && shared.generation == generation) {
        return;
    }
    match data {
        Some(data) => {
            if shared.cover.as_ref().is_some_and(|(u, d)| u == url && *d == data) {
                return;
            }
            shared.cover = Some((url.to_string(), data.clone()));
            drop(shared);
            let _ = app.emit_to(
                crate::island::WINDOW_LABEL,
                ARTWORK_EVENT,
                Artwork { art_url: url.to_string(), data_url: data },
            );
        }
        // Nothing readable for this track: the previous track's cover is not its own.
        None => {
            if shared.cover.as_ref().is_some_and(|(u, _)| u != url) {
                shared.cover = None;
            }
        }
    }
}

// ── Listening ─────────────────────────────────────────────────────────────────

/// The event registrations, so they can be taken back (SMTC keeps calling a
/// handler until it is removed).
struct Hooks {
    manager_sessions: Option<EventRegistrationToken>,
    session: Option<Session>,
    media: Option<EventRegistrationToken>,
    playback: Option<EventRegistrationToken>,
    timeline: Option<EventRegistrationToken>,
}

impl Hooks {
    fn new(manager: &Manager, tx: &mpsc::Sender<Msg>) -> Hooks {
        let t = tx.clone();
        let manager_sessions = manager
            .SessionsChanged(&TypedEventHandler::new(move |_, _| {
                let _ = t.send(Msg::Sessions);
                Ok(())
            }))
            .ok();
        Hooks { manager_sessions, session: None, media: None, playback: None, timeline: None }
    }

    /// Spotify's current session, followed on its three events.
    fn follow(&mut self, manager: &Manager, tx: &mpsc::Sender<Msg>) {
        self.unfollow();
        let Some(session) = find_session(manager) else { return };
        let t = tx.clone();
        self.media = session
            .MediaPropertiesChanged(&TypedEventHandler::new(move |_, _| {
                let _ = t.send(Msg::Changed);
                Ok(())
            }))
            .ok();
        let t = tx.clone();
        self.playback = session
            .PlaybackInfoChanged(&TypedEventHandler::new(move |_, _| {
                let _ = t.send(Msg::Changed);
                Ok(())
            }))
            .ok();
        let t = tx.clone();
        self.timeline = session
            .TimelinePropertiesChanged(&TypedEventHandler::new(move |_, _| {
                let _ = t.send(Msg::Changed);
                Ok(())
            }))
            .ok();
        self.session = Some(session);
    }

    fn unfollow(&mut self) {
        let Some(session) = self.session.take() else { return };
        if let Some(token) = self.media.take() {
            let _ = session.RemoveMediaPropertiesChanged(token);
        }
        if let Some(token) = self.playback.take() {
            let _ = session.RemovePlaybackInfoChanged(token);
        }
        if let Some(token) = self.timeline.take() {
            let _ = session.RemoveTimelinePropertiesChanged(token);
        }
    }

    fn release(&mut self, manager: &Manager) {
        self.unfollow();
        if let Some(token) = self.manager_sessions.take() {
            let _ = manager.RemoveSessionsChanged(token);
        }
    }
}

fn current(generation: u64) -> bool {
    let shared = SHARED.lock().unwrap();
    shared.active && shared.generation == generation
}

fn listen(app: AppHandle, generation: u64, tx: mpsc::Sender<Msg>, rx: mpsc::Receiver<Msg>) {
    init_winrt();
    let manager = match request_manager() {
        Ok(m) => m,
        Err(err) => {
            crate::log::line(format!("spotify: no media session manager: {err}"));
            return;
        }
    };
    let mut hooks = Hooks::new(&manager, &tx);
    hooks.follow(&manager, &tx);
    update(&app, generation, hooks.session.as_ref());

    'listening: loop {
        let mut sessions_changed = match rx.recv_timeout(IDLE_WAIT) {
            Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Ok(Msg::Sessions) => true,
            Ok(Msg::Changed) => false,
            Err(RecvTimeoutError::Timeout) => continue,
        };
        std::thread::sleep(SETTLE);
        while let Ok(more) = rx.try_recv() {
            match more {
                Msg::Stop => break 'listening,
                Msg::Sessions => sessions_changed = true,
                Msg::Changed => {}
            }
        }
        if !current(generation) {
            break;
        }
        if sessions_changed {
            hooks.follow(&manager, &tx);
        }
        update(&app, generation, hooks.session.as_ref());
    }
    hooks.release(&manager);
}

/// Starts the listener when the pill is declared, stops it when it is not.
pub fn sync(app: &AppHandle, on: bool) {
    let (stale, generation, channel) = {
        let mut shared = SHARED.lock().unwrap();
        if shared.active == on {
            return;
        }
        shared.active = on;
        shared.generation += 1;
        shared.state = PlayerState { installed: installed(), ..PlayerState::default() };
        shared.cover = None;
        let stale = shared.wake.take();
        let channel = on.then(mpsc::channel::<Msg>);
        shared.wake = channel.as_ref().map(|(tx, _)| tx.clone());
        (stale, shared.generation, channel)
    };
    // A listener from before is told to go (it also notices the new generation).
    if let Some(tx) = stale {
        let _ = tx.send(Msg::Stop);
    }
    match channel {
        Some((tx, rx)) => {
            let app = app.clone();
            let spawned = std::thread::Builder::new()
                .name("coucou-spotify".into())
                .spawn(move || listen(app, generation, tx, rx));
            if let Err(err) = spawned {
                crate::log::line(format!("spotify: no listener thread: {err}"));
            }
        }
        None => {
            let state = SHARED.lock().unwrap().state.clone();
            emit_state(app, &state);
        }
    }
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// The player as it is now, read again from Spotify's session.
pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
    let generation = {
        let shared = SHARED.lock().unwrap();
        if !shared.active {
            return None;
        }
        shared.generation
    };
    init_winrt();
    let session = request_manager().ok().and_then(|m| find_session(&m));
    update(app, generation, session.as_ref())
}

pub fn control(app: &AppHandle, action: &str, value: Option<f64>) -> bool {
    let state = {
        let shared = SHARED.lock().unwrap();
        if !shared.active {
            return false;
        }
        shared.state.clone()
    };
    init_winrt();
    let Some(session) = request_manager().ok().and_then(|m| find_session(&m)) else { return false };
    let v = value.unwrap_or(0.0);
    let seek_to = state.track.as_ref().map(|t| v.clamp(0.0, (t.duration - 1.0).max(0.0)));
    let repeat_mode = if v != 0.0 { MediaPlaybackAutoRepeatMode::List } else { MediaPlaybackAutoRepeatMode::None };
    let done = (|| -> windows::core::Result<bool> {
        Ok(match action {
            "playPause" => session.TryTogglePlayPauseAsync()?.get()?,
            "next" => session.TrySkipNextAsync()?.get()?,
            "previous" => session.TrySkipPreviousAsync()?.get()?,
            "seek" => match seek_to {
                Some(target) => session.TryChangePlaybackPositionAsync((target * 10_000_000.0) as i64)?.get()?,
                None => false,
            },
            "shuffle" => session.TryChangeShuffleActiveAsync(v != 0.0)?.get()?,
            "repeat" => session.TryChangeAutoRepeatModeAsync(repeat_mode)?.get()?,
            // SMTC has no volume.
            _ => false,
        })
    })()
    .unwrap_or(false);
    if !done {
        return false;
    }
    // Spotify doesn't always signal these at once: show them, as the Mac does.
    let now = now_ms();
    let next = {
        let mut shared = SHARED.lock().unwrap();
        match action {
            "seek" => {
                if let Some(target) = seek_to {
                    shared.state.position = target;
                    shared.state.position_at = now;
                }
            }
            "shuffle" => shared.state.shuffle = v != 0.0,
            "repeat" => shared.state.repeat = v != 0.0,
            _ => return true,
        }
        shared.state.clone()
    };
    emit_state(app, &next);
    true
}

// ── Launching ─────────────────────────────────────────────────────────────────

/// Whether there is a Spotify to start: the desktop build, the Store build, or
/// the Store's launcher alias.
pub fn installed() -> bool {
    let var = |name: &str| std::env::var_os(name).map(std::path::PathBuf::from);
    if var("APPDATA").is_some_and(|p| p.join("Spotify").join("Spotify.exe").is_file()) {
        return true;
    }
    let Some(local) = var("LOCALAPPDATA") else { return false };
    if local.join("Microsoft").join("WindowsApps").join("Spotify.exe").exists() {
        return true;
    }
    std::fs::read_dir(local.join("Packages"))
        .map(|dir| {
            dir.flatten().any(|e| e.file_name().to_string_lossy().to_ascii_lowercase().starts_with("spotifyab.spotifymusic_"))
        })
        .unwrap_or(false)
}

/// "Open Spotify": the `spotify:` protocol starts it, or brings the running one
/// forward. Without Spotify, its download page.
pub fn open() -> bool {
    if installed() {
        crate::platform::open_url("spotify:");
        true
    } else {
        crate::platform::open_url(DOWNLOAD_URL);
        false
    }
}
