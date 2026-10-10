// The iPhone, without a Mac: links and text both ways through iCloud Drive,
// and push alerts through ntfy. Windows only.
//
// iCloud Drive (iCloud for Windows keeps %USERPROFILE%\iCloudDrive in sync):
// - iPhone → laptop: an iPhone Shortcut saves a .txt into iCloudDrive\Coucou\
//   to-laptop\. One thread blocks in ReadDirectoryChangesW on that folder, so
//   nothing runs until a file lands; each file is read once, copied to the
//   clipboard, shown in the island and deleted.
// - laptop → iPhone: when the user allows it, the text copied last is written
//   to iCloudDrive\Coucou\to-iphone.txt, which another Shortcut reads.
//
// ntfy (ntfy.sh, or any ntfy server): when an agent finishes, fails or needs an
// answer and the user has been away from the keyboard for a minute, one POST
// to their topic. The topic is the only secret, so it lives in the keychain.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex, OnceLock};

use tauri::{AppHandle, Emitter};

use crate::settings::PlusPrefs;
use crate::sysevents::Live;

pub const NTFY_KEY: &str = "ntfy-topic";
const NTFY_SERVER: &str = "https://ntfy.sh";
/// Away for this long, an alert goes to the phone too.
const AWAY_SECS: u64 = 60;
const MAX_SHARE: u64 = 64 * 1024;

static APP: OnceLock<AppHandle> = OnceLock::new();
static PREFS: LazyLock<Mutex<PlusPrefs>> = LazyLock::new(Default::default);
static WATCHING: AtomicBool = AtomicBool::new(false);
/// The text that just came from the iPhone, so copying it here doesn't send it back.
static LAST_IN: Mutex<Option<String>> = Mutex::new(None);

pub fn bridge_dir() -> PathBuf {
    crate::platform::home_dir().join("iCloudDrive").join("Coucou")
}

pub fn icloud_present() -> bool {
    crate::platform::home_dir().join("iCloudDrive").is_dir()
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

pub fn start(app: &AppHandle, prefs: &PlusPrefs) {
    let _ = APP.set(app.clone());
    apply(prefs);
}

/// Settings saved: the folder watch follows the iCloud switch.
pub fn apply(prefs: &PlusPrefs) {
    *PREFS.lock().unwrap() = prefs.clone();
    if prefs.icloud_bridge && icloud_present() && !WATCHING.swap(true, Ordering::SeqCst) {
        let _ = std::thread::Builder::new().name("coucou-icloud".into()).spawn(watch);
    }
}

fn enabled() -> bool {
    PREFS.lock().unwrap().icloud_bridge
}

// ── iPhone → laptop ───────────────────────────────────────────────────────────

fn watch() {
    let inbox = bridge_dir().join("to-laptop");
    if std::fs::create_dir_all(&inbox).is_err() {
        WATCHING.store(false, Ordering::SeqCst);
        return;
    }
    // Whatever arrived while Coucou was closed.
    drain(&inbox);
    let wide: Vec<u16> = inbox.as_os_str().encode_wide_z();
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::Storage::FileSystem::{
        CreateFileW, ReadDirectoryChangesW, FILE_FLAG_BACKUP_SEMANTICS, FILE_LIST_DIRECTORY,
        FILE_NOTIFY_CHANGE_FILE_NAME, FILE_NOTIFY_CHANGE_LAST_WRITE, FILE_SHARE_DELETE, FILE_SHARE_READ,
        FILE_SHARE_WRITE, OPEN_EXISTING,
    };
    let handle: HANDLE = match unsafe {
        CreateFileW(
            windows::core::PCWSTR(wide.as_ptr()),
            FILE_LIST_DIRECTORY.0,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            None,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            None,
        )
    } {
        Ok(h) => h,
        Err(e) => {
            crate::log::line(format!("phone: cannot watch {}: {e}", inbox.display()));
            WATCHING.store(false, Ordering::SeqCst);
            return;
        }
    };
    let mut buf = vec![0u8; 8192];
    loop {
        let mut got = 0u32;
        // Blocks until something changes in the folder.
        let ok = unsafe {
            ReadDirectoryChangesW(
                handle,
                buf.as_mut_ptr() as _,
                buf.len() as u32,
                false,
                FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE,
                Some(&mut got),
                None,
                None,
            )
        };
        if ok.is_err() || !enabled() {
            break;
        }
        // iCloud writes a file in steps: let it finish before reading.
        std::thread::sleep(std::time::Duration::from_millis(400));
        drain(&inbox);
    }
    let _ = unsafe { CloseHandle(handle) };
    WATCHING.store(false, Ordering::SeqCst);
}

trait WideZ {
    fn encode_wide_z(&self) -> Vec<u16>;
}
impl WideZ for std::ffi::OsStr {
    fn encode_wide_z(&self) -> Vec<u16> {
        use std::os::windows::ffi::OsStrExt;
        self.encode_wide().chain(std::iter::once(0)).collect()
    }
}

/// Reads, shows and deletes every finished share in the folder, oldest first.
fn drain(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("txt")))
        .filter_map(|p| Some((std::fs::metadata(&p).ok()?.modified().ok()?, p)))
        .collect();
    files.sort();
    for (_, path) in files {
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let text = if size <= MAX_SHARE { std::fs::read(&path).ok() } else { None };
        let _ = std::fs::remove_file(&path);
        if let Some(text) = text.map(|b| String::from_utf8_lossy(&b).trim().to_string()).filter(|t| !t.is_empty()) {
            received(text);
        }
    }
}

fn received(text: String) {
    *LAST_IN.lock().unwrap() = Some(text.clone());
    crate::sysevents::clipboard_copy(text.clone());
    if let Some(app) = APP.get() {
        let _ = app.emit_to(
            crate::island::WINDOW_LABEL,
            "live",
            Live { kind: "phone", level: None, muted: false, charging: false, text },
        );
    }
}

// ── Laptop → iPhone ───────────────────────────────────────────────────────────

/// A text was copied here (sysevents.rs): it goes to the iPhone when allowed.
pub fn laptop_copied(text: &str) {
    let prefs = PREFS.lock().unwrap().clone();
    if !(prefs.icloud_bridge && prefs.share_copies_to_iphone) || !icloud_present() {
        return;
    }
    if LAST_IN.lock().unwrap().as_deref() == Some(text) {
        return;
    }
    send_to_iphone(text);
}

/// Writes the text for the iPhone's "Get from laptop" Shortcut.
#[tauri::command]
pub fn phone_send(text: String) -> bool {
    send_to_iphone(&text)
}

fn send_to_iphone(text: &str) -> bool {
    let dir = bridge_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return false;
    }
    // Written beside and renamed, so iCloud never uploads half a file.
    let tmp = dir.join("to-iphone.tmp");
    std::fs::write(&tmp, text.as_bytes()).is_ok() && std::fs::rename(&tmp, dir.join("to-iphone.txt")).is_ok()
}

/// For Settings: whether iCloud Drive is there, and where the bridge lives.
#[tauri::command]
pub fn phone_status() -> serde_json::Value {
    serde_json::json!({ "icloud": icloud_present(), "folder": bridge_dir().to_string_lossy() })
}

// ── Push alerts (ntfy) ────────────────────────────────────────────────────────

/// Seconds since the last keyboard or mouse input on this PC.
fn idle_secs() -> u64 {
    use windows::Win32::System::SystemInformation::GetTickCount;
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
    let mut info = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
    if !unsafe { GetLastInputInfo(&mut info) }.as_bool() {
        return 0;
    }
    (unsafe { GetTickCount() }.wrapping_sub(info.dwTime) / 1000) as u64
}

/// The ntfy URL for a topic: a bare topic goes to ntfy.sh; a full https URL is
/// the user's own server. Anything else is refused.
pub fn ntfy_url(topic: &str) -> Option<String> {
    let t = topic.trim();
    if t.starts_with("https://") {
        return Some(t.to_string());
    }
    let ok = !t.is_empty() && t.len() <= 64 && t.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    ok.then(|| format!("{NTFY_SERVER}/{t}"))
}

/// An alert for the phone. `force` skips the away check (Settings → Send a test).
#[tauri::command]
pub async fn phone_push(title: String, body: String, urgent: bool, force: Option<bool>) -> bool {
    if crate::integrations::PAUSED.load(Ordering::Relaxed) {
        return false;
    }
    let force = force.unwrap_or(false);
    if !force && PREFS.lock().unwrap().push_only_when_away && idle_secs() < AWAY_SECS {
        return false;
    }
    let Some(url) = crate::secrets::get(NTFY_KEY).and_then(|t| ntfy_url(&t)) else { return false };
    let title: String = title.chars().filter(|c| !c.is_control()).take(120).collect();
    let body: String = body.chars().take(1000).collect();
    let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(10)).build().unwrap_or_default();
    client
        .post(url)
        .header("Title", title)
        .header("Tags", if urgent { "warning" } else { "robot" })
        .header("Priority", if urgent { "high" } else { "default" })
        .body(body)
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn topics_go_to_ntfy_sh_and_urls_must_be_https() {
        assert_eq!(ntfy_url("mithun-coucou-8f3k2").as_deref(), Some("https://ntfy.sh/mithun-coucou-8f3k2"));
        assert_eq!(ntfy_url("https://ntfy.example.com/alerts").as_deref(), Some("https://ntfy.example.com/alerts"));
        assert_eq!(ntfy_url("http://ntfy.example.com/x"), None);
        assert_eq!(ntfy_url("a/../b"), None);
        assert_eq!(ntfy_url(""), None);
    }

    #[test]
    fn shares_are_read_once_oldest_first_and_deleted() {
        let dir = std::env::temp_dir().join(format!("coucou-phone-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), "https://example.com").unwrap();
        std::fs::write(dir.join("skip.jpg"), "x").unwrap();
        drain(&dir);
        assert!(!dir.join("a.txt").exists());
        assert!(dir.join("skip.jpg").exists());
        assert_eq!(LAST_IN.lock().unwrap().as_deref(), Some("https://example.com"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
