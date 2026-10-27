// The Apple Music pill — port of MusicController.swift for Windows.
//
// On Windows, Apple Music (and iTunes) publishes what it plays to the
// Global System Media Transport Controls (GSMTC), the same overlay media keys use.
// Windows hands that session to us through GlobalSystemMediaTransportControlsSessionManager:
// track metadata, thumbnail, status, timeline, shuffle and repeat, with real-time change events.
//
// Volume is controlled through the Windows mixer (Core Audio) for the Apple Music process.
//
// The island receives:
// - "music" event: PlayerState
// - "music-artwork" event: cover data URL

#![cfg_attr(not(windows), allow(dead_code))]

use serde::Serialize;
use tauri::AppHandle;

pub const PILL_ID: &str = "integration_music";
pub const DOWNLOAD_URL: &str = "https://apps.microsoft.com/detail/9PFHDD62MXS1";

const STATE_EVENT: &str = "music";
const ARTWORK_EVENT: &str = "music-artwork";
const ARTWORK_LIMIT: usize = 3 * 1024 * 1024;

// ── Models ───────────────────────────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration: f64,
    pub art_url: Option<String>,
    pub object_path: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayerState {
    pub installed: bool,
    pub running: bool,
    pub playing: bool,
    pub track: Option<Track>,
    pub position: f64,
    pub position_at: Option<f64>,
    pub volume: i32,
    pub shuffle: bool,
    pub repeat: bool,
}

impl PlayerState {
    pub fn anchor(&mut self, position: f64, position_at: f64) {
        self.position = position;
        self.position_at = Some(position_at);
    }

    pub fn clear(&mut self, now_ms: f64) {
        self.playing = false;
        self.track = None;
        self.anchor(0.0, now_ms);
        self.shuffle = false;
        self.repeat = false;
    }
}

pub fn short_title(raw: &str) -> String {
    crate::spotify::short_title(raw)
}

pub fn short_artist(raw: &str) -> String {
    crate::spotify::short_artist(raw)
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Artwork {
    art_url: String,
    data_url: String,
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

fn emit_state(app: &AppHandle, state: &PlayerState) {
    use tauri::Emitter;
    let _ = app.emit_to(crate::island::WINDOW_LABEL, STATE_EVENT, state);
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn music_refresh(app: AppHandle) -> Option<PlayerState> {
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

#[tauri::command]
pub async fn music_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
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

#[tauri::command]
pub async fn music_open() -> bool {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(win::open).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

#[tauri::command]
pub fn music_installed() -> bool {
    #[cfg(windows)]
    {
        win::installed()
    }
    #[cfg(not(windows))]
    {
        false
    }
}

pub fn sync(app: &AppHandle, active_integrations: &[String]) {
    let on = active_integrations.iter().any(|id| id == PILL_ID);
    #[cfg(windows)]
    win::sync(app, on);
    #[cfg(not(windows))]
    let _ = (app, on);
}

// ── Windows implementation ────────────────────────────────────────────────────

pub fn is_apple_music_app(app_id: &str) -> bool {
    let lower = app_id.to_ascii_lowercase();
    lower.contains("applemusic") || lower.contains("apple.music") || lower.contains("itunes")
}

pub fn windows_music_track(title: &str, artist: &str, album: &str, duration: f64) -> Option<Track> {
    let title = title.trim();
    if title.is_empty() {
        return None;
    }
    let artist = artist.trim();
    let album = album.trim();
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in [artist, album, title].join("\u{1f}").bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    Some(Track {
        id: format!("applemusic:track:{hash:016x}"),
        title: short_title(title),
        artist: short_artist(artist),
        album: album.to_string(),
        duration: duration.max(0.0),
        art_url: Some(format!("smtc:music:{hash:016x}")),
        object_path: String::new(),
    })
}

#[cfg(windows)]
mod win {
    use super::*;
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{LazyLock, Mutex};

    use windows::core::Interface;
    use windows::Foundation::TypedEventHandler;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionMediaProperties as MediaProperties,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Media::MediaPlaybackAutoRepeatMode;
    use windows::Storage::Streams::DataReader;
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::Media::Audio::{
        eMultimedia, eRender, IAudioSessionControl2, IAudioSessionManager2, IMMDeviceEnumerator, ISimpleAudioVolume,
        MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    enum Wake {
        Changed,
        Sessions,
        Stop,
    }

    struct Shared {
        generation: u64,
        active: bool,
        wake: Option<Sender<Wake>>,
        state: PlayerState,
    }

    static SHARED: LazyLock<Mutex<Shared>> =
        LazyLock::new(|| Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default() }));

    static ART: LazyLock<Mutex<VecDeque<(String, String)>>> = LazyLock::new(|| Mutex::new(VecDeque::new()));
    static LAST_RAW_THUMBNAIL: LazyLock<Mutex<Option<(String, Vec<u8>)>>> = LazyLock::new(|| Mutex::new(None));

    fn com() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    pub fn sync(app: &AppHandle, on: bool) {
        let (tx, rx) = mpsc::channel();
        let (old, generation, state) = {
            let mut s = SHARED.lock().unwrap();
            if s.active == on {
                return;
            }
            s.active = on;
            s.generation += 1;
            s.state = PlayerState { installed: installed(), ..PlayerState::default() };
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
                .name("coucou-music".into())
                .spawn(move || listen(app, generation, tx, rx));
            if let Err(err) = spawned {
                crate::log::line(format!("apple music: no listener thread: {err}"));
            }
        } else {
            emit_state(app, &state);
        }
    }

    fn listen(app: AppHandle, generation: u64, tx: Sender<Wake>, rx: Receiver<Wake>) {
        com();
        let manager = match Manager::RequestAsync().and_then(|op| op.get()) {
            Ok(m) => m,
            Err(err) => {
                crate::log::line(format!("apple music: no media sessions: {err}"));
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
            .find(|s| s.SourceAppUserModelId().is_ok_and(|id| is_apple_music_app(&id.to_string_lossy())))
    }

    struct Snapshot {
        track: Option<Track>,
        playing: bool,
        position: f64,
        updated_at: Option<f64>,
        shuffle: bool,
        repeat: bool,
    }

    fn snapshot(session: &Session) -> windows::core::Result<(Snapshot, MediaProperties)> {
        let props = session.TryGetMediaPropertiesAsync()?.get()?;
        let timeline = session.GetTimelineProperties()?;
        let info = session.GetPlaybackInfo()?;

        let title = props.Title()?.to_string_lossy();
        let artist = props.Artist()?.to_string_lossy();
        let album = props.AlbumTitle()?.to_string_lossy();
        let duration = crate::spotify::ticks_to_secs(timeline.EndTime()?.Duration);
        let track = windows_music_track(&title, &artist, &album, duration);

        let playing = info.PlaybackStatus()? == Status::Playing;
        let position = crate::spotify::ticks_to_secs(timeline.Position()?.Duration);
        let updated_at = crate::spotify::windows_time_to_unix_ms(timeline.LastUpdatedTime()?.UniversalTime);

        let shuffle = info.IsShuffleActive().ok().and_then(|b| b.Value().ok()).unwrap_or(false);
        let repeat = info
            .AutoRepeatMode()
            .ok()
            .and_then(|m| m.Value().ok())
            .map(|m| m != MediaPlaybackAutoRepeatMode::None)
            .unwrap_or(false);

        let snapshot = Snapshot {
            track,
            playing,
            position,
            updated_at,
            shuffle,
            repeat,
        };
        Ok((snapshot, props))
    }

    fn read_and_emit(app: &AppHandle, generation: u64, session: Option<&Session>) {
        let read = session.and_then(|s| snapshot(s).ok());
        let volume = read.as_ref().and_then(|_| music_audio_volume());
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
                    let at = snap.updated_at.filter(|&t| t <= now).unwrap_or(now);
                    s.state.anchor(snap.position, at);
                    s.state.shuffle = snap.shuffle;
                    s.state.repeat = snap.repeat;
                    if let Some(v) = volume {
                        s.state.volume = v;
                    }
                    Some(props)
                }
                None => {
                    s.state.running = false;
                    s.state.installed = installed();
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

    fn artwork(app: &AppHandle, track: &Track, props: &MediaProperties) {
        use tauri::Emitter;
        let Some(key) = track.art_url.clone() else { return };

        let cached = ART.lock().unwrap().iter().find(|(k, _)| *k == key).map(|(_, d)| d.clone());
        if let Some(data) = cached {
            let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: key, data_url: data });
            return;
        }

        let Some(bytes) = thumbnail(props) else {
            retry_artwork(app.clone(), track.clone(), 200);
            return;
        };

        // Check if the read bytes match the PREVIOUS track's thumbnail (stale SMTC stream)
        let is_stale = {
            let last = LAST_RAW_THUMBNAIL.lock().unwrap();
            match last.as_ref() {
                Some((last_key, last_bytes)) => *last_key != key && *last_bytes == bytes,
                None => false,
            }
        };

        if is_stale {
            retry_artwork(app.clone(), track.clone(), 250);
            return;
        }

        let Some(mime) = crate::spotify::sniff_image(&bytes) else { return };
        let data = format!("data:{mime};base64,{}", crate::claude::base64_for(&bytes));
        {
            let mut art = ART.lock().unwrap();
            art.push_back((key.clone(), data.clone()));
            while art.len() > 12 {
                art.pop_front();
            }
            let mut last = LAST_RAW_THUMBNAIL.lock().unwrap();
            *last = Some((key.clone(), bytes));
        }
        let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: key, data_url: data });
    }

    fn retry_artwork(app: AppHandle, track: Track, delay_ms: u64) {
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(delay_ms));
            com();
            let Some(manager) = Manager::RequestAsync().and_then(|op| op.get()).ok() else { return };
            let Some(session) = find_session(&manager) else { return };
            let Ok(props) = session.TryGetMediaPropertiesAsync().and_then(|op| op.get()) else { return };

            let current_key = {
                let s = SHARED.lock().unwrap();
                s.state.track.as_ref().and_then(|t| t.art_url.clone())
            };
            if current_key.as_deref() != track.art_url.as_deref() {
                return;
            }

            if let Some(bytes) = thumbnail(&props) {
                let key = match track.art_url.clone() {
                    Some(k) => k,
                    None => return,
                };
                let is_stale = {
                    let last = LAST_RAW_THUMBNAIL.lock().unwrap();
                    match last.as_ref() {
                        Some((last_key, last_bytes)) => *last_key != key && *last_bytes == bytes,
                        None => false,
                    }
                };
                if is_stale {
                    if delay_ms < 500 {
                        retry_artwork(app, track, 400);
                    }
                    return;
                }
                if let Some(mime) = crate::spotify::sniff_image(&bytes) {
                    let data = format!("data:{mime};base64,{}", crate::claude::base64_for(&bytes));
                    {
                        let mut art = ART.lock().unwrap();
                        art.push_back((key.clone(), data.clone()));
                        while art.len() > 12 {
                            art.pop_front();
                        }
                        let mut last = LAST_RAW_THUMBNAIL.lock().unwrap();
                        *last = Some((key.clone(), bytes));
                    }
                    use tauri::Emitter;
                    let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: key, data_url: data });
                }
            }
        });
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

    // ── Volume ────────────────────────────────────────────────────────────────

    fn is_apple_music_session(control: &IAudioSessionControl2) -> bool {
        unsafe {
            if let Ok(id) = control.GetSessionIdentifier() {
                let id_str = id.to_string().unwrap_or_default().to_ascii_lowercase();
                if id_str.contains("applemusic") || id_str.contains("apple.music") || id_str.contains("itunes") {
                    return true;
                }
            }
            if let Ok(id) = control.GetSessionInstanceIdentifier() {
                let id_str = id.to_string().unwrap_or_default().to_ascii_lowercase();
                if id_str.contains("applemusic") || id_str.contains("apple.music") || id_str.contains("itunes") {
                    return true;
                }
            }
            let pid = control.GetProcessId().unwrap_or(0);
            if pid != 0 && is_apple_music_process(pid) {
                return true;
            }
            false
        }
    }

    fn music_audio() -> Vec<ISimpleAudioVolume> {
        com();
        let mut out = Vec::new();
        unsafe {
            let Ok(devices) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else {
                return out;
            };
            let Ok(device) = devices.GetDefaultAudioEndpoint(eRender, eMultimedia) else { return out };
            let Ok(manager) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) else { return out };
            let Ok(sessions) = manager.GetSessionEnumerator() else { return out };
            for i in 0..sessions.GetCount().unwrap_or(0) {
                let Ok(control) = sessions.GetSession(i) else { continue };
                let Ok(control) = control.cast::<IAudioSessionControl2>() else { continue };
                if is_apple_music_session(&control) {
                    if let Ok(volume) = control.cast::<ISimpleAudioVolume>() {
                        out.push(volume);
                    }
                }
            }
        }
        out
    }

    fn is_apple_music_process(pid: u32) -> bool {
        unsafe {
            let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            let named = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
            let _ = CloseHandle(process);
            if named.is_err() {
                return false;
            }
            let path = String::from_utf16_lossy(&buf[..len as usize]).to_ascii_lowercase();
            path.contains("applemusic") || path.contains("itunes")
        }
    }

    fn music_audio_volume() -> Option<i32> {
        let level = unsafe { music_audio().first()?.GetMasterVolume().ok()? };
        Some((level * 100.0).round().clamp(0.0, 100.0) as i32)
    }

    fn set_music_volume(percent: f64) -> bool {
        let level = (percent / 100.0).clamp(0.0, 1.0) as f32;
        let sessions = music_audio();
        let mut done = false;
        for volume in &sessions {
            done |= unsafe { volume.SetMasterVolume(level, std::ptr::null()).is_ok() };
        }
        done
    }

    // ── Controls ──────────────────────────────────────────────────────────────

    pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
        let generation = {
            let s = SHARED.lock().unwrap();
            if !s.active {
                return None;
            }
            s.generation
        };
        com();
        let manager = Manager::RequestAsync().and_then(|op| op.get()).ok()?;
        let session = find_session(&manager);
        read_and_emit(app, generation, session.as_ref());
        let s = SHARED.lock().unwrap();
        s.state.running.then(|| s.state.clone())
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
            "seek" => {
                let Some(target) = seek_to else { return false };
                let target_ticks = (target * 10_000_000.0) as i64;
                let start_ticks = session
                    .GetTimelineProperties()
                    .ok()
                    .and_then(|t| t.StartTime().ok())
                    .map(|s| s.Duration)
                    .unwrap_or(0);
                let ok = asked!(session.TryChangePlaybackPositionAsync(start_ticks + target_ticks));
                if !ok && start_ticks != 0 {
                    asked!(session.TryChangePlaybackPositionAsync(target_ticks))
                } else {
                    ok
                }
            }
            "shuffle" => asked!(session.TryChangeShuffleActiveAsync(v != 0.0)),
            "repeat" => asked!(session.TryChangeAutoRepeatModeAsync(if v != 0.0 {
                MediaPlaybackAutoRepeatMode::List
            } else {
                MediaPlaybackAutoRepeatMode::None
            })),
            "volume" => {
                let _ = set_music_volume(v);
                true
            }
            _ => false,
        };
        if !done {
            return false;
        }
        let optimistic = matches!(action, "seek" | "shuffle" | "repeat" | "volume");
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
                    "repeat" => s.state.repeat = v != 0.0,
                    _ => s.state.volume = v.round().clamp(0.0, 100.0) as i32,
                }
                s.state.clone()
            };
            emit_state(app, &state);
        }
        true
    }

    // ── Launching ─────────────────────────────────────────────────────────────

    pub fn installed() -> bool {
        let under = |var: &str, rest: &str| std::env::var_os(var).map(|base| PathBuf::from(base).join(rest));
        let store = under("LOCALAPPDATA", r"Microsoft\WindowsApps\AppleMusic.exe")
            .is_some_and(|p| std::fs::symlink_metadata(p).is_ok());
        let itunes = under("ProgramFiles", r"iTunes\iTunes.exe").is_some_and(|p| p.is_file());
        let itunes_x86 = under("ProgramFiles(x86)", r"iTunes\iTunes.exe").is_some_and(|p| p.is_file());
        store || itunes || itunes_x86
    }

    pub fn open() -> bool {
        let running = SHARED.lock().unwrap().state.running;
        if running || installed() {
            let launched = std::process::Command::new("explorer.exe")
                .arg("shell:AppsFolder\\AppleInc.AppleMusicWin_nzyj5cx40ttqa!App")
                .spawn()
                .is_ok();
            let _ = crate::platform::open_url("music:");
            if !launched {
                let _ = crate::platform::open_url("itunes:");
            }
            return true;
        }
        let _ = crate::platform::open_url("ms-windows-store://pdp/?ProductId=9PFHDD62MXS1");
        crate::platform::open_url(DOWNLOAD_URL);
        false
    }
}
