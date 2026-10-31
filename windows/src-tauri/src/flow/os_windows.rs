// Flow dictation on Windows: the key, through a low-level keyboard hook (it
// observes modifiers and consumes an opted-in Copilot chord); paste through SendInput; and
// the app in front, from the foreground window's program.

use std::cell::RefCell;
use std::sync::mpsc::Sender;
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
    GetWindowThreadProcessId, IsWindowVisible, PeekMessageW, PostThreadMessageW, SetWindowsHookExW, TranslateMessage,
    UnhookWindowsHookEx, KBDLLHOOKSTRUCT, LLKHF_EXTENDED, LLKHF_INJECTED, MSG, PM_NOREMOVE, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_QUIT,
    WM_SYSKEYDOWN, WM_SYSKEYUP,
};

use super::keyboard::Keys;
use super::logic::FlowKey;
use super::KeyEvent;

const VK_V: u16 = 0x56;
const VK_CONTROL: u16 = 0x11;
const VK_SHIFT_KEY: u16 = 0x10;
const VK_RSHIFT: u32 = 0xA1;
const VK_RCONTROL: u32 = 0xA3;
const VK_RMENU: u32 = 0xA5;
const VK_LWIN: u32 = 0x5B;

thread_local! {
    // The hook runs on its installing thread. No global lock or shared state
    // crosses a stop/restart, and the callback only classifies and queues.
    static KEYS: RefCell<Option<(Keys, Sender<(KeyEvent, Instant)>)>> = const { RefCell::new(None) };
}

unsafe extern "system" fn hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN | WM_KEYUP | WM_SYSKEYUP) {
        let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let consumed = KEYS.with(|slot| {
            let mut slot = slot.borrow_mut();
            let Some((keys, tx)) = slot.as_mut() else { return false };
            let (event, consumed) = keys.event(info.vkCode, info.scanCode,
                info.flags.0 & LLKHF_EXTENDED.0 != 0,
                matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN),
                info.flags.0 & LLKHF_INJECTED.0 != 0);
            if let Some(event) = event { let _ = tx.send((event, Instant::now())); }
            consumed
        });
        if consumed { return LRESULT(1); }
    }
    CallNextHookEx(None, code, wparam, lparam)
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
    }
}

pub fn listen(key: FlowKey, tx: Sender<(KeyEvent, Instant)>) -> Result<KeyListener, String> {
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<u32, String>>();
    let thread = std::thread::Builder::new()
        .name("coucou-flow-keys".into())
        .spawn(move || unsafe {
            // Create the queue before announcing readiness: Drop may post WM_QUIT immediately.
            let mut msg = MSG::default();
            let _ = PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE);
            KEYS.with(|slot| *slot.borrow_mut() = Some((Keys::new(key), tx)));
            let module = GetModuleHandleW(None).ok();
            let handle = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook), module.map(Into::into), 0) {
                Ok(h) => h,
                Err(err) => {
                    let _ = ready_tx.send(Err(err.to_string()));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(GetCurrentThreadId()));
            while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            let _ = UnhookWindowsHookEx(handle);
            KEYS.with(|slot| *slot.borrow_mut() = None);
        })
        .map_err(|e| e.to_string())?;
    match ready_rx.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok(thread_id)) => Ok(KeyListener { thread_id, thread: Some(thread) }),
        Ok(Err(err)) => Err(err),
        Err(_) => Err("the keyboard hook did not start".into()),
    }
}

/// Waits (up to a second) until the dictation key is up, so the paste is a
/// plain Ctrl+V and not Ctrl+Alt+V or Ctrl+Shift+V.
pub fn wait_key_released(key: FlowKey) {
    let keys: &[u32] = match key {
        FlowKey::RightCtrl => &[VK_RCONTROL],
        FlowKey::RightAlt => &[VK_RMENU],
        FlowKey::RightShift => &[VK_RSHIFT],
        FlowKey::LeftCtrlSuper => &[0xA2, VK_LWIN],
        FlowKey::Copilot => &[0x86, 0xA0, VK_RSHIFT, VK_LWIN, 0x5C],
    };
    let until = Instant::now() + Duration::from_secs(1);
    while Instant::now() < until {
        if keys.iter().all(|vk| (unsafe { GetAsyncKeyState(*vk as i32) } as u16) & 0x8000 == 0) {
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
