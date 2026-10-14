//! Apple Music through Cider's local MPRIS player. No account credentials.
use crate::spotify::{ArtSource, PlayerState};
use tauri::{AppHandle, Emitter};

pub const PILL_ID: &str = "integration_music";

pub fn artwork_source(raw: &str) -> Option<ArtSource> {
    let url = reqwest::Url::parse(raw).ok()?;
    if url.scheme() == "file" {
        return crate::spotify::artwork_source(raw);
    }
    let host = url.host_str()?.to_ascii_lowercase();
    (url.scheme() == "https"
        && (host == "mzstatic.com" || host.ends_with(".mzstatic.com"))
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none())
    .then(|| ArtSource::Https(url.to_string()))
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use dbus::blocking::{stdintf::org_freedesktop_dbus::Properties, Connection};
    use std::{
        collections::VecDeque,
        sync::{
            atomic::{AtomicBool, AtomicU64, Ordering},
            LazyLock, Mutex,
        },
        time::Duration,
    };
    const BUS: &str = "org.mpris.MediaPlayer2.cider";
    const PATH: &str = "/org/mpris/MediaPlayer2";
    const PLAYER: &str = "org.mpris.MediaPlayer2.Player";
    const ROOT: &str = "org.mpris.MediaPlayer2";
    static ACTIVE: AtomicBool = AtomicBool::new(false);
    static GENERATION: AtomicU64 = AtomicU64::new(0);
    static CONNECTION: Mutex<Option<Connection>> = Mutex::new(None);
    static STATE: LazyLock<Mutex<PlayerState>> =
        LazyLock::new(|| Mutex::new(PlayerState::default()));
    static ART: Mutex<VecDeque<(String, String)>> = Mutex::new(VecDeque::new());
    static LOADING: Mutex<Option<String>> = Mutex::new(None);

    fn with_bus<T>(f: impl FnOnce(&Connection) -> Option<T>) -> Option<T> {
        let mut slot = CONNECTION.lock().ok()?;
        if slot.as_ref().is_none_or(|c| !c.channel().is_connected()) {
            *slot = Connection::new_session().ok();
        }
        f(slot.as_ref()?)
    }
    fn now() -> f64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs_f64() * 1000.0)
            .unwrap_or(0.0)
    }
    pub fn installed() -> bool {
        crate::platform::find_on_path("cider").is_some()
            || std::path::Path::new("/usr/lib/cider/Cider").is_file()
    }
    fn read() -> PlayerState {
        let props = with_bus(|c| {
            c.with_proxy(BUS, PATH, Duration::from_millis(1200))
                .get_all(PLAYER)
                .ok()
        });
        let mut state = STATE.lock().unwrap().clone();
        state.installed = installed() || props.is_some();
        state.running = props.is_some();
        if let Some(props) = props {
            state.apply(&crate::spotify::mpris_props(&props), now());
        } else {
            state.clear(now());
        }
        state
    }
    fn current(generation: u64) -> bool {
        ACTIVE.load(Ordering::Acquire) && GENERATION.load(Ordering::Acquire) == generation
    }
    fn emit(app: &AppHandle, state: &PlayerState, generation: u64) {
        if !current(generation) {
            return;
        }
        *STATE.lock().unwrap() = state.clone();
        let _ = app.emit_to("island", "apple-music", state);
        artwork(app, state, generation);
    }
    pub fn sync(app: &AppHandle, on: bool) {
        if ACTIVE.swap(on, Ordering::AcqRel) == on {
            return;
        }
        let generation = GENERATION.fetch_add(1, Ordering::AcqRel) + 1;
        if !on {
            let state = PlayerState {
                installed: installed(),
                ..PlayerState::default()
            };
            *STATE.lock().unwrap() = state.clone();
            let _ = app.emit_to("island", "apple-music", state);
            return;
        }
        let app = app.clone();
        // A single small local read also catches Cider versions that omit seek signals.
        let _ = std::thread::Builder::new()
            .name("coucou-apple-music".into())
            .spawn(move || {
                while current(generation) {
                    emit(&app, &read(), generation);
                    for _ in 0..10 {
                        if !current(generation) {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(100));
                    }
                }
            });
    }
    pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
        if !ACTIVE.load(Ordering::Acquire) {
            return None;
        }
        let generation = GENERATION.load(Ordering::Acquire);
        let state = read();
        emit(app, &state, generation);
        Some(state)
    }
    pub fn control(app: &AppHandle, action: &str, value: Option<f64>) -> bool {
        if !ACTIVE.load(Ordering::Acquire) {
            return false;
        }
        let state = STATE.lock().unwrap().clone();
        if !state.running {
            return false;
        }
        let done = send(&state, action, value);
        refresh(app);
        done
    }
    fn send(state: &PlayerState, action: &str, value: Option<f64>) -> bool {
        let v = value.filter(|v| v.is_finite()).unwrap_or(0.0);
        with_bus(|c| {
            let p = c.with_proxy(BUS, PATH, Duration::from_millis(1200));
            let result: Result<(), dbus::Error> = match action {
                "playPause" => p.method_call(PLAYER, "PlayPause", ()),
                "next" => p.method_call(PLAYER, "Next", ()),
                "previous" => p.method_call(PLAYER, "Previous", ()),
                "seek" => {
                    let track = state.track.as_ref()?;
                    let path = dbus::Path::new(track.object_path.clone()).ok()?;
                    p.method_call(
                        PLAYER,
                        "SetPosition",
                        (
                            path,
                            (v.clamp(0.0, track.duration.max(0.0)) * 1_000_000.0) as i64,
                        ),
                    )
                }
                "shuffle" => p.set(PLAYER, "Shuffle", v != 0.0),
                "repeat" => p.set(
                    PLAYER,
                    "LoopStatus",
                    if v != 0.0 { "Playlist" } else { "None" },
                ),
                "volume" => p.set(PLAYER, "Volume", (v / 100.0).clamp(0.0, 1.0)),
                _ => return None,
            };
            result.ok()
        })
        .is_some()
    }
    pub fn open() -> bool {
        let raised = with_bus(|c| {
            let p = c.with_proxy(BUS, PATH, Duration::from_millis(1200));
            if !p.get::<bool>(ROOT, "CanRaise").ok()? {
                return None;
            }
            p.method_call::<(), _, _, _>(ROOT, "Raise", ()).ok()
        })
        .is_some();
        if raised {
            return true;
        }
        let bin = crate::platform::find_on_path("cider").or_else(|| {
            let p = std::path::PathBuf::from("/usr/lib/cider/Cider");
            p.is_file().then_some(p)
        });
        let Some(bin) = bin else {
            return false;
        };
        use std::process::{Command, Stdio};
        match Command::new(bin)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(mut child) => {
                std::thread::spawn(move || {
                    let _ = child.wait();
                });
                true
            }
            Err(_) => false,
        }
    }
    fn artwork(app: &AppHandle, state: &PlayerState, generation: u64) {
        let Some(url) = state.track.as_ref().and_then(|t| t.art_url.clone()) else {
            return;
        };
        if let Some((_, data)) = ART.lock().unwrap().iter().find(|(u, _)| u == &url) {
            let _ = app.emit_to(
                "island",
                "apple-music-artwork",
                serde_json::json!({"artUrl":url,"dataUrl":data}),
            );
            return;
        }
        let source = super::artwork_source(&url);
        if source.is_none() {
            return;
        }
        {
            let mut loading = LOADING.lock().unwrap();
            if loading.as_ref() == Some(&url) {
                return;
            }
            *loading = Some(url.clone());
        }
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            let bytes = fetch_artwork(source.unwrap()).await;
            {
                let mut loading = LOADING.lock().unwrap();
                if loading.as_ref() == Some(&url) {
                    *loading = None;
                }
            }
            let Some(bytes) = bytes else {
                return;
            };
            let Some(mime) = crate::spotify::sniff_image(&bytes) else {
                return;
            };
            let data = format!("data:{mime};base64,{}", crate::claude::base64_for(&bytes));
            {
                let mut cache = ART.lock().unwrap();
                cache.retain(|(u, _)| u != &url);
                cache.push_back((url.clone(), data.clone()));
                while cache.len() > 8 {
                    cache.pop_front();
                }
            }
            if current(generation)
                && STATE
                    .lock()
                    .unwrap()
                    .track
                    .as_ref()
                    .and_then(|t| t.art_url.as_ref())
                    == Some(&url)
            {
                let _ = app.emit_to(
                    "island",
                    "apple-music-artwork",
                    serde_json::json!({"artUrl":url,"dataUrl":data}),
                );
            }
        });
    }
    async fn fetch_artwork(source: ArtSource) -> Option<Vec<u8>> {
        let limit = 3 * 1024 * 1024;
        match source {
            ArtSource::Https(remote) => {
                if crate::integrations::PAUSED.load(Ordering::Relaxed) {
                    None
                } else {
                    let client = reqwest::Client::builder()
                        .timeout(Duration::from_secs(10))
                        .redirect(reqwest::redirect::Policy::none())
                        .build()
                        .ok();
                    if let Some(client) = client {
                        match client.get(remote).send().await {
                            Ok(r) if r.status().is_success() => {
                                crate::net::read_capped(r, limit).await.ok()
                            }
                            _ => None,
                        }
                    } else {
                        None
                    }
                }
            }
            ArtSource::File(path) => tauri::async_runtime::spawn_blocking(move || {
                std::fs::metadata(&path)
                    .ok()
                    .filter(|m| m.is_file() && m.len() <= 3 * 1024 * 1024)
                    .and_then(|_| std::fs::read(path).ok())
            })
            .await
            .ok()
            .flatten(),
        }
    }
    #[cfg(test)]
    #[test]
    #[ignore = "Runs against a separate test session bus, never the user's player"]
    fn mock_cider_controls() {
        assert!(std::env::var_os("COUCOU_MOCK_CIDER").is_some());
        let state = read();
        assert!(state.running);
        assert_eq!(state.track.as_ref().unwrap().title, "Test track");
        for (action, value) in [
            ("playPause", None),
            ("next", None),
            ("previous", None),
            ("seek", Some(55.5)),
            ("shuffle", Some(1.0)),
            ("repeat", Some(1.0)),
            ("volume", Some(42.0)),
        ] {
            assert!(send(&state, action, value), "{action}");
        }
        assert!(!send(&state, "unsupported", None));
    }
}

pub fn sync(app: &AppHandle, active: &[String]) {
    #[cfg(target_os = "linux")]
    linux::sync(app, active.iter().any(|id| id == PILL_ID));
    #[cfg(not(target_os = "linux"))]
    let _ = (app, active);
}
#[tauri::command]
pub async fn cider_refresh(app: AppHandle) -> Option<PlayerState> {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux::refresh(&app))
            .await
            .ok()
            .flatten()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = app;
        None
    }
}
#[tauri::command]
pub async fn cider_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux::control(&app, &action, value))
            .await
            .unwrap_or(false)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (app, action, value);
        false
    }
}
#[tauri::command]
pub async fn cider_open() -> bool {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(linux::open)
            .await
            .unwrap_or(false)
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}
#[tauri::command]
pub fn cider_installed() -> bool {
    #[cfg(target_os = "linux")]
    {
        linux::installed()
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn apple_artwork_is_limited_to_apple_image_hosts() {
        assert!(matches!(
            artwork_source("https://is1-ssl.mzstatic.com/image/thumb/test.jpg"),
            Some(ArtSource::Https(_))
        ));
        for url in [
            "https://mzstatic.com.evil.test/x",
            "http://is1-ssl.mzstatic.com/x",
            "https://example.com/a",
            "https://user:pass@is1-ssl.mzstatic.com/a",
            "https://is1-ssl.mzstatic.com:999/a",
        ] {
            assert!(artwork_source(url).is_none(), "{url}");
        }
    }
}
