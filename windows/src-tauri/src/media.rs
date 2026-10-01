// Now-playing pill with no API key and no OAuth: the Spotify desktop app sets
// its main window title to "Artist - Title" while something is playing
// ("Spotify" when idle, "Advertisement" during ads). Reading a window title is
// local, instant and needs no permission — the same trick every lightweight
// now-playing widget uses. Runs synchronously inside the poller tick.

use serde::Serialize;
use windows::core::BOOL;
use windows::Win32::Foundation::{HWND, LPARAM};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetWindowTextW, IsWindowVisible,
};

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub playing: bool,
    pub artist: String,
    pub title: String,
}

struct Found(Option<String>);

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let found = unsafe { &mut *(lparam.0 as *mut Found) };
    if found.0.is_some() {
        return false.into();
    }
    if !unsafe { IsWindowVisible(hwnd) }.as_bool() {
        return true.into();
    }
    let mut class = [0u16; 64];
    let class_len = unsafe { GetClassNameW(hwnd, &mut class) };
    if class_len == 0 {
        return true.into();
    }
    if String::from_utf16_lossy(&class[..class_len as usize]) != "SpotifyMainWindow" {
        return true.into();
    }
    let mut buf = [0u16; 512];
    let len = unsafe { GetWindowTextW(hwnd, &mut buf) };
    if len > 0 {
        found.0 = Some(String::from_utf16_lossy(&buf[..len as usize]));
        return false.into();
    }
    true.into()
}

pub fn now_playing() -> NowPlaying {
    let mut found = Found(None);
    unsafe {
        let _ = EnumWindows(
            Some(enum_proc),
            LPARAM(&mut found as *mut Found as isize),
        );
    };
    let title = found.0.unwrap_or_default();
    // "Artist - Title" (hyphen and en-dash both seen in the wild).
    for sep in [" - ", " – "] {
        if let Some((artist, track)) = title.split_once(sep) {
            let artist = artist.trim();
            let track = track.trim();
            if !artist.is_empty()
                && !track.is_empty()
                && artist != "Spotify"
                && track != "Advertisement"
            {
                return NowPlaying {
                    playing: true,
                    artist: artist.to_string(),
                    title: track.to_string(),
                };
            }
        }
    }
    NowPlaying::default()
}

/// System-wide media keys (play/pause, next, previous). They go to whatever
/// is currently playing — the Spotify desktop app, a browser tab with the web
/// player, anything. No focus stealing, no API, no key.
pub fn press(action: &str) -> Result<(), String> {
    let vk = match action {
        "playpause" | "toggle" | "play" | "pause" => 0xB3u16,
        "next" => 0xB0u16,
        "prev" | "previous" => 0xB1u16,
        _ => return Err("unknown media key".into()),
    };
    let mk = |up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { Default::default() },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    let sent = unsafe { SendInput(&[mk(false), mk(true)], std::mem::size_of::<INPUT>() as i32) };
    if sent == 2 {
        Ok(())
    } else {
        Err("media key not delivered".into())
    }
}
