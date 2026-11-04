// Flow dictation on Windows: the key, through a low-level keyboard hook (it
// only watches, it never swallows a key); the paste, through SendInput; and
// the app in front, from the foreground window's program.

use std::sync::mpsc::Sender;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use windows::core::PWSTR;
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::{
    GetCurrentThreadId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, EnumWindows, GetForegroundWindow, GetMessageW, GetWindowTextLengthW,
    GetWindowThreadProcessId, IsWindowVisible, PostThreadMessageW, SetWindowsHookExW, TranslateMessage,
    UnhookWindowsHookEx, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_QUIT,
    WM_SYSKEYDOWN, WM_SYSKEYUP,
};

use super::logic::{is_modifier_code, Combo, ComboEdge};
use super::KeyEvent;

const VK_ESCAPE: u32 = 0x1B;
const VK_V: u16 = 0x56;
const VK_CONTROL: u16 = 0x11;
const VK_SHIFT_KEY: u16 = 0x10;
const VK_LSHIFT: u32 = 0xA0;
const VK_RSHIFT: u32 = 0xA1;
const VK_LCONTROL: u32 = 0xA2;
const VK_RCONTROL: u32 = 0xA3;
const VK_LMENU: u32 = 0xA4;
const VK_RMENU: u32 = 0xA5;
const VK_LWIN: u32 = 0x5B;
const VK_RWIN: u32 = 0x5C;
/// Unassigned: pressed and released by Coucou so a held Alt or Win, once let
/// go, opens neither the app's menu bar nor the Start menu.
const VK_MASK: u16 = 0xE8;

/// Modifier keys never count as "another key": AltGr even sends a fake left
/// Ctrl with every right Alt.
fn is_modifier(vk: u32) -> bool {
    matches!(vk, 0x10 | 0x11 | 0x12 | VK_LSHIFT..=VK_RMENU | VK_LWIN | VK_RWIN | 0x14)
}

/// A KeyboardEvent.code name → its virtual key.
pub fn code_vk(code: &str) -> Option<u32> {
    let vk = match code {
        "ControlLeft" => VK_LCONTROL,
        "ControlRight" => VK_RCONTROL,
        "AltLeft" => VK_LMENU,
        "AltRight" => VK_RMENU,
        "ShiftLeft" => VK_LSHIFT,
        "ShiftRight" => VK_RSHIFT,
        "MetaLeft" => VK_LWIN,
        "MetaRight" => VK_RWIN,
        "Space" => 0x20,
        "Backquote" => 0xC0,
        "Insert" => 0x2D,
        "Pause" => 0x13,
        "ScrollLock" => 0x91,
        "CapsLock" => 0x14,
        "ContextMenu" => 0x5D,
        _ => {
            if let Some(c) = code.strip_prefix("Key").filter(|c| c.len() == 1) {
                c.as_bytes()[0] as u32 // 'A'..'Z' are their own virtual keys
            } else if let Some(d) = code.strip_prefix("Digit").filter(|d| d.len() == 1) {
                d.as_bytes()[0] as u32 // '0'..'9' too
            } else {
                let n: u32 = code.strip_prefix('F')?.parse().ok()?;
                if !(1..=24).contains(&n) {
                    return None;
                }
                0x70 + n - 1
            }
        }
    };
    Some(vk)
}

/// The shortcut being watched: its keys' virtual keys, which are modifiers,
/// and which are down.
struct Watch {
    vks: Vec<u32>,
    modifier: Vec<bool>,
    combo: Combo,
    /// It holds Alt or Win: those are masked when it starts.
    masks: bool,
}

static SINK: Mutex<Option<Sender<(KeyEvent, Instant)>>> = Mutex::new(None);
static WATCH: Mutex<Option<Watch>> = Mutex::new(None);

fn send(event: KeyEvent) {
    if let Some(tx) = SINK.lock().unwrap().as_ref() {
        let _ = tx.send((event, Instant::now()));
    }
}

unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        // Our own Ctrl+V, and other programs' synthetic keys, are not the user's.
        if info.flags.0 & LLKHF_INJECTED.0 == 0 {
            let down = matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
            let up = matches!(wparam.0 as u32, WM_KEYUP | WM_SYSKEYUP);
            if on_key(info.vkCode, down, up) {
                // A shortcut's own letter (Alt + Shift + F): the app in front
                // never gets it, or it would act on it too.
                return LRESULT(1);
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// One key; true when the app in front must not get it.
fn on_key(vk: u32, down: bool, up: bool) -> bool {
    let mut guard = WATCH.lock().unwrap();
    let Some(w) = guard.as_mut() else { return false };
    if let Some(i) = w.vks.iter().position(|&k| k == vk) {
        if !down && !up {
            return false;
        }
        let was_all = w.combo.all_held();
        let edge = w.combo.key(i, down);
        let masks = w.masks;
        // A key that isn't a modifier is the shortcut's own while it is held:
        // its press (the one that completes it), repeats and release.
        let own = !w.modifier[i] && (matches!(edge, ComboEdge::Down | ComboEdge::Repeat) || (up && was_all));
        drop(guard);
        match edge {
            ComboEdge::Down => {
                // Not from inside the hook: Windows hands it injected keys of its own.
                if masks {
                    std::thread::spawn(mask_menu);
                }
                send(KeyEvent::Down);
            }
            ComboEdge::Repeat => send(KeyEvent::Down),
            ComboEdge::Up => send(KeyEvent::Up),
            ComboEdge::Part | ComboEdge::Outside => {}
        }
        return own;
    }
    drop(guard);
    if !down {
        return false;
    }
    if vk == VK_ESCAPE {
        send(KeyEvent::Escape);
    } else if !is_modifier(vk) {
        send(KeyEvent::Other);
    }
    false
}

/// A key nobody uses, pressed and released: Windows then reads the held Alt or
/// Win as part of a shortcut, so letting it go opens no menu.
fn mask_menu() {
    let inputs = [key_input(VK_MASK, false), key_input(VK_MASK, true)];
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

/// The hook's thread; it ends when dropped.
pub struct KeyListener {
    thread_id: u32,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Drop for KeyListener {
    fn drop(&mut self) {
        unsafe {
            let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        *SINK.lock().unwrap() = None;
        *WATCH.lock().unwrap() = None;
    }
}

/// Watches the keys `codes` (KeyboardEvent.code names), held together to dictate.
pub fn listen(codes: &[String], tx: Sender<(KeyEvent, Instant)>) -> Result<KeyListener, String> {
    let vks: Vec<u32> = codes.iter().filter_map(|c| code_vk(c)).collect();
    if vks.is_empty() || vks.len() != codes.len() {
        return Err(format!("unknown keys: {codes:?}"));
    }
    let modifier: Vec<bool> = codes.iter().map(|c| is_modifier_code(c)).collect();
    let masks = vks.iter().any(|&v| matches!(v, VK_LMENU | VK_LWIN | VK_RWIN));
    *WATCH.lock().unwrap() = Some(Watch { combo: Combo::new(vks.len()), vks, modifier, masks });
    *SINK.lock().unwrap() = Some(tx);
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<u32, String>>();
    let thread = std::thread::Builder::new()
        .name("coucou-flow-keys".into())
        .spawn(move || unsafe {
            let module = GetModuleHandleW(None).ok();
            let handle = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), module.map(Into::into), 0) {
                Ok(h) => h,
                Err(err) => {
                    let _ = ready_tx.send(Err(err.to_string()));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(GetCurrentThreadId()));
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            let _ = UnhookWindowsHookEx(handle);
        })
        .map_err(|e| e.to_string())?;
    match ready_rx.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok(thread_id)) => Ok(KeyListener { thread_id, thread: Some(thread) }),
        Ok(Err(err)) => Err(err),
        Err(_) => Err("the keyboard hook did not start".into()),
    }
}

/// Waits (up to a second) until the dictation keys are up, so the paste is a
/// plain Ctrl+V and not Ctrl+Alt+V or Ctrl+Shift+V.
pub fn wait_key_released(codes: &[String]) {
    let vks: Vec<i32> = codes.iter().filter_map(|c| code_vk(c)).map(|v| v as i32).collect();
    let until = Instant::now() + Duration::from_secs(1);
    while Instant::now() < until {
        let held = vks.iter().any(|&vk| (unsafe { GetAsyncKeyState(vk) } as u16) & 0x8000 != 0);
        if !held {
            return;
        }
        std::thread::sleep(Duration::from_millis(15));
    }
}

fn key_input(vk: u16, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(vk),
                wScan: 0,
                dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

/// Ctrl+V in the app in front. Ctrl+Shift+V for a terminal that wants it.
pub fn send_paste(shift: bool) -> Result<(), String> {
    let mut inputs = vec![key_input(VK_CONTROL, false)];
    if shift {
        inputs.push(key_input(VK_SHIFT_KEY, false));
    }
    inputs.push(key_input(VK_V, false));
    inputs.push(key_input(VK_V, true));
    if shift {
        inputs.push(key_input(VK_SHIFT_KEY, true));
    }
    inputs.push(key_input(VK_CONTROL, true));
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        Err("Windows refused the keystrokes".into())
    }
}

/// A window's program: "outlook", "Outlook".
fn program_of(hwnd: HWND) -> Option<(String, String)> {
    unsafe {
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid as *mut u32));
        if pid == 0 || pid == std::process::id() {
            return None;
        }
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(process);
        if !ok {
            return None;
        }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let stem = std::path::Path::new(&path).file_stem()?.to_string_lossy().to_string();
        Some((stem.to_lowercase(), super::display_name(&stem)))
    }
}

/// The app in front: (id, name), None for Coucou itself or the desktop.
pub fn foreground_app() -> Option<(String, String)> {
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return None;
    }
    program_of(hwnd)
}

/// Apps with a visible window, for "Add an app" in Styles.
pub fn running_apps() -> Vec<(String, String)> {
    unsafe extern "system" fn each(hwnd: HWND, lparam: LPARAM) -> windows::core::BOOL {
        let list = &mut *(lparam.0 as *mut Vec<(String, String)>);
        if IsWindowVisible(hwnd).as_bool() && GetWindowTextLengthW(hwnd) > 0 {
            if let Some(app) = program_of(hwnd) {
                if !list.iter().any(|(id, _)| *id == app.0) && !super::is_shell(&app.0) {
                    list.push(app);
                }
            }
        }
        windows::core::BOOL(1)
    }
    let mut list: Vec<(String, String)> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(each), LPARAM(&mut list as *mut _ as isize));
    }
    list
}

/// Whether the platform can listen for the key at all.
pub fn keys_supported() -> Result<(), &'static str> {
    Ok(())
}
