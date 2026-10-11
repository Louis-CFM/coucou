// What Windows itself tells the island: the volume keys, brightness, the
// battery, waking from sleep and the clipboard. Windows only.
//
// One thread owns a message-only window and blocks in GetMessage, so nothing
// runs until Windows has something to say:
// - Volume keys: a low-level keyboard hook (only while the volume HUD is on)
//   takes Volume Up / Down / Mute away from Windows' own popup; a second
//   thread sets the level and the island shows it. The hook itself only
//   forwards the key — a hook that dawdles stalls every keystroke.
// - Brightness, AC/battery and the battery level: power-setting notifications.
// - Waking up: WM_POWERBROADCAST / PBT_APMRESUMEAUTOMATIC → the Monday recap.
// - Clipboard: WM_CLIPBOARDUPDATE. Text only, kept in memory (never on disk),
//   and nothing a password manager marks as private.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::{LazyLock, Mutex, OnceLock};

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use windows::core::{GUID, PCWSTR};
use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData, IsClipboardFormatAvailable,
    OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::System::Power::{RegisterPowerSettingNotification, POWERBROADCAST_SETTING};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{VIRTUAL_KEY, VK_VOLUME_DOWN, VK_VOLUME_MUTE, VK_VOLUME_UP};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, PostThreadMessageW,
    RegisterClassW, SetWindowsHookExW, UnhookWindowsHookEx, DEVICE_NOTIFY_WINDOW_HANDLE, HC_ACTION, HHOOK,
    HWND_MESSAGE, KBDLLHOOKSTRUCT, MSG, PBT_APMRESUMEAUTOMATIC, PBT_POWERSETTINGCHANGE,
    WH_KEYBOARD_LL, WINDOW_EX_STYLE, WINDOW_STYLE, WM_APP, WM_CLIPBOARDUPDATE, WM_KEYDOWN, WM_POWERBROADCAST,
    WM_SYSKEYDOWN, WNDCLASSW,
};

use crate::settings::PlusPrefs;

/// GUID_VIDEO_CURRENT_MONITOR_BRIGHTNESS / display brightness (0…100).
const GUID_BRIGHTNESS: GUID = GUID::from_u128(0xaded5e82_b909_4619_9949_f5d71dac0bcb);
/// GUID_ACDC_POWER_SOURCE: 0 = AC, 1 = battery, 2 = UPS.
const GUID_POWER_SOURCE: GUID = GUID::from_u128(0x5d3e9a59_e9d5_4b00_a6bd_ff34ff516548);
/// GUID_BATTERY_PERCENTAGE_REMAINING: 0…100.
const GUID_BATTERY: GUID = GUID::from_u128(0xa7ad8041_b45a_4cae_87a3_eecbb468a9e1);

/// Posted to the thread: the volume HUD was switched, install or drop the hook.
const WM_SYNC_HOOK: u32 = WM_APP + 1;
/// Windows' own step (2 %).
const VOLUME_STEP: f32 = 0.02;
const CLIPBOARD_KEEP: usize = 24;
const CLIPBOARD_MAX_CHARS: usize = 20_000;

static APP: OnceLock<AppHandle> = OnceLock::new();
static PREFS: LazyLock<Mutex<PlusPrefs>> = LazyLock::new(Default::default);
static THREAD_ID: AtomicU32 = AtomicU32::new(0);
static VOLUME_KEYS: AtomicBool = AtomicBool::new(false);
static VOLUME_TX: OnceLock<Sender<VIRTUAL_KEY>> = OnceLock::new();
static HOOK: Mutex<Option<isize>> = Mutex::new(None);
/// Last values heard, so the first notification (sent on registering) and
/// repeats stay quiet.
static LAST: LazyLock<Mutex<Last>> = LazyLock::new(Default::default);
static CLIPS: LazyLock<Mutex<VecDeque<Clip>>> = LazyLock::new(Default::default);

#[derive(Default)]
pub struct Last {
    brightness: Option<u32>,
    on_ac: Option<bool>,
    battery: Option<u32>,
}

/// One "live activity" for the compact island (src/island/live.ts).
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Live {
    /// volume | brightness | battery
    pub kind: &'static str,
    /// 0…1, when there is a level to draw.
    pub level: Option<f32>,
    pub muted: bool,
    pub charging: bool,
    /// Short text, e.g. "Charging" or "Low battery".
    pub text: String,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub id: u64,
    pub text: String,
    /// Unix ms.
    pub at: f64,
}

fn emit_live(live: Live) {
    if let Some(app) = APP.get() {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, "live", live);
    }
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

pub fn start(app: &AppHandle, prefs: &PlusPrefs) {
    if APP.set(app.clone()).is_err() {
        return;
    }
    *PREFS.lock().unwrap() = prefs.clone();
    VOLUME_KEYS.store(prefs.volume_hud, Ordering::Relaxed);
    let (tx, rx) = channel::<VIRTUAL_KEY>();
    let _ = VOLUME_TX.set(tx);
    let _ = std::thread::Builder::new().name("coucou-volume".into()).spawn(move || {
        for vk in rx {
            volume_key(vk);
        }
    });
    let _ = std::thread::Builder::new().name("coucou-sys".into()).spawn(run);
}

/// Settings saved: the hook follows the volume HUD switch.
pub fn apply(prefs: &PlusPrefs) {
    *PREFS.lock().unwrap() = prefs.clone();
    VOLUME_KEYS.store(prefs.volume_hud, Ordering::Relaxed);
    if !prefs.clipboard_history {
        CLIPS.lock().unwrap().clear();
    }
    let id = THREAD_ID.load(Ordering::Relaxed);
    if id != 0 {
        let _ = unsafe { PostThreadMessageW(id, WM_SYNC_HOOK, WPARAM(0), LPARAM(0)) };
    }
}

fn run() {
    unsafe {
        THREAD_ID.store(GetCurrentThreadId(), Ordering::Relaxed);
        let Ok(module) = GetModuleHandleW(None) else { return };
        let class = windows::core::w!("CoucouSysEvents");
        let wc = WNDCLASSW { lpfnWndProc: Some(wndproc), hInstance: module.into(), lpszClassName: class, ..Default::default() };
        RegisterClassW(&wc);
        let Ok(hwnd) = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR::null(),
            WINDOW_STYLE(0),
            0,
            0,
            0,
            0,
            Some(HWND_MESSAGE),
            None,
            Some(module.into()),
            None,
        ) else {
            crate::log::line("sysevents: no message window");
            return;
        };
        for guid in [GUID_BRIGHTNESS, GUID_POWER_SOURCE, GUID_BATTERY] {
            let _ = RegisterPowerSettingNotification(HANDLE(hwnd.0), &guid, DEVICE_NOTIFY_WINDOW_HANDLE);
        }
        let _ = AddClipboardFormatListener(hwnd);
        // Another app coming forward (a full-screen one, the taskbar) can rise
        // above the island: it climbs back on top each time, and only then.
        let _ = windows::Win32::UI::Accessibility::SetWinEventHook(
            windows::Win32::UI::WindowsAndMessaging::EVENT_SYSTEM_FOREGROUND,
            windows::Win32::UI::WindowsAndMessaging::EVENT_SYSTEM_FOREGROUND,
            None,
            Some(foreground_changed),
            0,
            0,
            windows::Win32::UI::WindowsAndMessaging::WINEVENT_OUTOFCONTEXT,
        );
        sync_hook();
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            if msg.hwnd.0.is_null() && msg.message == WM_SYNC_HOOK {
                sync_hook();
                continue;
            }
            DispatchMessageW(&msg);
        }
    }
}

fn sync_hook() {
    let want = VOLUME_KEYS.load(Ordering::Relaxed);
    let mut hook = HOOK.lock().unwrap();
    match (want, *hook) {
        (true, None) => {
            match unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), None, 0) } {
                Ok(h) => {
                    *hook = Some(h.0 as isize);
                    crate::log::line("sysevents: volume keys hooked");
                }
                Err(e) => crate::log::line(format!("sysevents: no keyboard hook: {e}")),
            }
        }
        (false, Some(h)) => {
            let _ = unsafe { UnhookWindowsHookEx(HHOOK(h as _)) };
            *hook = None;
        }
        _ => {}
    }
}

unsafe extern "system" fn foreground_changed(
    _: windows::Win32::UI::Accessibility::HWINEVENTHOOK,
    _: u32,
    _: HWND,
    _: i32,
    _: i32,
    _: u32,
    _: u32,
) {
    keep_on_top();
}

/// Puts the island (and Mochi on the desktop) back above every other window.
pub fn keep_on_top() {
    use tauri::Manager;
    use windows::Win32::UI::WindowsAndMessaging::{SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE};
    let Some(app) = APP.get() else { return };
    for (_, win) in app.webview_windows() {
        if win.label() == "settings" {
            continue;
        }
        if let Ok(h) = win.hwnd() {
            let _ = unsafe { SetWindowPos(HWND(h.0 as _), Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) };
        }
    }
}

// ── Volume keys ───────────────────────────────────────────────────────────────

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 && VOLUME_KEYS.load(Ordering::Relaxed) {
        let k = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let vk = VIRTUAL_KEY(k.vkCode as u16);
        let ours = vk == VK_VOLUME_UP || vk == VK_VOLUME_DOWN || vk == VK_VOLUME_MUTE;
        // Laptop Fn keys often arrive injected by the maker's hotkey service,
        // so injected keys count too (Coucou never injects any itself).
        if ours {
            let down = wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN;
            if down {
                if let Some(tx) = VOLUME_TX.get() {
                    let _ = tx.send(vk);
                }
            }
            // Swallowed, key up included: Windows' popup never sees it.
            return LRESULT(1);
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// The next level for a key: Windows' 2 % steps, landing on the grid.
pub fn stepped(level: f32, up: bool) -> f32 {
    let steps = (level / VOLUME_STEP).round();
    let next = if up { steps + 1.0 } else { steps - 1.0 };
    (next * VOLUME_STEP).clamp(0.0, 1.0)
}

fn volume_key(vk: VIRTUAL_KEY) {
    let Some(ep) = crate::audio::endpoint() else { return };
    unsafe {
        let level = ep.GetMasterVolumeLevelScalar().unwrap_or(0.0);
        let mut muted = ep.GetMute().map(|b| b.as_bool()).unwrap_or(false);
        let mut new = level;
        if vk == VK_VOLUME_MUTE {
            muted = !muted;
            let _ = ep.SetMute(muted, std::ptr::null());
        } else {
            new = stepped(level, vk == VK_VOLUME_UP);
            let _ = ep.SetMasterVolumeLevelScalar(new, std::ptr::null());
            // A key that changes the level brings the sound back, as Windows does.
            if muted && vk == VK_VOLUME_UP {
                muted = false;
                let _ = ep.SetMute(false, std::ptr::null());
            }
        }
        emit_live(Live { kind: "volume", level: Some(new), muted: muted || new == 0.0, charging: false, text: String::new() });
    }
}

// ── Window messages ───────────────────────────────────────────────────────────

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_POWERBROADCAST => {
            match wparam.0 as u32 {
                PBT_APMRESUMEAUTOMATIC => {
                    // The Monday recap waits for the first wake of the week.
                    if let Some(app) = APP.get() {
                        let _ = app.emit_to(crate::island::WINDOW_LABEL, "recap-check", ());
                    }
                }
                PBT_POWERSETTINGCHANGE => {
                    let s = unsafe { &*(lparam.0 as *const POWERBROADCAST_SETTING) };
                    if s.DataLength >= 4 {
                        let value = unsafe { std::ptr::read_unaligned(s.Data.as_ptr() as *const u32) };
                        power_setting(s.PowerSetting, value);
                    }
                }
                _ => {}
            }
            LRESULT(1)
        }
        WM_CLIPBOARDUPDATE => {
            if PREFS.lock().unwrap().clipboard_history {
                read_clipboard(hwnd);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// What a power notification means for the island, given the last value.
pub fn power_event(last: &mut Last, guid: GUID, value: u32, prefs: &PlusPrefs) -> Option<Live> {
    if guid == GUID_BRIGHTNESS {
        let first = last.brightness.is_none();
        let changed = last.brightness != Some(value);
        last.brightness = Some(value);
        return (!first && changed && prefs.brightness_hud).then(|| Live {
            kind: "brightness",
            level: Some(value.min(100) as f32 / 100.0),
            muted: false,
            charging: false,
            text: String::new(),
        });
    }
    if guid == GUID_POWER_SOURCE {
        let on_ac = value == 0;
        let first = last.on_ac.is_none();
        let changed = last.on_ac != Some(on_ac);
        last.on_ac = Some(on_ac);
        let level = last.battery.map(|b| b as f32 / 100.0);
        // A desktop on AC never had a battery to report.
        return (!first && changed && prefs.battery_alerts && level.is_some()).then(|| Live {
            kind: "battery",
            level,
            muted: false,
            charging: on_ac,
            text: if on_ac { "Charging".into() } else { "On battery".into() },
        });
    }
    if guid == GUID_BATTERY {
        let before = last.battery;
        last.battery = Some(value);
        let on_battery = last.on_ac == Some(false);
        // Crossing 20 % and 10 % on the way down, once each.
        let crossed = |mark: u32| before.is_some_and(|b| b > mark) && value <= mark;
        return (prefs.battery_alerts && on_battery && (crossed(20) || crossed(10))).then(|| Live {
            kind: "battery",
            level: Some(value as f32 / 100.0),
            muted: false,
            charging: false,
            text: "Low battery".into(),
        });
    }
    None
}

fn power_setting(guid: GUID, value: u32) {
    let prefs = PREFS.lock().unwrap().clone();
    let live = power_event(&mut LAST.lock().unwrap(), guid, value, &prefs);
    if let Some(live) = live {
        emit_live(live);
    }
}

/// Battery level and whether it charges, for the System card.
pub fn battery() -> (Option<u32>, Option<bool>) {
    let l = LAST.lock().unwrap();
    (l.battery, l.on_ac)
}

// ── Clipboard ─────────────────────────────────────────────────────────────────

fn format(name: PCWSTR) -> u32 {
    unsafe { RegisterClipboardFormatW(name) }
}

fn read_clipboard(hwnd: HWND) {
    unsafe {
        // Password managers mark what they copy; it is never kept.
        for private in [
            windows::core::w!("ExcludeClipboardContentFromMonitorProcessing"),
            windows::core::w!("Clipboard Viewer Ignore"),
        ] {
            if IsClipboardFormatAvailable(format(private)).is_ok() {
                return;
            }
        }
        let history_flag = format(windows::core::w!("CanIncludeInClipboardHistory"));
        if IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).is_err() {
            return;
        }
        // Whoever just wrote it may still hold it for a moment.
        let mut opened = false;
        for _ in 0..5 {
            if OpenClipboard(Some(hwnd)).is_ok() {
                opened = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(15));
        }
        if !opened {
            return;
        }
        let excluded = IsClipboardFormatAvailable(history_flag).is_ok()
            && GetClipboardData(history_flag).ok().is_some_and(|h| read_u32(h) == Some(0));
        let text = if excluded { None } else { GetClipboardData(CF_UNICODETEXT.0 as u32).ok().and_then(|h| read_wide(h)) };
        let _ = CloseClipboard();
        if let Some(text) = text {
            remember(text);
        }
    }
}

unsafe fn read_u32(h: HANDLE) -> Option<u32> {
    let g = HGLOBAL(h.0);
    let p = unsafe { GlobalLock(g) } as *const u32;
    if p.is_null() {
        return None;
    }
    let v = unsafe { std::ptr::read_unaligned(p) };
    let _ = unsafe { GlobalUnlock(g) };
    Some(v)
}

unsafe fn read_wide(h: HANDLE) -> Option<String> {
    let g = HGLOBAL(h.0);
    let size = unsafe { GlobalSize(g) } / 2;
    let p = unsafe { GlobalLock(g) } as *const u16;
    if p.is_null() {
        return None;
    }
    let slice = unsafe { std::slice::from_raw_parts(p, size) };
    let len = slice.iter().position(|&c| c == 0).unwrap_or(size);
    let text = String::from_utf16_lossy(&slice[..len]);
    let _ = unsafe { GlobalUnlock(g) };
    Some(text)
}

/// Keeps a copied text at the top of the list, once.
pub fn remember(text: String) {
    if text.trim().is_empty() {
        return;
    }
    let text: String = text.chars().take(CLIPBOARD_MAX_CHARS).collect();
    let mut clips = CLIPS.lock().unwrap();
    clips.retain(|c| c.text != text);
    let id = clips.iter().map(|c| c.id).max().unwrap_or(0) + 1;
    clips.push_front(Clip { id, text, at: now_ms() });
    clips.truncate(CLIPBOARD_KEEP);
    drop(clips);
    if let Some(app) = APP.get() {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, "clipboard-changed", ());
    }
}

#[tauri::command]
pub fn clipboard_history() -> Vec<Clip> {
    CLIPS.lock().unwrap().iter().cloned().collect()
}

#[tauri::command]
pub fn clipboard_clear() {
    CLIPS.lock().unwrap().clear();
}

/// Puts a text back on the clipboard (a click on a row of the Shelf).
#[tauri::command]
pub fn clipboard_copy(text: String) -> bool {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        if OpenClipboard(None).is_err() {
            return false;
        }
        let _ = EmptyClipboard();
        let Ok(mem) = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2) else {
            let _ = CloseClipboard();
            return false;
        };
        let p = GlobalLock(mem) as *mut u16;
        if p.is_null() {
            let _ = GlobalFree(Some(mem));
            let _ = CloseClipboard();
            return false;
        }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), p, wide.len());
        let _ = GlobalUnlock(mem);
        let ok = SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(mem.0))).is_ok();
        if !ok {
            let _ = GlobalFree(Some(mem));
        }
        let _ = CloseClipboard();
        ok
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn prefs() -> PlusPrefs {
        PlusPrefs::default()
    }

    #[test]
    fn volume_moves_in_windows_steps() {
        assert!((stepped(0.50, true) - 0.52).abs() < 1e-4);
        assert!((stepped(0.51, false) - 0.50).abs() < 1e-4);
        assert_eq!(stepped(1.0, true), 1.0);
        assert_eq!(stepped(0.0, false), 0.0);
    }

    #[test]
    fn the_first_notification_is_the_current_value_not_a_change() {
        let mut last = Last::default();
        assert_eq!(power_event(&mut last, GUID_BRIGHTNESS, 40, &prefs()), None);
        assert_eq!(power_event(&mut last, GUID_BRIGHTNESS, 40, &prefs()), None);
        let live = power_event(&mut last, GUID_BRIGHTNESS, 60, &prefs()).unwrap();
        assert_eq!((live.kind, live.level), ("brightness", Some(0.6)));
        let off = PlusPrefs { brightness_hud: false, ..prefs() };
        assert_eq!(power_event(&mut last, GUID_BRIGHTNESS, 70, &off), None);
    }

    #[test]
    fn plugging_in_and_running_low() {
        let mut last = Last::default();
        power_event(&mut last, GUID_BATTERY, 55, &prefs());
        assert_eq!(power_event(&mut last, GUID_POWER_SOURCE, 1, &prefs()), None);
        let plugged = power_event(&mut last, GUID_POWER_SOURCE, 0, &prefs()).unwrap();
        assert!(plugged.charging);
        power_event(&mut last, GUID_POWER_SOURCE, 1, &prefs()).unwrap();
        assert_eq!(power_event(&mut last, GUID_BATTERY, 21, &prefs()), None);
        assert_eq!(power_event(&mut last, GUID_BATTERY, 20, &prefs()).unwrap().text, "Low battery");
        assert_eq!(power_event(&mut last, GUID_BATTERY, 19, &prefs()), None);
        assert!(power_event(&mut last, GUID_BATTERY, 10, &prefs()).is_some());
    }

    #[test]
    fn a_desktop_without_battery_says_nothing_about_power() {
        let mut last = Last::default();
        power_event(&mut last, GUID_POWER_SOURCE, 0, &prefs());
        assert_eq!(power_event(&mut last, GUID_POWER_SOURCE, 1, &prefs()), None);
    }
}
