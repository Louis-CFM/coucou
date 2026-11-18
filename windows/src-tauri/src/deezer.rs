//! The Deezer pill's backend (Windows): the system media controls session of
//! the Deezer app, as spotify.rs does for Spotify. Deezer gives no album,
//! shuffle or repeat, so the state leaves them at their defaults.


use tauri::AppHandle;

pub use crate::spotify::{PlayerState, Track};

pub const PILL_ID: &str = "integration_deezer";
pub const STATE_EVENT: &str = "deezer";
pub const ARTWORK_EVENT: &str = "deezer-artwork";
/// The Microsoft Store package, and the app id it registers with Windows.
const PACKAGE_FAMILY: &str = "Deezer.62021768415AF_q7m17pa7q8kj0";
const APP_ID: &str = "Deezer.62021768415AF_q7m17pa7q8kj0!Deezer.Music";
/// Without Deezer: the Store's search for it (no download page is verified).
const STORE_URL: &str = "ms-windows-store://search/?query=Deezer";

/// The Microsoft Store app registers "Deezer.62021768415AF_…!Deezer.Music".
pub fn is_deezer_app(app_id: &str) -> bool {
    app_id.to_ascii_lowercase().contains("deezer")
}

/// What the session says about the track → the track, or None when nothing is
/// loaded. The Deezer session gives no album.
pub fn windows_track(title: &str, artist: &str, album: &str, duration: f64) -> Option<Track> {
    let title = title.trim();
    if title.is_empty() {
        return None;
    }
    let artist = artist.trim();
    let album = album.trim();
    // FNV-1a: a short, stable id for the same tags.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in [artist, album, title].join("\u{1f}").bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    Some(Track {
        id: format!("deezer:track:{hash:016x}"),
        title: title.to_string(),
        artist: artist.to_string(),
        album: album.to_string(),
        duration: duration.max(0.0),
        // Not a URL: the page only uses it to match a cover to its track.
        art_url: Some(format!("smtc:{hash:016x}")),
        object_path: String::new(),
    })
}

/// The audio session belongs to one of Deezer's several processes.
fn is_deezer_exe(path: &str) -> bool {
    path.rsplit(['\\', '/']).next().is_some_and(|name| name.eq_ignore_ascii_case("deezer.exe"))
}

/// Where a seek lands: inside the track, a second short of its end.
fn seek_target(duration: f64, wanted: f64) -> f64 {
    wanted.clamp(0.0, (duration - 1.0).max(0.0))
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// The player as it is now, read again from the session.
#[tauri::command]
pub async fn deezer_refresh(app: AppHandle) -> Option<PlayerState> {
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

/// `playPause`, `next`, `previous`, `seek` (seconds), `volume` (0…100).
#[tauri::command]
pub async fn deezer_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
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

/// Brings Deezer forward or starts it; without Deezer, its download page.
#[tauri::command]
pub async fn deezer_open() -> bool {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(win::open).await.unwrap_or(false)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// For Settings: whether there is a Deezer to launch.
#[tauri::command]
pub fn deezer_installed() -> bool {
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
pub fn sync(app: &AppHandle, active_integrations: &[String]) {
    let on = active_integrations.iter().any(|id| id == PILL_ID);
    #[cfg(windows)]
    win::sync(app, on);
    #[cfg(not(windows))]
    let _ = (app, on);
}

#[cfg(windows)]
mod win {
    use super::*;
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::sync::mpsc::{self, Receiver, Sender};
    use std::sync::{LazyLock, Mutex};

    use tauri::Emitter;
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

    use crate::spotify::{data_url, now_ms, ticks_to_secs, windows_time_to_unix_ms, Artwork, ARTWORK_LIMIT};

    /// What wakes the listener.
    enum Wake {
        /// The session's track, status or timeline moved.
        Changed,
        /// A player appeared or went away: find Deezer's session again.
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

    /// WinRT and Core Audio need COM on the calling thread.
    fn com() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    fn emit_state(app: &AppHandle, state: &PlayerState) {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, STATE_EVENT, state);
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
                .name("coucou-deezer".into())
                .spawn(move || listen(app, generation, tx, rx));
            if let Err(err) = spawned {
                crate::log::line(format!("deezer: no listener thread: {err}"));
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
                crate::log::line(format!("deezer: no media sessions: {err}"));
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
                bound = find_session(&manager).map(|s| Bound::bind(s, &tx));
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

    /// Deezer's session, with the event handlers that wake the listener.
    struct Bound {
        session: Session,
        tokens: [Option<i64>; 3],
    }

    impl Bound {
        fn bind(session: Session, tx: &Sender<Wake>) -> Bound {
            let tokens = [
                session.MediaPropertiesChanged(&wake_on(tx)).ok(),
                session.PlaybackInfoChanged(&wake_on(tx)).ok(),
                session.TimelinePropertiesChanged(&wake_on(tx)).ok(),
            ];
            Bound { session, tokens }
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
            .find(|s| s.SourceAppUserModelId().is_ok_and(|id| is_deezer_app(&id.to_string_lossy())))
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
        };
        Ok((snapshot, props))
    }

    fn anchor(state: &mut PlayerState, position: f64, at: f64) {
        state.position = position.max(0.0);
        state.position_at = at;
    }

    fn read_and_emit(app: &AppHandle, generation: u64, session: Option<&Session>) {
        let read = session.and_then(|s| snapshot(s).ok());
        let volume = read.as_ref().and_then(|_| deezer_volume());
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
    /// remote). Read once per track; a thumbnail that comes a moment after the
    /// title is picked up by the next event.
    fn artwork(app: &AppHandle, track: &Track, props: &MediaProperties) {
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

    // ── Volume: Deezer in the Windows mixer ───────────────────────────────────

    /// Deezer's audio sessions on the default output.
    fn deezer_audio() -> Vec<ISimpleAudioVolume> {
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
                if pid != 0 && is_deezer_process(pid) {
                    if let Ok(volume) = control.cast::<ISimpleAudioVolume>() {
                        out.push(volume);
                    }
                }
            }
        }
        out
    }

    fn is_deezer_process(pid: u32) -> bool {
        unsafe {
            let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            let named =
                QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
            let _ = CloseHandle(process);
            named.is_ok() && is_deezer_exe(&String::from_utf16_lossy(&buf[..len as usize]))
        }
    }

    /// 0…100, or None while Deezer has no audio session (nothing played yet).
    fn deezer_volume() -> Option<i32> {
        let level = unsafe { deezer_audio().first()?.GetMasterVolume().ok()? };
        Some((level * 100.0).round().clamp(0.0, 100.0) as i32)
    }

    fn set_deezer_volume(percent: f64) -> bool {
        let level = (percent / 100.0).clamp(0.0, 1.0) as f32;
        let mut done = false;
        for volume in &deezer_audio() {
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
        let seek_to = state.track.as_ref().map(|t| seek_target(t.duration, v));
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
            "volume" => set_deezer_volume(v),
            _ => false,
        };
        if !done {
            return false;
        }
        // Show these at once; the session's events confirm them.
        if matches!(action, "seek" | "volume") {
            let state = {
                let mut s = SHARED.lock().unwrap();
                if action == "seek" {
                    if let Some(target) = seek_to {
                        anchor(&mut s.state, target, now_ms());
                    }
                } else {
                    s.state.volume = v.round().clamp(0.0, 100.0) as i32;
                }
                s.state.clone()
            };
            emit_state(app, &state);
        }
        true
    }

    // ── Launching ─────────────────────────────────────────────────────────────

    /// The Store package leaves a folder for the user under %LOCALAPPDATA%\Packages.
    pub fn installed() -> bool {
        std::env::var_os("LOCALAPPDATA")
            .map(|base| PathBuf::from(base).join("Packages").join(PACKAGE_FAMILY))
            .is_some_and(|p| p.is_dir())
    }

    /// Starts Deezer, or brings it forward; without Deezer, the Store's search.
    pub fn open() -> bool {
        let running = SHARED.lock().unwrap().state.running;
        if running || installed() {
            let launched = std::process::Command::new("explorer.exe")
                .arg(format!("shell:AppsFolder\\{APP_ID}"))
                .spawn()
                .is_ok();
            return launched;
        }
        crate::platform::open_url(STORE_URL);
        false
    }

    /// Reads the real session; run by hand with Deezer open:
    /// `cargo test deezer::win::live -- --ignored --nocapture`
    #[cfg(test)]
    mod live {
        use super::*;

        #[test]
        #[ignore = "needs the Deezer app running"]
        fn reads_the_live_session() {
            com();
            let manager = Manager::RequestAsync().and_then(|op| op.get()).expect("media sessions");
            let session = find_session(&manager).expect("a Deezer session");
            let (snap, props) = snapshot(&session).expect("snapshot");
            println!("track    = {:?}", snap.track);
            println!("playing  = {}  position = {:.1}s  updated_at = {:?}", snap.playing, snap.position, snap.updated_at);
            let cover = thumbnail(&props);
            println!("cover    = {:?} bytes, data url: {}", cover.as_ref().map(|b| b.len()), cover.as_deref().and_then(data_url).map(|d| d[..22].to_string()).unwrap_or_default());
            println!("volume   = {:?}  installed = {}", deezer_volume(), installed());
            assert!(snap.track.is_some());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognises_the_deezer_session() {
        assert!(is_deezer_app("Deezer.62021768415AF_q7m17pa7q8kj0!Deezer.Music"));
        assert!(is_deezer_app("deezer.exe"));
        assert!(!is_deezer_app("Spotify.exe"));
    }

    #[test]
    fn a_track_needs_a_title() {
        assert_eq!(windows_track("  ", "Alan Walker", "", 211.0), None);
    }

    #[test]
    fn the_track_id_is_stable_and_prefixed() {
        let a = windows_track("Darkside", "Alan Walker, Au/Ra, Tomine Harket", "", 211.8).unwrap();
        let b = windows_track("Darkside", "Alan Walker, Au/Ra, Tomine Harket", "", 211.8).unwrap();
        assert_eq!(a.id, b.id);
        assert!(a.id.starts_with("deezer:track:"));
        assert_eq!(a.album, "");
    }

    #[test]
    fn different_tags_give_different_ids() {
        let a = windows_track("Darkside", "Alan Walker", "", 211.0).unwrap();
        let b = windows_track("Faded", "Alan Walker", "", 211.0).unwrap();
        let c = windows_track("Darkside", "Au/Ra", "", 211.0).unwrap();
        assert_ne!(a.id, b.id);
        assert_ne!(a.id, c.id);
    }

    #[test]
    fn tags_are_trimmed_and_a_negative_duration_is_zero() {
        let t = windows_track("  Darkside ", " Alan Walker ", "  ", -5.0).unwrap();
        assert_eq!((t.title.as_str(), t.artist.as_str(), t.album.as_str()), ("Darkside", "Alan Walker", ""));
        assert_eq!(t.duration, 0.0);
    }

    #[test]
    fn only_the_deezer_process_is_taken_for_the_volume() {
        let store = r"C:\Program Files\WindowsApps\Deezer.62021768415AF_8.0.10.0_x86__q7m17pa7q8kj0\app\Deezer.exe";
        assert!(is_deezer_exe(store));
        assert!(is_deezer_exe("C:/x/DEEZER.EXE"));
        assert!(!is_deezer_exe(r"C:\Program Files\Spotify\Spotify.exe"));
        assert!(!is_deezer_exe(r"C:\Deezer\other.exe"));
    }

    #[test]
    fn a_seek_stays_inside_the_track() {
        assert_eq!(seek_target(211.0, 100.0), 100.0);
        assert_eq!(seek_target(211.0, -4.0), 0.0);
        assert_eq!(seek_target(211.0, 500.0), 210.0);
        assert_eq!(seek_target(0.0, 30.0), 0.0);
    }
}
