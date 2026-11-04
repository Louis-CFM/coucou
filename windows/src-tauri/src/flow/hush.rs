// Silence while you speak to Coucou: the other apps' sound (a video, music, a
// call) is muted from the moment Coucou listens until it has heard you, so
// nothing playing gets in the way of your voice. Windows mutes each app's
// session in the mixer, never Coucou's own; only the sessions Coucou muted are
// given their sound back, and a list on disk does it at the next launch if
// Coucou quit in between. Elsewhere it does nothing.

use std::sync::mpsc::{self, Sender};
use std::sync::{Mutex, OnceLock};

/// Held while Coucou listens: dropping the last one gives the sound back.
pub struct Guard(());

impl Drop for Guard {
    fn drop(&mut self) {
        let mut depth = DEPTH.lock().unwrap();
        *depth = depth.saturating_sub(1);
        if *depth == 0 {
            send(Job::Restore);
        }
    }
}

static DEPTH: Mutex<u32> = Mutex::new(0);

enum Job {
    Mute,
    Restore,
}

/// One thread does the work, in order: a mute is never undone by a restore
/// that started before it.
fn send(job: Job) {
    static WORKER: OnceLock<Mutex<Sender<Job>>> = OnceLock::new();
    let tx = WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<Job>();
        let _ = std::thread::Builder::new().name("coucou-hush".into()).spawn(move || {
            imp::restore_left_over();
            for job in rx {
                match job {
                    Job::Mute => imp::mute_others(),
                    Job::Restore => imp::restore(),
                }
            }
        });
        Mutex::new(tx)
    });
    let _ = tx.lock().unwrap().send(job);
}

/// Mutes the other apps until the guard is dropped, when `on` (the user's
/// choice). Several listeners at once share the silence.
pub fn hush(on: bool) -> Option<Guard> {
    if !on || !imp::SUPPORTED {
        return None;
    }
    let mut depth = DEPTH.lock().unwrap();
    *depth += 1;
    if *depth == 1 {
        send(Job::Mute);
    }
    Some(Guard(()))
}

/// At launch: a silence left by a Coucou that quit while listening is undone.
pub fn setup() {
    if imp::SUPPORTED {
        send(Job::Restore);
    }
}

/// The sessions Coucou muted, by their instance id, kept on disk until given back.
fn list_path() -> std::path::PathBuf {
    crate::settings::local_dir().join("hushed.json")
}

#[cfg_attr(not(windows), allow(dead_code))]
fn save_list(ids: &[String]) {
    let path = list_path();
    if ids.is_empty() {
        let _ = std::fs::remove_file(path);
    } else if let Ok(text) = serde_json::to_string(ids) {
        let _ = std::fs::write(path, text);
    }
}

#[cfg_attr(not(windows), allow(dead_code))]
fn load_list() -> Vec<String> {
    std::fs::read_to_string(list_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

#[cfg(windows)]
mod imp {
    use windows::core::Interface;
    use windows::Win32::Media::Audio::{
        eMultimedia, eRender, IAudioSessionControl2, IAudioSessionManager2, IMMDeviceEnumerator, ISimpleAudioVolume,
        MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_ALL, COINIT_MULTITHREADED};

    pub const SUPPORTED: bool = true;

    /// The sessions on the default output: (instance id, process, volume).
    fn sessions() -> Vec<(String, u32, ISimpleAudioVolume)> {
        let mut out = Vec::new();
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let Ok(devices) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else {
                return out;
            };
            let Ok(device) = devices.GetDefaultAudioEndpoint(eRender, eMultimedia) else { return out };
            let Ok(manager) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) else { return out };
            let Ok(list) = manager.GetSessionEnumerator() else { return out };
            for i in 0..list.GetCount().unwrap_or(0) {
                let Ok(control) = list.GetSession(i) else { continue };
                let Ok(control) = control.cast::<IAudioSessionControl2>() else { continue };
                // Windows' own sounds (notifications, errors) are left alone.
                if control.IsSystemSoundsSession().0 == 0 {
                    continue;
                }
                let Ok(raw) = control.GetSessionInstanceIdentifier() else { continue };
                let id = raw.to_string().unwrap_or_default();
                CoTaskMemFree(Some(raw.0 as *const _));
                let pid = control.GetProcessId().unwrap_or(0);
                if let Ok(volume) = control.cast::<ISimpleAudioVolume>() {
                    out.push((id, pid, volume));
                }
            }
        }
        out
    }

    /// Coucou itself, or one of its webviews: its own sounds keep playing.
    fn is_ours(pid: u32) -> bool {
        let me = std::process::id();
        pid == me || crate::platform::process_ancestors(pid).contains(&me)
    }

    pub fn mute_others() {
        let mut muted = super::load_list();
        for (id, pid, volume) in sessions() {
            if pid == 0 || is_ours(pid) || muted.contains(&id) {
                continue;
            }
            unsafe {
                // Already muted by the user: theirs to unmute, not ours.
                if volume.GetMute().map(|m| m.as_bool()).unwrap_or(true) {
                    continue;
                }
                if volume.SetMute(true, std::ptr::null()).is_ok() {
                    muted.push(id);
                }
            }
        }
        super::save_list(&muted);
    }

    pub fn restore() {
        let muted = super::load_list();
        if muted.is_empty() {
            return;
        }
        for (id, _, volume) in sessions() {
            if muted.contains(&id) {
                unsafe {
                    let _ = volume.SetMute(false, std::ptr::null());
                }
            }
        }
        super::save_list(&[]);
    }

    pub fn restore_left_over() {
        restore();
    }
}

#[cfg(not(windows))]
mod imp {
    pub const SUPPORTED: bool = false;
    pub fn mute_others() {}
    pub fn restore() {}
    pub fn restore_left_over() {}
}
