// The Yandex Music pill — Windows counterpart of YandexMusicController.swift.
//
// Yandex Music (the desktop app, an Electron app) publishes what it plays to the
// system media controls through `navigator.mediaSession`, like Spotify does. On
// Windows Coucou reads that session through
// GlobalSystemMediaTransportControlsSessionManager: track, thumbnail, status and
// timeline as properties with change events, and play/pause, skip and seek as
// requests. The volume isn't part of it; it is the app's own volume in the
// Windows mixer (Core Audio), read whenever the rest is.
//
// Nothing runs on a timer. While the pill is declared, one thread waits on the
// session's events. Turning the pill off ends the thread. There is no official
// Yandex Music client on Linux, and the Mac side is Swift: here Linux and macOS
// are stubs (nothing is read, nothing is driven).
//
// The state and the events have the same shape as the Spotify pill's, so the
// island's page reuses the same types: `yandex-music` carries a `PlayerState`,
// `yandex-music-artwork` carries `{ artUrl, dataUrl }`. Shuffle and repeat are
// always false (the media session of this app does not offer them to us).

#![cfg_attr(not(windows), allow(dead_code))]

use serde::Serialize;
use tauri::AppHandle;

use crate::spotify::{short_artist, short_title, sniff_image, PlayerState, Track};

pub const PILL_ID: &str = "integration_yandex_music";
/// Where "Get Yandex Music" leads when it isn't installed.
pub const DOWNLOAD_URL: &str = "https://music.yandex.ru/download/";
/// Island events: the player's state, and a track's cover as a data URL.
const STATE_EVENT: &str = "yandex-music";
const ARTWORK_EVENT: &str = "yandex-music-artwork";
/// The biggest cover we read.
const ARTWORK_LIMIT: usize = 3 * 1024 * 1024;

// ── Pure parts ────────────────────────────────────────────────────────────────

/// "Yandex Music" or "Яндекс Музыка", in any case, anywhere in the name.
fn is_yandex_music_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    (lower.contains("yandex") && lower.contains("music")) || (lower.contains("яндекс") && lower.contains("музык"))
}

/// The media session ids the app registers: "ru.yandex.desktop.music",
/// "Яндекс Музыка.exe", or the Microsoft Store's "A025C540.Yandex.Music_…!App".
pub fn is_yandex_music_app(app_id: &str) -> bool {
    is_yandex_music_name(app_id)
}

/// The app's executable name ("Яндекс Музыка.exe", "YandexMusic.exe"), to find
/// its audio sessions in the Windows mixer.
pub fn is_yandex_music_exe(file_name: &str) -> bool {
    is_yandex_music_name(file_name)
}

/// What the media session says about the track → the track, or None when
/// nothing is loaded. Windows gives no track URI, so the id is made from the
/// tags (FNV-1a, short and stable for the same tags).
pub fn yandex_track(title: &str, artist: &str, album: &str, duration: f64) -> Option<Track> {
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
        id: format!("yandex:track:{hash:016x}"),
        title: short_title(title),
        artist: short_artist(artist),
        album: album.to_string(),
        duration: duration.max(0.0),
        // Not a URL: the thumbnail is read from the session itself. The page
        // only uses it to match a cover to its track.
        art_url: Some(format!("smtc:{hash:016x}")),
        object_path: String::new(),
    })
}

fn data_url(bytes: &[u8]) -> Option<String> {
    let mime = sniff_image(bytes)?;
    Some(format!("data:{mime};base64,{}", crate::claude::base64_for(bytes)))
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

/// The player as it is now, read again from the media session (the card coming
/// on screen: seeks made in the app's own window are not always signalled).
#[tauri::command]
pub async fn yandex_music_refresh(app: AppHandle) -> Option<PlayerState> {
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
/// `seek` (seconds), `volume` (0…100).
#[tauri::command]
pub async fn yandex_music_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
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

/// "Open Yandex Music": brings it forward, or starts it. Without it, its
/// download page. True when the app was reached or started.
#[tauri::command]
pub async fn yandex_music_open() -> bool {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(win::open).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// For Settings: whether there is a Yandex Music to launch.
#[tauri::command]
pub fn yandex_music_installed() -> bool {
    #[cfg(windows)]
    {
        win::installed()
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
    win::sync(app, on);
    #[cfg(not(windows))]
    let _ = (app, on);
}

// ── Windows: the system media controls ────────────────────────────────────────

#[cfg(windows)]
mod win {
    use super::*;
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{LazyLock, Mutex};
    use std::time::{Duration, Instant};

    use windows::core::Interface;
    use windows::Foundation::TypedEventHandler;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionMediaProperties as MediaProperties,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
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

    use crate::spotify::{ticks_to_secs, windows_time_to_unix_ms};

    /// What wakes the listener.
    enum Wake {
        /// The session's track, status or timeline moved.
        Changed,
        /// A player appeared or went away: find the app's session again.
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

    static SHARED: LazyLock<Mutex<Shared>> =
        LazyLock::new(|| Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default() }));

    /// Covers already read, by the track's art key; the newest last.
    static ART: LazyLock<Mutex<VecDeque<(String, String)>>> = LazyLock::new(|| Mutex::new(VecDeque::new()));

    /// WinRT and Core Audio need COM on the calling thread. A thread that has it
    /// already, in either model, keeps it.
    fn com() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    /// Where playback was at `at` (Unix ms), as the state keeps it.
    fn anchor(state: &mut PlayerState, position: f64, at: f64) {
        state.position = position.max(0.0);
        state.position_at = at;
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
                .name("coucou-yandex-music".into())
                .spawn(move || listen(app, generation, tx, rx));
            if let Err(err) = spawned {
                crate::log::line(format!("yandex-music: no listener thread: {err}"));
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
                crate::log::line(format!("yandex-music: no media sessions: {err}"));
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

    /// The app's session, with the event handlers that wake the listener.
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
            .find(|s| s.SourceAppUserModelId().is_ok_and(|id| is_yandex_music_app(&id.to_string_lossy())))
    }

    // ── Reading ───────────────────────────────────────────────────────────────

    /// Everything the session says, as it is now.
    struct Snapshot {
        track: Option<Track>,
        playing: bool,
        position: f64,
        /// When Windows last updated the position (Unix ms), if it says.
        updated_at: Option<f64>,
    }

    fn snapshot(session: &Session) -> windows::core::Result<(Snapshot, MediaProperties)> {
        let props = session.TryGetMediaPropertiesAsync()?.get()?;
        let timeline = session.GetTimelineProperties()?;
        let start = timeline.StartTime()?.Duration;
        let duration = ticks_to_secs(timeline.EndTime()?.Duration - start);
        let track = yandex_track(
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
        };
        Ok((snapshot, props))
    }

    fn read_and_emit(app: &AppHandle, generation: u64, session: Option<&Session>) {
        let read = session.and_then(|s| snapshot(s).ok());
        let volume = read.as_ref().and_then(|_| yandex_volume());
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
                    anchor(&mut s.state, snap.position, at);
                    s.state.shuffle = false;
                    s.state.repeat = false;
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

    // ── Artwork ───────────────────────────────────────────────────────────────

    /// The track's cover, as a data URL (the page may not load anything
    /// remote). Read once per track; the app sometimes adds the thumbnail a
    /// moment after the title, and the next event brings it then.
    fn artwork(app: &AppHandle, track: &Track, props: &MediaProperties) {
        use tauri::Emitter;
        let Some(key) = track.art_url.clone() else { return };
        let cached = ART.lock().unwrap().iter().find(|(k, _)| *k == key).map(|(_, d)| d.clone());
        let data = match cached {
            Some(data) => data,
            None => {
                let Some(data) = thumbnail(props).as_deref().and_then(data_url) else { return };
                let mut art = ART.lock().unwrap();
                art.push_back((key.clone(), data.clone()));
                while art.len() > 12 {
                    art.pop_front();
                }
                data
            }
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

    // ── Volume: Yandex Music in the Windows mixer ─────────────────────────────

    /// The app's audio sessions on the default output (Electron plays from a
    /// child process of the same executable).
    fn yandex_audio() -> Vec<ISimpleAudioVolume> {
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
                let pid = control.GetProcessId().unwrap_or(0);
                if pid != 0 && is_yandex_process(pid) {
                    if let Ok(volume) = control.cast::<ISimpleAudioVolume>() {
                        out.push(volume);
                    }
                }
            }
        }
        out
    }

    fn is_yandex_process(pid: u32) -> bool {
        unsafe {
            let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            let named = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
            let _ = CloseHandle(process);
            if named.is_err() {
                return false;
            }
            let path = String::from_utf16_lossy(&buf[..len as usize]);
            path.rsplit(['\\', '/']).next().is_some_and(is_yandex_music_exe)
        }
    }

    /// 0…100, or None while the app has no audio session (nothing played yet).
    fn yandex_volume() -> Option<i32> {
        let level = unsafe { yandex_audio().first()?.GetMasterVolume().ok()? };
        Some((level * 100.0).round().clamp(0.0, 100.0) as i32)
    }

    fn set_yandex_volume(percent: f64) -> bool {
        let level = (percent / 100.0).clamp(0.0, 1.0) as f32;
        let sessions = yandex_audio();
        let mut done = false;
        for volume in &sessions {
            done |= unsafe { volume.SetMasterVolume(level, std::ptr::null()).is_ok() };
        }
        done
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
            "volume" => set_yandex_volume(v),
            _ => false,
        };
        if !done {
            return false;
        }
        // Show these at once, as the Mac does; the session's events confirm them.
        let optimistic = matches!(action, "seek" | "volume");
        if optimistic {
            let state = {
                let mut s = SHARED.lock().unwrap();
                match action {
                    "seek" => {
                        if let Some(target) = seek_to {
                            anchor(&mut s.state, target, now_ms());
                        }
                    }
                    _ => s.state.volume = v.round().clamp(0.0, 100.0) as i32,
                }
                s.state.clone()
            };
            emit_state(app, &state);
        }
        true
    }

    // ── Launching ─────────────────────────────────────────────────────────────

    /// Whether Windows knows the `yandexmusic:` URI scheme the app registers
    /// (per user or per machine). Asked of `reg.exe`, and remembered for a
    /// minute, since this is read on every event while the app isn't running.
    fn scheme_registered() -> bool {
        static CACHE: LazyLock<Mutex<Option<(Instant, bool)>>> = LazyLock::new(|| Mutex::new(None));
        if let Some((at, found)) = *CACHE.lock().unwrap() {
            if at.elapsed() < Duration::from_secs(60) {
                return found;
            }
        }
        let has = |root: &str| {
            let mut cmd = std::process::Command::new("reg.exe");
            cmd.args(["query", &format!(r"{root}\Software\Classes\yandexmusic")])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            crate::platform::no_console(&mut cmd).status().is_ok_and(|status| status.success())
        };
        let found = has("HKCU") || has("HKLM");
        *CACHE.lock().unwrap() = Some((Instant::now(), found));
        found
    }

    /// The per-user install, a Microsoft Store alias, or the registered
    /// `yandexmusic:` scheme (any other install location).
    pub fn installed() -> bool {
        let under = |var: &str, rest: &str| std::env::var_os(var).map(|base| PathBuf::from(base).join(rest));
        if under("LOCALAPPDATA", r"Programs\YandexMusic").is_some_and(|p| p.is_dir()) {
            return true;
        }
        // An app execution alias is a reparse point that is_file() can't open.
        let aliases = under("LOCALAPPDATA", r"Microsoft\WindowsApps").and_then(|dir| std::fs::read_dir(dir).ok());
        if let Some(entries) = aliases {
            let aliased = entries.flatten().any(|entry| {
                let name = entry.file_name().to_string_lossy().to_lowercase();
                name.ends_with(".exe") && is_yandex_music_exe(&name)
            });
            if aliased {
                return true;
            }
        }
        scheme_registered()
    }

    /// The app's URI scheme brings it forward, or starts it. Without the app,
    /// its download page.
    pub fn open() -> bool {
        let running = SHARED.lock().unwrap().state.running;
        if running || installed() {
            crate::platform::open_url("yandexmusic://");
            return true;
        }
        crate::platform::open_url(DOWNLOAD_URL);
        false
    }
}

// ── Tests (the pure parts) ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_app_is_found_by_its_session_id() {
        assert!(is_yandex_music_app("ru.yandex.desktop.music"));
        assert!(is_yandex_music_app("Яндекс Музыка.exe"));
        assert!(is_yandex_music_app("A025C540.Yandex.Music_xyz!App"));
        assert!(is_yandex_music_app("YandexMusic.exe"));
        assert!(!is_yandex_music_app("Spotify.exe"));
        assert!(!is_yandex_music_app("MSEdge"));
        assert!(!is_yandex_music_app("Yandex.ABCD"));
        assert!(!is_yandex_music_app(""));
    }

    #[test]
    fn the_app_is_found_by_its_executable() {
        assert!(is_yandex_music_exe("Яндекс Музыка.exe"));
        assert!(is_yandex_music_exe("YandexMusic.exe"));
        assert!(is_yandex_music_exe("yandex music.EXE"));
        assert!(!is_yandex_music_exe("spotify.exe"));
        assert!(!is_yandex_music_exe("browser.exe"));
        assert!(!is_yandex_music_exe("Yandex.exe"));
    }

    #[test]
    fn a_track_gets_a_stable_id_and_a_cover_key() {
        let a = yandex_track("Song", "Artist", "Album", 200.0).unwrap();
        let b = yandex_track("  Song ", " Artist", "Album ", 200.0).unwrap();
        assert!(a.id.starts_with("yandex:track:"));
        assert_eq!(a.id.len(), "yandex:track:".len() + 16);
        assert_eq!(a.id, b.id);
        let hash = a.id.trim_start_matches("yandex:track:");
        assert_eq!(a.art_url.as_deref(), Some(format!("smtc:{hash}").as_str()));
        assert_eq!(a.duration, 200.0);
        assert_eq!(a.album, "Album");

        let other = yandex_track("Song", "Someone else", "Album", 200.0).unwrap();
        assert_ne!(a.id, other.id);
        // No artist or album is still a track here (there are no ads to tell apart).
        assert!(yandex_track("Song", "", "", 0.0).unwrap().id.starts_with("yandex:track:"));
    }

    #[test]
    fn an_empty_title_is_no_track() {
        assert_eq!(yandex_track("", "Artist", "Album", 10.0), None);
        assert_eq!(yandex_track("   ", "Artist", "Album", 10.0), None);
    }

    #[test]
    fn titles_and_artists_are_cut_like_the_mac() {
        let track = yandex_track("Песня - Remastered (Live)", "Артист feat. Гость", "Альбом", -5.0).unwrap();
        assert_eq!(track.title, "Песня");
        assert_eq!(track.artist, "Артист");
        assert_eq!(track.album, "Альбом");
        assert_eq!(track.duration, 0.0);
    }

    #[test]
    fn the_state_goes_to_the_page_in_camel_case() {
        let state = PlayerState {
            running: true,
            installed: true,
            track: yandex_track("Song", "Artist", "Album", 120.0),
            playing: true,
            position: 12.5,
            position_at: 1_000.0,
            shuffle: false,
            repeat: false,
            volume: 40,
        };
        let json = serde_json::to_value(&state).unwrap();
        assert_eq!(json["running"], true);
        assert_eq!(json["positionAt"], 1_000.0);
        assert_eq!(json["shuffle"], false);
        assert_eq!(json["repeat"], false);
        assert_eq!(json["volume"], 40);
        assert_eq!(json["track"]["title"], "Song");
        assert!(json["track"]["artUrl"].as_str().unwrap().starts_with("smtc:"));
        assert!(json["track"]["id"].as_str().unwrap().starts_with("yandex:track:"));
        assert!(json["track"].get("objectPath").is_none());

        let art = serde_json::to_value(Artwork { art_url: "smtc:1".into(), data_url: "data:image/png;base64,AA".into() }).unwrap();
        assert_eq!(art["artUrl"], "smtc:1");
        assert_eq!(art["dataUrl"], "data:image/png;base64,AA");
    }
}
