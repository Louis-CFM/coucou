//! What keeps the Mochis from falling asleep besides the island's own
//! activity. Sound coming out of the speakers (music, a video, a game, a call)
//! or the microphone or camera in use by any app (a call, a recording).
//! Checked every 3 s; the island hears "keep-awake" (true/false) when that
//! changes. It stays true for GRACE after the last sign of life, so the gap
//! between two songs isn't quiet enough to nod off in.

#![cfg_attr(not(windows), allow(unused_imports, dead_code))]

use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter};

use crate::log;

const POLL: Duration = Duration::from_secs(3);
const GRACE: Duration = Duration::from_secs(20);

pub fn start(app: AppHandle) {
    #[cfg(windows)]
    std::thread::spawn(move || {
        let _ = unsafe {
            windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED)
        };
        let mut last_alive: Option<Instant> = None;
        let mut shown = false;
        loop {
            if let Some(why) = reason() {
                if !shown {
                    log::line(format!("awake: {why}"));
                }
                last_alive = Some(Instant::now());
            }
            let awake = last_alive.is_some_and(|t| t.elapsed() < GRACE);
            if awake != shown {
                shown = awake;
                if !awake {
                    log::line("awake: quiet again");
                }
                let _ = app.emit_to(crate::island::WINDOW_LABEL, "keep-awake", awake);
            }
            std::thread::sleep(POLL);
        }
    });
    #[cfg(not(windows))]
    let _ = (app, POLL, GRACE);
}

/// Whether anything is keeping them up right now, and what.
#[cfg(windows)]
fn reason() -> Option<&'static str> {
    if unsafe { sound_playing() } {
        Some("sound playing")
    } else if unsafe { in_use("microphone") } {
        Some("microphone in use")
    } else if unsafe { in_use("webcam") } {
        Some("camera in use")
    } else {
        None
    }
}

/// The default speakers' peak level right now (before the volume, so muted
/// audio still counts).
#[cfg(windows)]
unsafe fn sound_playing() -> bool {
    use windows::Win32::Media::Audio::Endpoints::IAudioMeterInformation;
    use windows::Win32::Media::Audio::{eConsole, eRender, IMMDeviceEnumerator, MMDeviceEnumerator};
    use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_ALL};
    let Ok(devices) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else {
        return false;
    };
    devices
        .GetDefaultAudioEndpoint(eRender, eConsole)
        .and_then(|device| device.Activate::<IAudioMeterInformation>(CLSCTX_ALL, None))
        .and_then(|meter| meter.GetPeakValue())
        .is_ok_and(|peak| peak > 0.001)
}

/// Whether any app is using the microphone or camera now: Windows' privacy
/// store keeps a LastUsedTimeStop of 0 for an app while it holds the device.
#[cfg(windows)]
unsafe fn in_use(capability: &str) -> bool {
    use windows::Win32::System::Registry::HKEY_CURRENT_USER;
    let path = format!("Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\{capability}");
    let Some(root) = reg::open(HKEY_CURRENT_USER, &path) else {
        return false;
    };
    reg::subkeys(&root).iter().any(|name| {
        let Some(app) = reg::open(root.0, name) else { return false };
        if name == "NonPackaged" {
            // Desktop apps, one key per executable path.
            reg::subkeys(&app).iter().any(|exe| reg::open(app.0, exe).is_some_and(|k| reg::holding(&k)))
        } else {
            reg::holding(&app)
        }
    })
}

#[cfg(windows)]
mod reg {
    use windows::core::{PCWSTR, PWSTR};
    use windows::Win32::System::Registry::*;

    pub struct Key(pub HKEY);
    impl Drop for Key {
        fn drop(&mut self) {
            unsafe {
                let _ = RegCloseKey(self.0);
            }
        }
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(Some(0)).collect()
    }

    pub unsafe fn open(parent: HKEY, name: &str) -> Option<Key> {
        let name = wide(name);
        let mut key = HKEY::default();
        RegOpenKeyExW(parent, PCWSTR(name.as_ptr()), Some(0), KEY_READ, &mut key).ok().ok()?;
        Some(Key(key))
    }

    pub unsafe fn subkeys(key: &Key) -> Vec<String> {
        let mut names = Vec::new();
        for index in 0..4096 {
            let mut name = [0u16; 1024];
            let mut length = name.len() as u32;
            if RegEnumKeyExW(key.0, index, Some(PWSTR(name.as_mut_ptr())), &mut length, None, None, None, None).is_err() {
                break;
            }
            names.push(String::from_utf16_lossy(&name[..length as usize]));
        }
        names
    }

    fn qword(key: &Key, name: &str) -> Option<u64> {
        let name = wide(name);
        let mut kind = REG_VALUE_TYPE::default();
        let mut bytes = [0u8; 8];
        let mut size = 8u32;
        unsafe {
            RegQueryValueExW(key.0, PCWSTR(name.as_ptr()), None, Some(&mut kind), Some(bytes.as_mut_ptr()), Some(&mut size))
                .ok()
                .ok()?;
        }
        (kind == REG_QWORD && size == 8).then(|| u64::from_le_bytes(bytes))
    }

    /// Started using the device and hasn't stopped.
    pub fn holding(key: &Key) -> bool {
        qword(key, "LastUsedTimeStart").is_some_and(|t| t > 0) && qword(key, "LastUsedTimeStop") == Some(0)
    }
}
